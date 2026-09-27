import AVFoundation
import ZimuCore

/// 把一段语音（16kHz 单声道 Float）转写成文字的后端：云端接口或本地 WhisperKit
protocol SegmentTranscriber: AnyObject {
    /// 准备（检查配置、下载 / 加载模型等）
    @MainActor func prepare(status: @escaping @MainActor (String) -> Void) async throws
    /// 转写一段语音
    /// - Parameter prompt: 前文，帮助识别专有名词（不支持时忽略）
    func transcribe(samples: [Float], prompt: String?) async throws -> (text: String, language: String?)
    /// 是否在说话过程中做临时识别（本地模型可以；云端会增加费用，不做）
    var supportsInterimResults: Bool { get }
}

/// 基于 VAD 切段的识别引擎：本地检测语音起止，每段交给 SegmentTranscriber 识别。
/// 说话过程中（支持时）定期对当前片段做临时识别，作为实时草稿。
final class SegmentedTranscriptionEngine: TranscriptionEngine {
    static let sampleRate: Double = 16_000

    private let transcriber: SegmentTranscriber
    private let queue = DispatchQueue(label: "zimu.segmented.vad")
    private let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
    private let work = SegmentWorkQueue()
    /// 临时识别的间隔（秒）
    private let interimInterval: TimeInterval = 1.2

    // 以下状态只在 queue 上访问
    private var vad: EnergyVAD
    private var isRunning = false
    private var lastInterim: TimeInterval = 0

    private var workerTask: Task<Void, Never>?

    init(transcriber: SegmentTranscriber, sensitivity: Double) {
        self.transcriber = transcriber
        var configuration = EnergyVAD.Configuration()
        configuration.sensitivity = sensitivity
        self.vad = EnergyVAD(configuration: configuration)
    }

    @MainActor
    func prepare(status: @escaping @MainActor (String) -> Void) async throws -> AVAudioFormat {
        try await transcriber.prepare(status: status)
        return format
    }

    @MainActor
    func start(
        onEvent: @escaping @MainActor (TranscriptEvent) -> Void,
        onError: @escaping @MainActor (_ error: Error, _ isFatal: Bool) -> Void
    ) async throws {
        work.reset()
        queue.sync {
            vad.reset()
            lastInterim = 0
            isRunning = true
        }
        let transcriber = self.transcriber
        let work = self.work
        let showsProgressDots = !transcriber.supportsInterimResults
        workerTask = Task.detached(priority: .userInitiated) {
            var previousText = ""
            loop: while let item = await work.next() {
                if Task.isCancelled { break }
                switch item {
                case .interim(let samples):
                    if let result = try? await transcriber.transcribe(samples: samples, prompt: nil) {
                        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !text.isEmpty, !TextUtilities.isOnlyPunctuation(text) {
                            await onEvent(.partial(text))
                        }
                    }
                case .final(let samples):
                    if showsProgressDots { await onEvent(.partial("…")) }
                    do {
                        let result = try await transcriber.transcribe(samples: samples, prompt: previousText)
                        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                        if text.isEmpty || TextUtilities.isOnlyPunctuation(text) {
                            await onEvent(.partial(""))
                        } else {
                            previousText = text
                            await onEvent(.final(text, language: result.language))
                        }
                    } catch is CancellationError {
                        break loop
                    } catch {
                        await onEvent(.partial(""))
                        await onError(error, false)
                    }
                }
            }
        }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        guard let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
        let samples = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
        let supportsInterim = transcriber.supportsInterimResults
        queue.async { [weak self] in
            guard let self, self.isRunning else { return }
            for segment in self.vad.process(samples) {
                self.work.pushFinal(segment)
            }
            guard supportsInterim, self.vad.isSpeaking else { return }
            let current = self.vad.currentSegment
            let duration = Double(current.count) / Self.sampleRate
            let now = ProcessInfo.processInfo.systemUptime
            if duration >= 1.0, now - self.lastInterim >= self.interimInterval {
                self.lastInterim = now
                self.work.pushInterim(current)
            }
        }
    }

    @MainActor
    func stop() async {
        queue.sync {
            if isRunning, let last = vad.flush() {
                work.pushFinal(last)
            }
            isRunning = false
        }
        work.finish()
        // 等最后一段识别完成（最多 10 秒）
        if let task = workerTask {
            let timeout = Task {
                try? await Task.sleep(for: .seconds(10))
                task.cancel()
                self.work.finish()
            }
            await task.value
            timeout.cancel()
        }
        workerTask = nil
    }
}

/// 识别工作队列：定稿片段按顺序处理；临时识别只保留最新一个，且定稿到来时丢弃
final class SegmentWorkQueue: @unchecked Sendable {
    enum Item {
        case final([Float])
        case interim([Float])
    }

    private let lock = NSLock()
    private var finals: [[Float]] = []
    private var interim: [Float]?
    private var waiter: CheckedContinuation<Item?, Never>?
    private var finished = false

    func reset() {
        lock.lock()
        finals.removeAll()
        interim = nil
        finished = false
        lock.unlock()
    }

    func pushFinal(_ samples: [Float]) {
        lock.lock()
        interim = nil
        if let waiter {
            self.waiter = nil
            lock.unlock()
            waiter.resume(returning: .final(samples))
            return
        }
        finals.append(samples)
        lock.unlock()
    }

    func pushInterim(_ samples: [Float]) {
        lock.lock()
        if let waiter {
            self.waiter = nil
            lock.unlock()
            waiter.resume(returning: .interim(samples))
            return
        }
        interim = samples
        lock.unlock()
    }

    func finish() {
        lock.lock()
        finished = true
        interim = nil
        let waiter = self.waiter
        self.waiter = nil
        lock.unlock()
        waiter?.resume(returning: nil)
    }

    func next() async -> Item? {
        await withCheckedContinuation { (continuation: CheckedContinuation<Item?, Never>) in
            lock.lock()
            if !finals.isEmpty {
                let item = finals.removeFirst()
                lock.unlock()
                continuation.resume(returning: .final(item))
                return
            }
            if let item = interim {
                interim = nil
                lock.unlock()
                continuation.resume(returning: .interim(item))
                return
            }
            if finished {
                lock.unlock()
                continuation.resume(returning: nil)
                return
            }
            waiter = continuation
            lock.unlock()
        }
    }
}

/// 云端识别：OpenAI 兼容的 /audio/transcriptions
final class CloudSegmentTranscriber: SegmentTranscriber {
    private let client: OpenAITranscriptionClient

    init(config: OpenAIServiceConfig, apiKey: String, sourceLanguage: String) {
        client = OpenAITranscriptionClient(
            config: config,
            apiKey: apiKey,
            language: Languages.isoLanguageCode(sourceLanguage),
            client: URLSessionHTTPClient()
        )
    }

    var supportsInterimResults: Bool { false }

    @MainActor
    func prepare(status: @escaping @MainActor (String) -> Void) async throws {
        _ = try OpenAIEndpoint.url(base: client.config.baseURL, path: OpenAIEndpoint.transcriptionsPath)
        if client.config.model.trimmingCharacters(in: .whitespaces).isEmpty {
            throw ServiceError.missingModel
        }
    }

    func transcribe(samples: [Float], prompt: String?) async throws -> (text: String, language: String?) {
        let wav = WAVEncoder.encode(samples: samples, sampleRate: Int(SegmentedTranscriptionEngine.sampleRate))
        let text = try await client.transcribe(wav: wav, prompt: prompt)
        return (text, client.language)
    }
}
