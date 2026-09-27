import AVFoundation
import ZimuCore

/// 云端识别：本地 VAD 切段后上传到 OpenAI 兼容的 /audio/transcriptions 接口
final class OpenAICompatibleSTTEngine: TranscriptionEngine {
    private let client: OpenAITranscriptionClient
    private let sensitivity: Double
    private let queue = DispatchQueue(label: "zimu.stt.vad")
    private let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!

    // 以下状态只在 queue 上访问
    private var vad: EnergyVAD
    private var isRunning = false
    private var segmentContinuation: AsyncStream<[Float]>.Continuation?

    private var uploadTask: Task<Void, Never>?

    init(config: OpenAIServiceConfig, apiKey: String, sourceLanguage: String, sensitivity: Double) {
        self.client = OpenAITranscriptionClient(
            config: config,
            apiKey: apiKey,
            language: Languages.isoLanguageCode(sourceLanguage),
            client: URLSessionHTTPClient()
        )
        self.sensitivity = sensitivity
        var configuration = EnergyVAD.Configuration()
        configuration.sensitivity = sensitivity
        self.vad = EnergyVAD(configuration: configuration)
    }

    func prepare(status: @escaping @MainActor (String) -> Void) async throws -> AVAudioFormat {
        _ = try OpenAIEndpoint.url(base: client.config.baseURL, path: OpenAIEndpoint.transcriptionsPath)
        if client.config.model.trimmingCharacters(in: .whitespaces).isEmpty {
            throw ServiceError.missingModel
        }
        return format
    }

    func start(
        onEvent: @escaping @MainActor (TranscriptEvent) -> Void,
        onError: @escaping @MainActor (Error) -> Void
    ) async throws {
        let (segments, continuation) = AsyncStream<[Float]>.makeStream(bufferingPolicy: .bufferingNewest(4))
        queue.sync {
            vad.reset()
            segmentContinuation = continuation
            isRunning = true
        }
        let client = self.client
        uploadTask = Task.detached(priority: .userInitiated) {
            var previousText = ""
            for await samples in segments {
                if Task.isCancelled { break }
                await onEvent(.partial("…"))
                let wav = WAVEncoder.encode(samples: samples, sampleRate: 16_000)
                do {
                    let text = try await client.transcribe(wav: wav, prompt: previousText)
                    let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if cleaned.isEmpty || TextUtilities.isOnlyPunctuation(cleaned) {
                        await onEvent(.partial(""))
                    } else {
                        previousText = cleaned
                        await onEvent(.final(cleaned))
                    }
                } catch is CancellationError {
                    break
                } catch {
                    await onEvent(.partial(""))
                    await onError(error)
                }
            }
        }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        guard let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
        let samples = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
        queue.async { [weak self] in
            guard let self, self.isRunning else { return }
            for segment in self.vad.process(samples) {
                self.segmentContinuation?.yield(segment)
            }
        }
    }

    func stop() async {
        queue.sync {
            if isRunning, let last = vad.flush() {
                segmentContinuation?.yield(last)
            }
            isRunning = false
            segmentContinuation?.finish()
            segmentContinuation = nil
        }
        // 等最后一段上传完成（最多 10 秒）
        if let task = uploadTask {
            let timeout = Task {
                try? await Task.sleep(for: .seconds(10))
                task.cancel()
            }
            await task.value
            timeout.cancel()
        }
        uploadTask = nil
    }
}
