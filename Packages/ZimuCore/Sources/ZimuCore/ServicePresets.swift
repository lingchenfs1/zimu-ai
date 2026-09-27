import Foundation

/// 常见 OpenAI 兼容服务的预设（模型名可以在设置中修改）
public struct ServicePreset: Identifiable, Hashable, Sendable {
    public let name: String
    public let baseURL: String
    public let model: String
    public let needsAPIKey: Bool

    public var id: String { name }

    public init(name: String, baseURL: String, model: String, needsAPIKey: Bool = true) {
        self.name = name
        self.baseURL = baseURL
        self.model = model
        self.needsAPIKey = needsAPIKey
    }
}

public enum ServicePresets {
    public static let translation: [ServicePreset] = [
        ServicePreset(name: "OpenAI", baseURL: "https://api.openai.com/v1", model: "gpt-4o-mini"),
        ServicePreset(name: "DeepSeek", baseURL: "https://api.deepseek.com/v1", model: "deepseek-chat"),
        ServicePreset(name: "通义千问（阿里云百炼）", baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1", model: "qwen-plus"),
        ServicePreset(name: "Kimi（月之暗面）", baseURL: "https://api.moonshot.cn/v1", model: "moonshot-v1-8k"),
        ServicePreset(name: "智谱 GLM", baseURL: "https://open.bigmodel.cn/api/paas/v4", model: "glm-4-flash"),
        ServicePreset(name: "硅基流动", baseURL: "https://api.siliconflow.cn/v1", model: "Qwen/Qwen2.5-7B-Instruct"),
        ServicePreset(name: "OpenRouter", baseURL: "https://openrouter.ai/api/v1", model: "openai/gpt-4o-mini"),
        ServicePreset(name: "Ollama（本机）", baseURL: "http://localhost:11434/v1", model: "qwen2.5:7b", needsAPIKey: false),
        ServicePreset(name: "LM Studio（本机）", baseURL: "http://localhost:1234/v1", model: "local-model", needsAPIKey: false),
    ]

    public static let transcription: [ServicePreset] = [
        ServicePreset(name: "OpenAI", baseURL: "https://api.openai.com/v1", model: "gpt-4o-mini-transcribe"),
        ServicePreset(name: "OpenAI Whisper", baseURL: "https://api.openai.com/v1", model: "whisper-1"),
        ServicePreset(name: "Groq", baseURL: "https://api.groq.com/openai/v1", model: "whisper-large-v3-turbo"),
        ServicePreset(name: "硅基流动", baseURL: "https://api.siliconflow.cn/v1", model: "FunAudioLLM/SenseVoiceSmall"),
        ServicePreset(name: "本机 whisper 服务", baseURL: "http://localhost:8000/v1", model: "whisper-1", needsAPIKey: false),
    ]
}
