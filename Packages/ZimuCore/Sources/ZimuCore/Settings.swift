import Foundation

/// 语音识别引擎类型
public enum TranscriptionEngineKind: String, Codable, CaseIterable, Sendable, Identifiable {
    case apple
    case appleMultilingual
    case whisperKit
    case openAICompatible

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .apple: return "Apple 本地识别（单一语言）"
        case .appleMultilingual: return "Apple 本地识别（多语言自动切换）"
        case .whisperKit: return "WhisperKit 本地识别（自动检测语言）"
        case .openAICompatible: return "OpenAI 兼容云端识别（可自动检测语言）"
        }
    }

    /// 是否支持「自动检测」原声语言
    public var supportsAutoDetect: Bool {
        switch self {
        case .apple, .appleMultilingual: return false
        case .whisperKit, .openAICompatible: return true
        }
    }
}

/// Apple 本地识别的识别模式（决策 D19）
public enum RecognitionMode: String, Codable, CaseIterable, Sendable, Identifiable {
    /// 准确优先：定稿稍晚，错字更少
    case accurate
    /// 速度优先：定稿更快，准确度略低（SpeechTranscriber 的 fastResults）
    case fast

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .accurate: return "准确优先（推荐）"
        case .fast: return "速度优先"
        }
    }
}

/// 翻译场景：在内置提示词之外追加对应的风格要求
public enum TranslationScenario: String, Codable, CaseIterable, Sendable, Identifiable {
    case general
    case film
    case lecture
    case news
    case gaming

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .general: return "通用"
        case .film: return "影视剧对白"
        case .lecture: return "课程讲座 / 技术分享"
        case .news: return "新闻访谈"
        case .gaming: return "游戏直播"
        }
    }

    /// 追加到系统提示词的场景说明（英文，模型遵循得更好）
    public var promptInstructions: String? {
        switch self {
        case .general:
            return nil
        case .film:
            return "Scenario: movie / TV dialogue. Use colloquial, natural spoken language that fits the character and emotion; keep slang, jokes and tone; be very concise."
        case .lecture:
            return "Scenario: lecture, course or tech talk. Translate technical terms accurately and consistently; keep well-known English terms, product names and code identifiers as is; be clear and precise."
        case .news:
            return "Scenario: news or interview. Use a formal, accurate and neutral tone; keep names, titles, organizations, places and numbers precise."
        case .gaming:
            return "Scenario: game or live stream. Use a casual, lively tone; keep game terms, character, skill and item names as commonly used by players."
        }
    }
}

/// WhisperKit 可选模型
public struct WhisperModelOption: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let sizeDescription: String

    public init(id: String, name: String, sizeDescription: String) {
        self.id = id
        self.name = name
        self.sizeDescription = sizeDescription
    }

    public static let all: [WhisperModelOption] = [
        WhisperModelOption(id: "openai_whisper-tiny", name: "Tiny（最快，准确度一般）", sizeDescription: "约 75 MB"),
        WhisperModelOption(id: "openai_whisper-base", name: "Base（推荐）", sizeDescription: "约 145 MB"),
        WhisperModelOption(id: "openai_whisper-small", name: "Small（更准确）", sizeDescription: "约 480 MB"),
        WhisperModelOption(id: "openai_whisper-large-v3-v20240930_turbo_632MB", name: "Large v3 Turbo（最准确，需要较强性能）", sizeDescription: "约 632 MB"),
    ]
}

/// 翻译引擎类型
public enum TranslationEngineKind: String, Codable, CaseIterable, Sendable, Identifiable {
    case none
    case apple
    case openAICompatible

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .none: return "不翻译"
        case .apple: return "Apple 本地翻译"
        case .openAICompatible: return "OpenAI 兼容服务"
        }
    }
}

/// 字幕显示模式
public enum SubtitleDisplayMode: String, Codable, CaseIterable, Sendable, Identifiable {
    case bilingual
    case translationOnly
    case originalOnly

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .bilingual: return "双语（原文 + 译文）"
        case .translationOnly: return "仅译文"
        case .originalOnly: return "仅原文"
        }
    }

    public var showsOriginal: Bool { self != .translationOnly }
    public var showsTranslation: Bool { self != .originalOnly }
}

/// OpenAI 兼容服务的连接配置（API Key 不在这里，单独存 Keychain）
public struct OpenAIServiceConfig: Codable, Equatable, Sendable {
    public var baseURL: String
    public var model: String

    public init(baseURL: String, model: String) {
        self.baseURL = baseURL
        self.model = model
    }
}

/// 悬浮窗位置与大小（屏幕坐标）
public struct OverlayFrame: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

/// 应用的全部用户设置。以 JSON 形式保存在 UserDefaults 中。
public struct AppSettings: Codable, Equatable, Sendable {
    // MARK: 通用
    /// 源语言（BCP-47，例如 "en-US"）。云端识别可用 "auto" 表示自动检测。
    public var sourceLanguage: String = "en-US"
    /// 目标语言（BCP-47，例如 "zh-Hans"）
    public var targetLanguage: String = "zh-Hans"
    /// 同时翻译成的其他语言（主目标语言之外，最多 maximumAdditionalTargets 种；决策 D17）
    public var additionalTargetLanguages: [String] = []
    /// 只捕获某个 App 的音频；nil 表示捕获全部系统音频
    public var captureBundleID: String?

    // MARK: 识别
    public var transcriptionEngine: TranscriptionEngineKind = .apple
    public var cloudTranscription = OpenAIServiceConfig(baseURL: "https://api.openai.com/v1", model: "gpt-4o-mini-transcribe")
    /// 云端识别 / WhisperKit 的语音检测灵敏度 0...1
    public var vadSensitivity: Double = 0.5
    /// Apple 多语言识别的候选语言（2～4 种）
    public var appleCandidateLanguages: [String] = ["en-US", "zh-CN", "ja-JP"]
    /// WhisperKit 模型
    public var whisperModel: String = "openai_whisper-base"
    /// WhisperKit 模型下载地址（HuggingFace 镜像），空表示官方地址
    public var whisperEndpoint: String = ""
    /// Apple 本地识别的识别模式（决策 D19）
    public var recognitionMode: RecognitionMode = .accurate
    /// 专有名词（人名、术语），一行一个或用逗号分隔：用于翻译提示词、AI 校对和云端识别
    public var glossary: String = ""
    /// 纠错替换，一行一条「错 → 对」：对识别结果生效
    public var correctionRules: String = ""

    // MARK: 翻译
    public var translationEngine: TranslationEngineKind = .apple
    public var llmTranslation = OpenAIServiceConfig(baseURL: "https://api.openai.com/v1", model: "gpt-4o-mini")
    /// 翻译时附带的前文句数
    public var translationContextLines: Int = 3
    public var translationTemperature: Double = 0.3
    /// 追加到系统 prompt 的自定义要求
    public var customTranslationPrompt: String = ""
    /// 识别过程中实时翻译还没说完的句子（Apple 本地翻译免费且快，建议开启；云端服务会增加调用次数）
    public var liveTranslation: Bool = true
    /// OpenAI 兼容翻译的并发请求数
    public var translationConcurrency: Int = 3
    /// OpenAI 兼容翻译的额外请求参数（JSON）
    public var llmExtraBody: String = ""
    /// OpenAI 兼容翻译：按服务自动附加关闭模型思考的参数（决策 D18）
    public var disableThinking: Bool = true
    /// 翻译场景
    public var translationScenario: TranslationScenario = .general
    /// 用 AI 校对识别文字（仅 OpenAI 兼容翻译，决策 D20）
    public var aiSourceCorrection: Bool = false

    // MARK: 外观
    public var displayMode: SubtitleDisplayMode = .bilingual
    public var originalFontSize: Double = 20
    public var translationFontSize: Double = 28
    public var originalColorHex: String = "#FFFFFF"
    public var translationColorHex: String = "#FFD60A"
    /// 字幕背景不透明度 0...1
    public var backgroundOpacity: Double = 0.45
    /// 文字不透明度 0.2...1
    public var textOpacity: Double = 1.0
    public var cornerRadius: Double = 12
    public var boldText: Bool = true
    /// 同时显示的字幕条数
    public var maxVisibleEntries: Int = 2
    /// 多少秒没有新内容后隐藏字幕
    public var clearAfterSeconds: Double = 8
    /// 显示识别中的实时草稿
    public var showLiveText: Bool = true

    // MARK: 悬浮窗
    public var overlayLocked: Bool = false
    public var overlayVisible: Bool = true
    public var overlayFrame: OverlayFrame?

    // MARK: 快捷键
    public var hotkeysEnabled: Bool = true

    public init() {}

    /// 主目标语言之外最多再同时翻译成几种语言
    public static let maximumAdditionalTargets = 2

    /// 实际要翻译成的语言：主目标语言在前，去掉重复，最多 1 + maximumAdditionalTargets 种
    public var translationTargets: [String] {
        var targets = [targetLanguage]
        for code in additionalTargetLanguages where !code.isEmpty && !targets.contains(code) {
            guard targets.count < 1 + Self.maximumAdditionalTargets else { break }
            targets.append(code)
        }
        return targets
    }
}

/// 设置的读写：缺失字段使用默认值，便于以后新增设置项时兼容旧数据。
public enum SettingsCoder {
    public static func encode(_ settings: AppSettings) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(settings)
    }

    public static func decode(_ data: Data?) -> AppSettings {
        guard let data,
              let stored = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let defaultsData = encode(AppSettings()),
              let defaults = try? JSONSerialization.jsonObject(with: defaultsData) as? [String: Any]
        else { return AppSettings() }

        let merged = deepMerge(defaults, stored)
        guard let mergedData = try? JSONSerialization.data(withJSONObject: merged),
              let settings = try? JSONDecoder().decode(AppSettings.self, from: mergedData)
        else { return AppSettings() }
        return settings
    }

    static func deepMerge(_ base: [String: Any], _ overlay: [String: Any]) -> [String: Any] {
        var result = base
        for (key, value) in overlay {
            if let baseDict = base[key] as? [String: Any], let overlayDict = value as? [String: Any] {
                result[key] = deepMerge(baseDict, overlayDict)
            } else {
                result[key] = value
            }
        }
        return result
    }
}
