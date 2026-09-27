import AVFoundation
import Speech
import ZimuCore

/// Apple 本地语音识别（macOS 26 SpeechAnalyzer + SpeechTranscriber）
final class AppleSpeechEngine: TranscriptionEngine {
    private let localeIdentifier: String
    private var transcriber: SpeechTranscriber?
    private var analyzer: SpeechAnalyzer?
    private var resultsTask: Task<Void, Never>?

    private let lock = NSLock()
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?

    init(localeIdentifier: String) {
        self.localeIdentifier = localeIdentifier
    }

    func prepare(status: @escaping @MainActor (String) -> Void) async throws -> AVAudioFormat {
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
            reportingOptions: [.volatileResults],
            attributeOptions: []
        )

        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            let name = Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
            await status("正在下载「\(name)」语音识别模型…")
            try await request.downloadAndInstall()
        }

        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw TranscriptionError.noAudioFormat
        }
        self.transcriber = transcriber
        return format
    }

    func start(
        onEvent: @escaping @MainActor (TranscriptEvent) -> Void,
        onError: @escaping @MainActor (Error) -> Void
    ) async throws {
        guard let transcriber else { throw TranscriptionError.noAudioFormat }

        let (inputSequence, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        lock.withLock { inputContinuation = continuation }

        resultsTask = Task.detached(priority: .userInitiated) {
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    if result.isFinal {
                        await onEvent(.final(text))
                    } else {
                        await onEvent(.partial(text))
                    }
                }
            } catch is CancellationError {
                // 正常停止
            } catch {
                await onError(error)
            }
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer
        try await analyzer.start(inputSequence: inputSequence)
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        let continuation = lock.withLock { inputContinuation }
        continuation?.yield(AnalyzerInput(buffer: buffer))
    }

    func stop() async {
        let continuation = lock.withLock { () -> AsyncStream<AnalyzerInput>.Continuation? in
            let current = inputContinuation
            inputContinuation = nil
            return current
        }
        continuation?.finish()
        if let analyzer {
            try? await analyzer.finalizeAndFinishThroughEndOfInput()
        }
        // 等结果流结束（最多 3 秒）
        if let task = resultsTask {
            let timeout = Task {
                try? await Task.sleep(for: .seconds(3))
                task.cancel()
            }
            await task.value
            timeout.cancel()
        }
        resultsTask = nil
        analyzer = nil
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
