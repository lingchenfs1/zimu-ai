import AVFoundation
import Observation
import ZimuCore

/// 串起 音频捕获 → 语音识别 → 断句 → 翻译 → 字幕窗
@MainActor
@Observable
final class PipelineController {
    enum State: Equatable {
        case idle
        case preparing(String)
        case running
        case stopping
        case failed(String)

        var isActive: Bool {
            switch self {
            case .preparing, .running, .stopping: return true
            case .idle, .failed: return false
            }
        }
    }

    private(set) var state: State = .idle
    /// 实时电平 0...1
    private(set) var level: Float = 0
    /// 最近一次非致命错误（识别 / 翻译）
    private(set) var warning: String?
    /// 本次运行使用的语言（用于界面显示）
    private(set) var runningDescription: String = ""
    /// 多语言识别时当前判断的语言
    private(set) var activeLanguage: String?

    @ObservationIgnored private let settingsStore: SettingsStore
    @ObservationIgnored private let apiKeys: APIKeyStore
    @ObservationIgnored private let subtitles: SubtitleStore

    @ObservationIgnored private var capture: SystemAudioCapture?
    @ObservationIgnored private var engine: TranscriptionEngine?
    @ObservationIgnored private var translator: TranslationEngine?
    @ObservationIgnored private var segmenter = SubtitleSegmenter()
    @ObservationIgnored private var partialText = ""
    @ObservationIgnored private var flushTask: Task<Void, Never>?
    @ObservationIgnored private var startTask: Task<Void, Never>?
    /// 每次开始 / 停止都会递增，用于中止过期的启动流程
    @ObservationIgnored private var runID = 0
    /// 当前接受识别事件的运行编号。停止时要等引擎把剩余结果输出完，所以与 runID 分开
    @ObservationIgnored private var eventRunID = -1

    // 翻译（决策 D12）
    @ObservationIgnored private var scheduler = TranslationScheduler()
    @ObservationIgnored private var translationTasks: [Task<Void, Never>] = []
    /// 翻译代数：取消后旧任务的结果不再写入
    @ObservationIgnored private var translationGeneration = 0
    @ObservationIgnored private var contextLines = 3
    @ObservationIgnored private var liveTranslationEnabled = true
    @ObservationIgnored private var liveTranslationInterval: TimeInterval = 0.5
    @ObservationIgnored private var liveTranslationTask: Task<Void, Never>?
    @ObservationIgnored private var liveTranslationDirty = false
    @ObservationIgnored private var lastLiveTranslation = Date.distantPast

    init(settingsStore: SettingsStore, apiKeys: APIKeyStore, subtitles: SubtitleStore) {
        self.settingsStore = settingsStore
        self.apiKeys = apiKeys
        self.subtitles = subtitles
    }

    var isActive: Bool { state.isActive }

    func toggle() {
        if state.isActive {
            stop()
        } else {
            start()
        }
    }

    // MARK: 启动

    func start() {
        guard !state.isActive else { return }
        runID += 1
        let currentRun = runID
        warning = nil
        activeLanguage = nil
        state = .preparing("正在准备…")
        startTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.startPipeline(runID: currentRun)
            } catch {
                guard self.runID == currentRun else { return }
                self.eventRunID = -1
                await self.teardown()
                guard self.runID == currentRun else { return }
                self.state = .failed(error.localizedDescription)
            }
        }
    }

    private func startPipeline(runID currentRun: Int) async throws {
        let settings = settingsStore.settings
        let engine = try makeTranscriptionEngine(settings)
        self.engine = engine

        let format = try await engine.prepare { [weak self] message in
            guard let self, self.runID == currentRun else { return }
            self.state = .preparing(message)
        }
        try Task.checkCancellation()
        guard runID == currentRun else { return }

        state = .preparing("正在准备翻译…")
        translator = try await makeTranslator(settings)
        configureTranslation(settings)
        guard runID == currentRun else { return }

        cancelTranslations()
        segmenter = SubtitleSegmenter()
        partialText = ""
        subtitles.reset()
        subtitles.startSession()

        if let multilingual = engine as? AppleMultilingualSpeechEngine {
            activeLanguage = multilingual.activeLanguage
            multilingual.onActiveLanguageChange = { [weak self] language in
                self?.activeLanguage = language
            }
        }

        eventRunID = currentRun
        try await engine.start(
            onEvent: { [weak self] event in
                guard let self, self.eventRunID == currentRun else { return }
                self.handle(event)
            },
            onError: { [weak self] error, isFatal in
                guard let self, self.eventRunID == currentRun else { return }
                if isFatal {
                    self.fail(with: "识别中断：\(error.localizedDescription)")
                } else {
                    self.warning = "识别出错：\(error.localizedDescription)"
                }
            }
        )
        if let multilingual = engine as? AppleMultilingualSpeechEngine {
            activeLanguage = multilingual.activeLanguage
        }
        guard runID == currentRun else {
            // 启动过程中用户点了停止：teardown 可能早于 engine.start 完成，这里补一次停止
            await engine.stop()
            return
        }

        // 音频捕获在后台线程启动：第一次使用时系统会弹出授权对话框并阻塞调用线程（决策 D11）
        state = .preparing("正在开始捕获系统音频…")
        let permissionHint = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard let self, !Task.isCancelled, self.runID == currentRun, case .preparing = self.state else { return }
            self.state = .preparing("正在等待「录制系统音频」授权。请在系统弹窗中点「允许」；没有看到弹窗时，到 系统设置 › 隐私与安全性 › 屏幕与系统录音 中允许字幕AI")
        }
        defer { permissionHint.cancel() }

        let capture = SystemAudioCapture()
        self.capture = capture
        try await capture.startInBackground(
            bundleID: settings.captureBundleID,
            outputFormat: format,
            onBuffer: { [weak engine] buffer in
                engine?.append(buffer)
            },
            onLevel: { [weak self] level in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self?.level = level
                    }
                }
            }
        )
        guard runID == currentRun else { return }
        runningDescription = describe(settings)
        state = .running
        startFlushLoop(runID: currentRun)
    }

    // MARK: 停止

    func stop() {
        guard state.isActive, state != .stopping else { return }
        runID += 1
        state = .stopping
        startTask?.cancel()
        finishSession { [weak self] in
            self?.state = .idle
        }
    }

    /// 识别引擎中断等致命错误：停止并显示错误
    private func fail(with message: String) {
        guard state.isActive, state != .stopping else { return }
        runID += 1
        state = .stopping
        startTask?.cancel()
        finishSession { [weak self] in
            self?.state = .failed(message)
        }
    }

    /// 停止捕获和识别；引擎停止前输出的最后结果仍会被处理，然后把剩余文本提交为字幕
    private func finishSession(then completion: @escaping @MainActor () -> Void) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.teardown()
            self.eventRunID = -1
            self.commit(self.segmenter.flush(now: Date()))
            self.partialText = ""
            self.liveTranslationTask?.cancel()
            self.liveTranslationTask = nil
            self.subtitles.clearLiveText()
            completion()
        }
    }

    private func teardown() async {
        flushTask?.cancel()
        flushTask = nil
        // 先取出并清空引用，避免与新一轮运行交错时误清掉新的引擎
        let capture = self.capture
        let engine = self.engine
        self.capture = nil
        self.engine = nil
        level = 0
        if let capture {
            await capture.stopInBackground()
        }
        await engine?.stop()
    }

    /// 退出应用前调用：尽快停止音频捕获（不等识别引擎输出剩余结果）
    var needsShutdown: Bool { capture != nil || engine != nil }

    func shutdown(timeout: TimeInterval) async {
        runID += 1
        eventRunID = -1
        startTask?.cancel()
        flushTask?.cancel()
        flushTask = nil
        liveTranslationTask?.cancel()
        cancelTranslations()
        let capture = self.capture
        self.capture = nil
        self.engine = nil
        if let capture {
            await capture.stopInBackground(timeout: timeout)
        }
        state = .idle
    }

    // MARK: 识别结果

    private func handle(_ event: TranscriptEvent) {
        let now = Date()
        switch event {
        case .partial(let text):
            partialText = text
            if !text.isEmpty { segmenter.notePartial(at: now) }
        case .final(let text, let language):
            partialText = ""
            commit(segmenter.appendFinal(text, language: language, at: now))
        }
        updateLiveText()
    }

    private func updateLiveText() {
        subtitles.setLiveText(TextUtilities.join(segmenter.pendingText, partialText))
        scheduleLiveTranslation()
    }

    private func startFlushLoop(runID currentRun: Int) {
        flushTask?.cancel()
        flushTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(300))
                guard let self, self.runID == currentRun else { return }
                let segments = self.segmenter.flushIfNeeded(now: Date())
                if !segments.isEmpty {
                    self.commit(segments)
                    self.updateLiveText()
                }
            }
        }
    }

    private func commit(_ segments: [SubtitleSegment]) {
        for segment in segments {
            let needsTranslation = translator != nil
            let id = subtitles.commit(segment, needsTranslation: needsTranslation)
            guard needsTranslation else { continue }
            // 实时译文恰好对应这句原文时直接复用，省去一次翻译
            if let reused = subtitles.timeline.reusableLiveTranslation(for: segment.text) {
                subtitles.updateTranslation(id: id, text: reused, isFinal: true)
            } else {
                enqueueTranslation(TranslationJob(id: id, text: segment.text, language: segment.language))
            }
        }
    }

    // MARK: 翻译（决策 D12）

    private func configureTranslation(_ settings: AppSettings) {
        contextLines = settings.translationContextLines
        liveTranslationEnabled = settings.liveTranslation
        let batchSize = translator?.maxBatchSize ?? 1
        if batchSize > 1 {
            // 支持批量的引擎（Apple 翻译）：一次一个请求，积压的句子合并成一批
            scheduler = TranslationScheduler(maxConcurrent: 1, maxQueued: 8, maxBatchSize: batchSize)
            liveTranslationInterval = 0.4
        } else {
            let concurrency = max(1, min(6, settings.translationConcurrency))
            scheduler = TranslationScheduler(maxConcurrent: concurrency, maxQueued: max(2, concurrency * 2), maxBatchSize: 1)
            liveTranslationInterval = 1.2
        }
    }

    private func enqueueTranslation(_ job: TranslationJob) {
        for dropped in scheduler.enqueue(job) {
            subtitles.markTranslationSkipped(id: dropped.id)
        }
        pumpTranslations()
    }

    private func pumpTranslations() {
        guard let translator else { return }
        let generation = translationGeneration
        for batch in scheduler.nextBatches() {
            let task = Task { @MainActor [weak self] in
                await self?.runTranslation(batch, translator: translator, generation: generation)
                guard let self, self.translationGeneration == generation else { return }
                self.scheduler.finishBatch()
                self.pumpTranslations()
            }
            translationTasks.append(task)
        }
        translationTasks.removeAll { $0.isCancelled }
    }

    private func runTranslation(_ batch: [TranslationJob], translator: TranslationEngine, generation: Int) async {
        do {
            if batch.count == 1, let job = batch.first {
                let context = subtitles.recentOriginals(before: job.id, count: contextLines)
                let result = try await translator.translate(job.text, sourceLanguage: job.language, context: context) { [weak self] partial in
                    guard let self, self.translationGeneration == generation else { return }
                    self.subtitles.updateTranslation(id: job.id, text: partial, isFinal: false)
                }
                guard translationGeneration == generation else { return }
                subtitles.updateTranslation(id: job.id, text: result, isFinal: true)
            } else {
                let results = try await translator.translateBatch(batch.map(\.text), sourceLanguage: batch.first?.language)
                guard translationGeneration == generation else { return }
                for (job, text) in zip(batch, results) {
                    subtitles.updateTranslation(id: job.id, text: text, isFinal: true)
                }
            }
            if warning?.hasPrefix("翻译") == true { warning = nil }
        } catch {
            let cancelled = Task.isCancelled
                || error is CancellationError
                || (error as? URLError)?.code == .cancelled
            for job in batch {
                if cancelled {
                    subtitles.markTranslationSkipped(id: job.id)
                } else {
                    subtitles.markTranslationFailed(id: job.id, message: error.localizedDescription)
                }
            }
            if !cancelled, translationGeneration == generation {
                warning = "翻译出错：\(error.localizedDescription)"
            }
        }
    }

    private func cancelTranslations() {
        translationGeneration += 1
        translationTasks.forEach { $0.cancel() }
        translationTasks.removeAll()
        scheduler.reset()
        liveTranslationTask?.cancel()
        liveTranslationTask = nil
        liveTranslationDirty = false
    }

    // MARK: 实时翻译识别中的文字

    private func scheduleLiveTranslation() {
        guard liveTranslationEnabled, translator != nil, !subtitles.timeline.liveText.isEmpty else { return }
        guard liveTranslationTask == nil else {
            liveTranslationDirty = true
            return
        }
        let delay = max(0, liveTranslationInterval - Date().timeIntervalSince(lastLiveTranslation))
        let generation = translationGeneration
        liveTranslationTask = Task { @MainActor [weak self] in
            if delay > 0 {
                try? await Task.sleep(for: .seconds(delay))
            }
            guard let self, !Task.isCancelled, self.translationGeneration == generation else { return }
            await self.performLiveTranslation(generation: generation)
            guard self.translationGeneration == generation else { return }
            self.liveTranslationTask = nil
            if self.liveTranslationDirty {
                self.liveTranslationDirty = false
                self.scheduleLiveTranslation()
            }
        }
    }

    private func performLiveTranslation(generation: Int) async {
        let source = subtitles.timeline.liveText
        guard let translator,
              !source.isEmpty,
              source != subtitles.timeline.liveTranslationSource,
              TextUtilities.normalizedForComparison(source).count >= 2
        else { return }
        lastLiveTranslation = Date()
        let language = segmenter.pendingLanguage ?? activeLanguage
        do {
            let result = try await translator.translate(source, sourceLanguage: language, context: []) { [weak self] partial in
                guard let self, self.translationGeneration == generation else { return }
                self.subtitles.setLiveTranslation(partial, source: source)
            }
            guard translationGeneration == generation else { return }
            subtitles.setLiveTranslation(result, source: source)
        } catch {
            // 实时翻译失败不影响整句翻译，忽略
        }
    }

    // MARK: 引擎工厂

    private func makeTranscriptionEngine(_ settings: AppSettings) throws -> TranscriptionEngine {
        switch settings.transcriptionEngine {
        case .apple:
            guard settings.sourceLanguage != "auto" else { throw TranscriptionError.autoDetectNotSupported }
            return AppleSpeechEngine(localeIdentifier: settings.sourceLanguage)
        case .appleMultilingual:
            return AppleMultilingualSpeechEngine(localeIdentifiers: settings.appleCandidateLanguages)
        case .whisperKit:
            return SegmentedTranscriptionEngine(
                transcriber: WhisperKitTranscriber(
                    model: settings.whisperModel,
                    endpoint: settings.whisperEndpoint,
                    language: settings.sourceLanguage
                ),
                sensitivity: settings.vadSensitivity
            )
        case .openAICompatible:
            return SegmentedTranscriptionEngine(
                transcriber: CloudSegmentTranscriber(
                    config: settings.cloudTranscription,
                    apiKey: apiKeys.transcriptionKey,
                    sourceLanguage: settings.sourceLanguage
                ),
                sensitivity: settings.vadSensitivity
            )
        }
    }

    private func makeTranslator(_ settings: AppSettings) async throws -> TranslationEngine? {
        switch settings.translationEngine {
        case .none:
            return nil
        case .apple:
            let multilingual = settings.transcriptionEngine == .appleMultilingual
            let source = multilingual ? "auto" : settings.sourceLanguage
            let engine = AppleTranslationEngine(source: source, target: settings.targetLanguage)
            try await engine.prepare()
            if multilingual {
                let missing = await engine.missingPairs(for: settings.appleCandidateLanguages)
                if !missing.isEmpty {
                    warning = "翻译语言包未安装：\(missing.joined(separator: "、"))。请在 设置 › 翻译 中下载"
                }
            }
            return engine
        case .openAICompatible:
            _ = try OpenAIEndpoint.url(base: settings.llmTranslation.baseURL, path: OpenAIEndpoint.chatCompletionsPath)
            _ = try OpenAICompatibleTranslator.parseExtraBody(settings.llmExtraBody)
            return OpenAICompatibleTranslator(
                config: settings.llmTranslation,
                apiKey: apiKeys.translationKey,
                targetLanguage: settings.targetLanguage,
                temperature: settings.translationTemperature,
                customInstructions: settings.customTranslationPrompt,
                extraBodyJSON: settings.llmExtraBody,
                client: URLSessionHTTPClient()
            )
        }
    }

    private func describe(_ settings: AppSettings) -> String {
        let source: String
        switch settings.transcriptionEngine {
        case .appleMultilingual:
            source = "多语言"
        default:
            source = settings.sourceLanguage == "auto"
                ? "自动检测"
                : Locale.current.localizedString(forIdentifier: settings.sourceLanguage) ?? settings.sourceLanguage
        }
        switch settings.translationEngine {
        case .none:
            return "\(source)（不翻译）"
        default:
            return "\(source) → \(Languages.displayName(for: settings.targetLanguage))"
        }
    }
}
