import Foundation

/// 可选的翻译目标语言
public struct LanguageOption: Hashable, Sendable, Identifiable {
    public let code: String
    public let name: String
    public let englishName: String

    public var id: String { code }

    public init(code: String, name: String, englishName: String) {
        self.code = code
        self.name = name
        self.englishName = englishName
    }
}

public enum Languages {
    public static let targets: [LanguageOption] = [
        LanguageOption(code: "zh-Hans", name: "简体中文", englishName: "Simplified Chinese"),
        LanguageOption(code: "zh-Hant", name: "繁體中文", englishName: "Traditional Chinese"),
        LanguageOption(code: "en", name: "英语", englishName: "English"),
        LanguageOption(code: "ja", name: "日语", englishName: "Japanese"),
        LanguageOption(code: "ko", name: "韩语", englishName: "Korean"),
        LanguageOption(code: "fr", name: "法语", englishName: "French"),
        LanguageOption(code: "de", name: "德语", englishName: "German"),
        LanguageOption(code: "es", name: "西班牙语", englishName: "Spanish"),
        LanguageOption(code: "pt-BR", name: "葡萄牙语（巴西）", englishName: "Brazilian Portuguese"),
        LanguageOption(code: "it", name: "意大利语", englishName: "Italian"),
        LanguageOption(code: "ru", name: "俄语", englishName: "Russian"),
        LanguageOption(code: "ar", name: "阿拉伯语", englishName: "Arabic"),
        LanguageOption(code: "th", name: "泰语", englishName: "Thai"),
        LanguageOption(code: "vi", name: "越南语", englishName: "Vietnamese"),
        LanguageOption(code: "id", name: "印尼语", englishName: "Indonesian"),
        LanguageOption(code: "hi", name: "印地语", englishName: "Hindi"),
        LanguageOption(code: "tr", name: "土耳其语", englishName: "Turkish"),
        LanguageOption(code: "nl", name: "荷兰语", englishName: "Dutch"),
        LanguageOption(code: "pl", name: "波兰语", englishName: "Polish"),
        LanguageOption(code: "uk", name: "乌克兰语", englishName: "Ukrainian"),
    ]

    public static func option(for code: String) -> LanguageOption? {
        if let exact = targets.first(where: { $0.code.caseInsensitiveCompare(code) == .orderedSame }) {
            return exact
        }
        let base = isoLanguageCode(code)
        return targets.first(where: { isoLanguageCode($0.code) == base })
    }

    /// 用于 prompt 的英文语言名
    public static func englishName(for code: String) -> String {
        option(for: code)?.englishName ?? code
    }

    /// 提示词中针对目标语言的字幕风格说明
    public static func subtitleStyleHint(for code: String) -> String {
        let lower = code.lowercased()
        if lower.hasPrefix("zh-hant") || lower == "zh-tw" || lower == "zh-hk" {
            return "Use Traditional Chinese with full-width punctuation (，。？！) and no spaces between Chinese characters."
        }
        switch isoLanguageCode(code) {
        case "zh":
            return "Use Simplified Chinese with full-width punctuation (，。？！) and no spaces between Chinese characters."
        case "ja":
            return "Use natural spoken Japanese with Japanese punctuation (、。？！)."
        case "ko":
            return "Use natural spoken Korean."
        default:
            return "Use natural, conversational \(englishName(for: code))."
        }
    }

    /// 用于界面的中文语言名
    public static func displayName(for code: String) -> String {
        option(for: code)?.name ?? code
    }

    /// "en-US" → "en"，"zh-Hans" → "zh"，"auto" → nil
    public static func isoLanguageCode(_ code: String) -> String? {
        let trimmed = code.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.lowercased() != "auto" else { return nil }
        let separators: Set<Character> = ["-", "_"]
        let base = trimmed.split(whereSeparator: { separators.contains($0) }).first.map(String.init) ?? trimmed
        return base.lowercased()
    }
}
