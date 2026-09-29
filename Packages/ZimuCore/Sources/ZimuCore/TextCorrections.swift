import Foundation

/// 识别结果的「纠错替换」和「专有名词」（决策 D19）。
///
/// Apple SpeechTranscriber 没有自定义词汇接口，经常听错的人名、术语用替换规则在识别后纠正。
public struct TextCorrections: Sendable, Equatable {
    public struct Rule: Sendable, Equatable {
        public let from: String
        public let to: String

        public init(from: String, to: String) {
            self.from = from
            self.to = to
        }
    }

    public let rules: [Rule]

    public init(rules: [Rule]) {
        self.rules = rules
    }

    /// 解析设置中的文本：一行一条，`错 → 对`（也支持 `->`、`=>`、`=`）；空行和 # 开头的行忽略
    public init(parsing text: String) {
        var rules: [Rule] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            for separator in ["→", "->", "=>", "="] {
                if let range = trimmed.range(of: separator) {
                    let from = trimmed[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
                    let to = trimmed[range.upperBound...].trimmingCharacters(in: .whitespaces)
                    if !from.isEmpty {
                        rules.append(Rule(from: from, to: to))
                    }
                    break
                }
            }
        }
        self.rules = rules
    }

    public var isEmpty: Bool { rules.isEmpty }

    /// 应用全部规则。含字母数字的拉丁文字按整词、不区分大小写匹配；中日韩等文字按子串匹配
    public func apply(to text: String) -> String {
        guard !rules.isEmpty, !text.isEmpty else { return text }
        var result = text
        for rule in rules {
            if Self.usesWordBoundaries(rule.from) {
                let pattern = "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: rule.from) + "(?![\\p{L}\\p{N}])"
                guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
                let range = NSRange(result.startIndex..., in: result)
                result = regex.stringByReplacingMatches(
                    in: result,
                    range: range,
                    withTemplate: NSRegularExpression.escapedTemplate(for: rule.to)
                )
            } else {
                result = result.replacingOccurrences(of: rule.from, with: rule.to)
            }
        }
        return result
    }

    /// 规则左边全是拉丁等有空格分词的文字时按整词匹配
    static func usesWordBoundaries(_ text: String) -> Bool {
        !TextUtilities.isMostlyNoSpaceScript(text) && text.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) }
    }
}

/// 专有名词列表
public enum Glossary {
    /// 解析设置中的文本：按换行、逗号、顿号、分号分隔，去重
    public static func terms(from text: String) -> [String] {
        let separators: Set<Character> = [",", "，", "、", ";", "；"]
        var result: [String] = []
        for part in text.split(whereSeparator: { $0.isNewline || separators.contains($0) }) {
            let term = part.trimmingCharacters(in: .whitespaces)
            if !term.isEmpty, !result.contains(term) {
                result.append(term)
            }
        }
        return result
    }
}
