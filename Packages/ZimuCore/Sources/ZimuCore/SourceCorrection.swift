import Foundation

/// 「用 AI 校对识别文字」的输出解析与安全检查（决策 D20）。
///
/// 模型按 `<source>校正后的原文</source><translation>译文</translation>` 输出；
/// 没按格式输出时整段当作译文，原文保持不变。
public enum SourceCorrection {
    public struct Result: Sendable, Equatable {
        /// 校正后的原文；模型没有给出时为 nil
        public var source: String?
        public var translation: String

        public init(source: String?, translation: String) {
            self.source = source
            self.translation = translation
        }
    }

    /// 校正前后差异超过这个比例（归一化编辑距离）时不采用
    public static let maximumChangeRatio = 0.5

    /// 解析模型输出（会先去掉推理内容）。isPartial 为 true 表示流式输出还没结束
    public static func parse(_ raw: String, isPartial: Bool = false) -> Result {
        let text = ReasoningFilter.strip(raw)
        let source = section("source", in: text, isPartial: isPartial)
            .map(clean)
            .flatMap { $0.isEmpty ? nil : $0 }

        let translation: String
        if let tagged = section("translation", in: text, isPartial: isPartial) {
            translation = tagged
        } else if let sourceClose = text.range(of: "</source>", options: .caseInsensitive) {
            // 模型给了 <source> 但没有 <translation> 标签：后面的内容当作译文
            translation = String(text[sourceClose.upperBound...])
        } else if text.range(of: "<source>", options: .caseInsensitive) != nil {
            // 还在输出校正后的原文
            translation = ""
        } else if isPartial, text.drop(while: { $0.isWhitespace }).hasPrefix("<") {
            // 标签还没输出完整
            translation = ""
        } else {
            translation = text
        }
        return Result(source: source, translation: TranslationPrompt.cleanOutput(translation))
    }

    /// 返回应该采用的校正后原文；没有变化、为空或改动过大时返回 nil
    public static func accepted(original: String, corrected: String?) -> String? {
        guard let corrected = corrected?.trimmingCharacters(in: .whitespacesAndNewlines), !corrected.isEmpty else { return nil }
        let original = original.trimmingCharacters(in: .whitespacesAndNewlines)
        guard corrected != original else { return nil }
        let a = Array(TextUtilities.normalizedForComparison(original))
        let b = Array(TextUtilities.normalizedForComparison(corrected))
        guard !a.isEmpty, !b.isEmpty else { return nil }
        let ratio = Double(editDistance(a, b)) / Double(max(a.count, b.count))
        return ratio <= maximumChangeRatio ? corrected : nil
    }

    /// 取出 <tag>…</tag> 的内容；流式输出中结束标签还没到时取到末尾
    static func section(_ tag: String, in text: String, isPartial: Bool) -> String? {
        guard let open = text.range(of: "<\(tag)>", options: .caseInsensitive) else { return nil }
        let rest = text[open.upperBound...]
        if let close = rest.range(of: "</\(tag)>", options: .caseInsensitive) {
            return String(rest[..<close.lowerBound])
        }
        // 未闭合：流式中取到末尾（去掉可能输出了一半的结束标签）；完整输出时也取到末尾
        var body = String(rest)
        if isPartial, let lt = body.lastIndex(of: "<"), "</\(tag)>".hasPrefix(body[lt...].lowercased()) {
            body = String(body[..<lt])
        }
        return body
    }

    private static func clean(_ text: String) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.count >= 2, let first = result.first, let last = result.last,
           (first == "\"" && last == "\"") || (first == "“" && last == "”") {
            result = String(result.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return result
    }

    /// 字符级编辑距离（Levenshtein）
    static func editDistance(_ a: [Character], _ b: [Character]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }
}
