import Foundation
import WhisperKit

// 注意：本文件不要 import ZimuCore —— WhisperKit 和 ZimuCore 都有 EnergyVAD / TextUtilities 类型，会重名。

enum WhisperKitTranscriberError: LocalizedError {
    case notLoaded

    var errorDescription: String? {
        switch self {
        case .notLoaded: return "Whisper 模型还没有加载"
        }
    }
}

/// 本地 WhisperKit 识别：自动检测语言（决策 D14）
final class WhisperKitTranscriber: SegmentTranscriber {
    /// 所有会话共用一个模型实例，避免每次开始都重新加载
    private static let runner = WhisperKitRunner()

    private let model: String
    private let endpoint: String
    /// ISO-639-1 语言代码；nil 表示自动检测
    private let language: String?

    init(model: String, endpoint: String, language: String) {
        self.model = model
        self.endpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmed = language.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed.lowercased() == "auto" {
            self.language = nil
        } else {
            self.language = trimmed
                .split(whereSeparator: { $0 == "-" || $0 == "_" })
                .first
                .map { String($0).lowercased() }
        }
    }

    var supportsInterimResults: Bool { true }

    @MainActor
    func prepare(status: @escaping @MainActor (String) -> Void) async throws {
        try await Self.runner.load(model: model, endpoint: endpoint, status: status)
    }

    func transcribe(samples: [Float], prompt: String?) async throws -> (text: String, language: String?) {
        try await Self.runner.transcribe(samples, language: language)
    }

    /// 模型保存位置：~/Library/Application Support/ZimuAI/WhisperKit
    static var modelsDirectory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return support.appendingPathComponent("ZimuAI/WhisperKit", isDirectory: true)
    }

    static func isModelDownloaded(_ model: String) -> Bool {
        let folder = modelsDirectory
            .appendingPathComponent("models/argmaxinc/whisperkit-coreml", isDirectory: true)
            .appendingPathComponent(model, isDirectory: true)
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return !contents.isEmpty
    }
}

/// 持有 WhisperKit 实例的 actor（WhisperKit 不是 Sendable，只在这里使用）
actor WhisperKitRunner {
    static let defaultEndpoint = "https://huggingface.co"

    private var pipe: WhisperKit?
    private var loadedModel: String?

    func load(model: String, endpoint: String, status: @escaping @MainActor (String) -> Void) async throws {
        if pipe != nil, loadedModel == model { return }
        pipe = nil
        loadedModel = nil

        let base = WhisperKitTranscriber.modelsDirectory
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        var remote = endpoint.isEmpty ? Self.defaultEndpoint : endpoint
        while remote.hasSuffix("/") { remote.removeLast() }
        // 分词器的下载不使用 endpoint 参数，只读 HF_ENDPOINT 环境变量
        if endpoint.isEmpty {
            unsetenv("HF_ENDPOINT")
        } else {
            setenv("HF_ENDPOINT", remote, 1)
        }

        await status("正在准备 Whisper 模型…")
        let folder = try await WhisperKit.download(
            variant: model,
            downloadBase: base,
            useBackgroundSession: false,
            from: "argmaxinc/whisperkit-coreml",
            endpoint: remote
        ) { progress in
            let percent = Int(progress.fractionCompleted * 100)
            Task { @MainActor in
                status("正在下载 Whisper 模型… \(percent)%")
            }
        }
        try Task.checkCancellation()

        await status("正在加载 Whisper 模型（第一次加载需要编译，可能要一两分钟）…")
        let config = WhisperKitConfig(
            model: model,
            downloadBase: base,
            modelEndpoint: remote,
            modelFolder: folder.path,
            tokenizerFolder: base,
            verbose: false,
            logLevel: .error,
            prewarm: true,
            load: true,
            download: false
        )
        pipe = try await WhisperKit(config)
        loadedModel = model
    }

    func transcribe(_ samples: [Float], language: String?) async throws -> (text: String, language: String?) {
        guard let pipe else { throw WhisperKitTranscriberError.notLoaded }
        // 自动检测语言必须同时设置 usePrefillPrompt 和 detectLanguage，否则会被当成英语
        let options = DecodingOptions(
            task: .transcribe,
            language: language,
            temperature: 0,
            usePrefillPrompt: true,
            detectLanguage: language == nil,
            skipSpecialTokens: true,
            withoutTimestamps: true,
            chunkingStrategy: ChunkingStrategy.none
        )
        let results = try await pipe.transcribe(audioArray: samples, decodeOptions: options)
        let text = results
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return (text, results.first?.language ?? language)
    }
}
