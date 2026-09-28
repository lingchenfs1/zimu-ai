import AVFoundation
import Speech
import ZimuCore

/// Apple 本地语音识别（macOS 26 SpeechAnalyzer + SpeechTranscriber），单一语言
final class AppleSpeechEngine: TranscriptionEngine {
    private let localeIdentifier: String
    private var transcriber: SpeechTranscriber?
    private var language: String?
    private var analyzer: SpeechAnalyzer?
    private var resultsTask: Task<Void, Never>?
    private let input = AnalyzerInputStream()

    init(localeIdentifier: String) {
        self.localeIdentifier = localeIdentifier
    }

    @MainActor
    func prepare(status: @escaping @MainActor (PreparationStatus) -> Void) async throws -> AVAudioFormat {
        guard localeIdentifier != "auto" else {
            throw TranscriptionError.autoDetectNotSupported
        }
        guard SpeechTranscriber.isAvailable else {
            throw TranscriptionError.unavailable
        }
        let requested = Locale(identifier: localeIdentifier)
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: requested) else {
            throw TranscriptionError.unsupportedLocale(localeIdentifier)
        }

        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults, .fastResults],
            attributeOptions: []
        )
        try await SpeechAssets.ensureInstalled([transcriber], status: status)

        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw TranscriptionError.noAudioFormat
        }
        self.transcriber = transcriber
        self.language = locale.identifier(.bcp47)
        return format
    }

    @MainActor
    func start(
        onEvent: @escaping @MainActor (TranscriptEvent) -> Void,
        onError: @escaping @MainActor (_ error: Error, _ isFatal: Bool) -> Void
    ) async throws {
        guard let transcriber else { throw TranscriptionError.noAudioFormat }
        let inputSequence = input.makeStream()
        let language = self.language
        let input = self.input

        resultsTask = Task.detached(priority: .userInitiated) {
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    if result.isFinal {
                        await onEvent(.final(text, language: language))
                    } else {
                        await onEvent(.partial(text))
                    }
                }
            } catch is CancellationError {
                // 正常停止
            } catch {
                // 结果流出错后分析会话已结束，不再读取输入：关闭输入流，避免音频无限堆积
                input.finish()
                await onError(error, true)
            }
        }

        let analyzer = SpeechAnalyzer(
            modules: [transcriber],
            options: SpeechAnalyzer.Options(priority: .userInitiated, modelRetention: .whileInUse)
        )
        self.analyzer = analyzer
        try await analyzer.start(inputSequence: inputSequence)
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        input.yield(buffer)
    }

    @MainActor
    func stop() async {
        input.finish()
        if let analyzer {
            await SpeechAssets.finish(analyzer)
        }
        await SpeechAssets.waitForResults([resultsTask].compactMap { $0 })
        resultsTask = nil
        analyzer = nil
    }
}

/// Apple 本地识别（多语言自动切换）：同时运行多个语言的识别器，按识别置信度判断正在说哪种语言。
final class AppleMultilingualSpeechEngine: TranscriptionEngine {
    private let localeIdentifiers: [String]
    private var modules: [(language: String, transcriber: SpeechTranscriber)] = []
    private var analyzer: SpeechAnalyzer?
    private var resultTasks: [Task<Void, Never>] = []
    private let input = AnalyzerInputStream()

    // 以下状态只在 MainActor 上访问
    private var selector: LanguageSelector?
    private var latestPartial: [String: String] = [:]
    /// 已输出的定稿结果覆盖到的音频时间（秒）；各语言识别器会对同一段音频各出一份结果，避免重复输出
    private var emittedUntil: Double = -1
    /// 当前判断的语言（BCP-47）
    @MainActor private(set) var activeLanguage: String?
    @MainActor var onActiveLanguageChange: ((String) -> Void)?

    static let maximumLanguages = 4

    init(localeIdentifiers: [String]) {
        var unique: [String] = []
        for id in localeIdentifiers where !unique.contains(id) {
            unique.append(id)
        }
        self.localeIdentifiers = Array(unique.prefix(Self.maximumLanguages))
    }

    @MainActor
    func prepare(status: @escaping @MainActor (PreparationStatus) -> Void) async throws -> AVAudioFormat {
        guard SpeechTranscriber.isAvailable else { throw TranscriptionError.unavailable }
        guard localeIdentifiers.count >= 2 else {
            throw TranscriptionError.missingConfiguration("多语言识别至少需要选择 2 种候选语言（设置 › 识别）")
        }
        var result: [(language: String, transcriber: SpeechTranscriber)] = []
        for identifier in localeIdentifiers {
            guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: identifier)) else {
                throw TranscriptionError.unsupportedLocale(identifier)
            }
            let transcriber = SpeechTranscriber(
                locale: locale,
                transcriptionOptions: [],
                reportingOptions: [.volatileResults, .fastResults],
                attributeOptions: [.transcriptionConfidence]
            )
            result.append((locale.identifier(.bcp47), transcriber))
        }
        let transcribers = result.map(\.transcriber)
        try await SpeechAssets.ensureInstalled(transcribers, status: status)
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: transcribers) else {
            throw TranscriptionError.noAudioFormat
        }
        modules = result
        return format
    }

    @MainActor
    func start(
        onEvent: @escaping @MainActor (TranscriptEvent) -> Void,
        onError: @escaping @MainActor (_ error: Error, _ isFatal: Bool) -> Void
    ) async throws {
        guard !modules.isEmpty else { throw TranscriptionError.noAudioFormat }
        let selector = LanguageSelector(candidates: modules.map(\.language))
        self.selector = selector
        activeLanguage = selector.active
        latestPartial = [:]
        emittedUntil = -1
        let inputSequence = input.makeStream()
        let input = self.input

        resultTasks = modules.map { module in
            let language = module.language
            let transcriber = module.transcriber
            return Task.detached(priority: .userInitiated) { [weak self] in
                do {
                    for try await result in transcriber.results {
                        let text = String(result.text.characters)
                        let confidence = Self.averageConfidence(result.text)
                        let isFinal = result.isFinal
                        let start = result.range.start.seconds
                        let end = result.range.end.seconds
                        await self?.handle(
                            language: language,
                            text: text,
                            isFinal: isFinal,
                            confidence: confidence,
                            timeRange: (start, end),
                            onEvent: onEvent
                        )
                    }
                } catch is CancellationError {
                    // 正常停止
                } catch {
                    input.finish()
                    await onError(error, true)
                }
            }
        }

        let analyzer = SpeechAnalyzer(
            modules: modules.map(\.transcriber),
            options: SpeechAnalyzer.Options(priority: .userInitiated, modelRetention: .whileInUse)
        )
        self.analyzer = analyzer
        try await analyzer.start(inputSequence: inputSequence)
    }

    @MainActor
    private func handle(
        language: String,
        text: String,
        isFinal: Bool,
        confidence: Double?,
        timeRange: (start: Double, end: Double),
        onEvent: @MainActor (TranscriptEvent) -> Void
    ) {
        guard var selector else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if isFinal {
            let score = trimmed.isEmpty ? 0 : (confidence ?? 0.5)
            let switched = selector.record(language: language, confidence: score, characters: trimmed.count)
            self.selector = selector
            latestPartial[language] = ""
            if switched {
                activeLanguage = selector.active
                onActiveLanguageChange?(selector.active)
                NSLog("ZimuAI: multilingual switched to \(selector.active)")
            }
            if language == selector.active {
                // 切换语言时，旧语言可能已经输出过同一段音频的结果：与已输出部分重叠的结果跳过
                let overlaps = timeRange.start.isFinite && timeRange.start < emittedUntil - 0.3
                if !trimmed.isEmpty, !overlaps {
                    onEvent(.final(trimmed, language: language))
                }
                if timeRange.end.isFinite {
                    emittedUntil = max(emittedUntil, timeRange.end)
                }
                onEvent(.partial(""))
            }
        } else {
            latestPartial[language] = text
            if language == selector.active {
                onEvent(.partial(text))
            }
        }
    }

    /// 按字符数加权的平均置信度；没有置信度信息时返回 nil
    static func averageConfidence(_ text: AttributedString) -> Double? {
        var weighted = 0.0
        var total = 0
        for run in text.runs {
            guard let confidence = run.transcriptionConfidence else { continue }
            let count = text[run.range].characters.count
            weighted += confidence * Double(count)
            total += count
        }
        return total > 0 ? weighted / Double(total) : nil
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        input.yield(buffer)
    }

    @MainActor
    func stop() async {
        input.finish()
        if let analyzer {
            await SpeechAssets.finish(analyzer)
        }
        await SpeechAssets.waitForResults(resultTasks)
        resultTasks = []
        analyzer = nil
    }
}

/// 线程安全的 AnalyzerInput 输入流（音频回调线程写入）
final class AnalyzerInputStream {
    private let lock = NSLock()
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?

    func makeStream() -> AsyncStream<AnalyzerInput> {
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        lock.withLock { self.continuation = continuation }
        return stream
    }

    func yield(_ buffer: AVAudioPCMBuffer) {
        let continuation = lock.withLock { self.continuation }
        continuation?.yield(AnalyzerInput(buffer: buffer))
    }

    func finish() {
        let continuation = lock.withLock { () -> AsyncStream<AnalyzerInput>.Continuation? in
            let current = self.continuation
            self.continuation = nil
            return current
        }
        continuation?.finish()
    }
}

/// 语音模型下载、结束分析等公共逻辑
enum SpeechAssets {
    /// 确保模型已安装；下载时显示进度
    @MainActor
    static func ensureInstalled(_ modules: [SpeechTranscriber], status: @escaping @MainActor (PreparationStatus) -> Void) async throws {
        guard let request = try await AssetInventory.assetInstallationRequest(supporting: modules) else { return }
        let progress = request.progress
        let monitor = Task { @MainActor in
            while !Task.isCancelled {
                status(PreparationStatus("正在下载语音识别模型…", fraction: progress.fractionCompleted))
                try? await Task.sleep(for: .milliseconds(300))
            }
        }
        defer { monitor.cancel() }
        try await request.downloadAndInstall()
    }

    static func finish(_ analyzer: SpeechAnalyzer) async {
        do {
            try await analyzer.finalizeAndFinishThroughEndOfInput()
        } catch {
            await analyzer.cancelAndFinishNow()
        }
    }

    /// 等结果流结束（最多 3 秒）
    static func waitForResults(_ tasks: [Task<Void, Never>]) async {
        guard !tasks.isEmpty else { return }
        let timeout = Task {
            try? await Task.sleep(for: .seconds(3))
            tasks.forEach { $0.cancel() }
        }
        for task in tasks {
            await task.value
        }
        timeout.cancel()
    }
}

/// Apple 本地识别支持的语言
enum SpeechLocaleCatalog {
    static func supportedLocales() async -> [Locale] {
        let locales = await SpeechTranscriber.supportedLocales
        return locales.sorted { lhs, rhs in
            let l = Locale.current.localizedString(forIdentifier: lhs.identifier) ?? lhs.identifier
            let r = Locale.current.localizedString(forIdentifier: rhs.identifier) ?? rhs.identifier
            return l.localizedStandardCompare(r) == .orderedAscending
        }
    }
}
