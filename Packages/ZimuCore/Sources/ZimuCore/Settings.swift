import Foundation

/// 语音识别引擎类型
public enum TranscriptionEngineKind: String, Codable, CaseIterable, Sendable, Identifiable {
    case apple
    case openAICompatible

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .apple: return "Apple 本地识别"
        case .openAICompatible: return "OpenAI 兼容云端识别"
        }
    }
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
    /// 只捕获某个 App 的音频；nil 表示捕获全部系统音频
    public var captureBundleID: String?

    // MARK: 识别
    public var transcriptionEngine: TranscriptionEngineKind = .apple
    public var cloudTranscription = OpenAIServiceConfig(baseURL: "https://api.openai.com/v1", model: "gpt-4o-mini-transcribe")
    /// 云端识别的语音检测灵敏度 0...1
    public var vadSensitivity: Double = 0.5

    // MARK: 翻译
    public var translationEngine: TranslationEngineKind = .apple
    public var llmTranslation = OpenAIServiceConfig(baseURL: "https://api.openai.com/v1", model: "gpt-4o-mini")
    /// 翻译时附带的前文句数
    public var translationContextLines: Int = 3
    public var translationTemperature: Double = 0.3
    /// 追加到系统 prompt 的自定义要求
    public var customTranslationPrompt: String = ""

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
