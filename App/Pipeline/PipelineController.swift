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
    @ObservationIgnored private var runID = 0

    // 翻译队列
    @ObservationIgnored private var pendingTranslations: [(id: Int, text: String)] = []
    @ObservationIgnored private var translationTask: Task<Void, Never>?
    @ObservationIgnored private var isTranslating = false
    @ObservationIgnored private var contextLines = 3
    /// 积压超过这个数量时丢弃较早的待翻译句子，保证字幕实时
    private let maxPendingTranslations = 2

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
        state = .preparing("正在准备…")
        startTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.startPipeline(runID: currentRun)
            } catch {
                guard self.runID == currentRun else { return }
                await self.teardown()
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
        contextLines = settings.translationContextLines
        guard runID == currentRun else { return }

        cancelTranslations()
        segmenter = SubtitleSegmenter()
        partialText = ""
        subtitles.reset()
        subtitles.startSession()

        try await engine.start(
            onEvent: { [weak self] event in
                guard let self, self.runID == currentRun else { return }
                self.handle(event)
            },
            onError: { [weak self] error in
                guard let self, self.runID == currentRun else { return }
                self.warning = "识别出错：\(error.localizedDescription)"
            }
        )
        guard runID == currentRun else {
            // 启动过程中用户点了停止：teardown 可能早于 engine.start 完成，这里补一次停止
            await engine.stop()
            return
        }

        state = .preparing("正在开始捕获系统音频…")
        let capture = SystemAudioCapture()
        try capture.start(
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
        self.capture = capture
        runningDescription = describe(settings)
        state = .running
        startFlushLoop(runID: currentRun)
    }

    // MARK: 停止

    func stop() {
        guard state.isActive else { return }
        runID += 1
        state = .stopping
        startTask?.cancel()
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.teardown()
            // 输出剩余文本
            self.commit(self.segmenter.flush(now: Date()))
            self.partialText = ""
            self.subtitles.clearLiveText()
            self.state = .idle
        }
    }

    private func teardown() async {
        flushTask?.cancel()
        flushTask = nil
        capture?.stop()
        capture = nil
        if let engine {
            await engine.stop()
        }
        engine = nil
        level = 0
    }

    // MARK: 识别结果

    private func handle(_ event: TranscriptEvent) {
        let now = Date()
        switch event {
        case .partial(let text):
            partialText = text
            if !text.isEmpty { segmenter.notePartial(at: now) }
        case .final(let text):
            partialText = ""
            commit(segmenter.appendFinal(text, at: now))
        }
        updateLiveText()
    }

    private func updateLiveText() {
        subtitles.setLiveText(TextUtilities.join(segmenter.pendingText, partialText))
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
            if needsTranslation {
                enqueueTranslation(id: id, text: segment.text)
            }
        }
    }

    // MARK: 翻译

    private func enqueueTranslation(id: Int, text: String) {
        pendingTranslations.append((id, text))
        while pendingTranslations.count > maxPendingTranslations {
            let dropped = pendingTranslations.removeFirst()
            subtitles.markTranslationSkipped(id: dropped.id)
        }
        pumpTranslations()
    }

    private func pumpTranslations() {
        guard !isTranslating, let translator, !pendingTranslations.isEmpty else { return }
        let job = pendingTranslations.removeFirst()
        let context = subtitles.recentOriginals(before: job.id, count: contextLines)
        isTranslating = true
        translationTask = Task { @MainActor [weak self] in
            do {
                let result = try await translator.translate(job.text, context: context) { partial in
                    self?.subtitles.updateTranslation(id: job.id, text: partial, isFinal: false)
                }
                self?.subtitles.updateTranslation(id: job.id, text: result, isFinal: true)
                if self?.warning?.hasPrefix("翻译") == true { self?.warning = nil }
            } catch is CancellationError {
                self?.subtitles.markTranslationSkipped(id: job.id)
            } catch {
                self?.subtitles.markTranslationFailed(id: job.id, message: error.localizedDescription)
                self?.warning = "翻译出错：\(error.localizedDescription)"
            }
            self?.isTranslating = false
            self?.pumpTranslations()
        }
    }

    private func cancelTranslations() {
        translationTask?.cancel()
        translationTask = nil
        pendingTranslations.removeAll()
        isTranslating = false
    }

    // MARK: 引擎工厂

    private func makeTranscriptionEngine(_ settings: AppSettings) throws -> TranscriptionEngine {
        switch settings.transcriptionEngine {
        case .apple:
            return AppleSpeechEngine(localeIdentifier: settings.sourceLanguage)
        case .openAICompatible:
            return OpenAICompatibleSTTEngine(
                config: settings.cloudTranscription,
                apiKey: apiKeys.transcriptionKey,
                sourceLanguage: settings.sourceLanguage,
                sensitivity: settings.vadSensitivity
            )
        }
    }

    private func makeTranslator(_ settings: AppSettings) async throws -> TranslationEngine? {
        switch settings.translationEngine {
        case .none:
            return nil
        case .apple:
            let engine = AppleTranslationEngine(source: settings.sourceLanguage, target: settings.targetLanguage)
            try await engine.prepare()
            return engine
        case .openAICompatible:
            _ = try OpenAIEndpoint.url(base: settings.llmTranslation.baseURL, path: OpenAIEndpoint.chatCompletionsPath)
            return OpenAICompatibleTranslator(
                config: settings.llmTranslation,
                apiKey: apiKeys.translationKey,
                targetLanguage: settings.targetLanguage,
                temperature: settings.translationTemperature,
                customInstructions: settings.customTranslationPrompt,
                client: URLSessionHTTPClient()
            )
        }
    }

    private func describe(_ settings: AppSettings) -> String {
        let source = settings.sourceLanguage == "auto" ? "自动" : Locale.current.localizedString(forIdentifier: settings.sourceLanguage) ?? settings.sourceLanguage
        switch settings.translationEngine {
        case .none:
            return "\(source)（不翻译）"
        default:
            return "\(source) → \(Languages.displayName(for: settings.targetLanguage))"
        }
    }
}
