import Foundation

/// 去掉大模型输出中的推理（思维链）内容（决策 D18）。
///
/// 常见形式：
/// - 成对的 `<think>…</think>`（也有 `<thinking>`、`<reasoning>`、`<thought>`）；
/// - 只有结束标签：聊天模板把 `<think>` 放进了提示里，模型只输出「推理…</think>译文」（本机 Qwen3 / R1 常见）；
/// - gpt-oss 的 harmony 格式：`<|channel|>analysis<|message|>…<|end|><|start|>assistant<|channel|>final<|message|>译文`。
public enum ReasoningFilter {
    static let tagNames = ["think", "thinking", "reasoning", "thought"]
    static let harmonyFinalMarker = "<|channel|>final<|message|>"
    static let harmonyChannelMarker = "<|channel|>"

    /// 删除推理内容，返回剩下的正文（不做其他清理）。
    /// 推理块还没结束（流式输出中）时返回推理开始之前的部分，通常为空。
    public static func strip(_ raw: String) -> String {
        var text = raw

        // gpt-oss harmony：只保留最后一个 final 频道的内容；只有 analysis 频道时说明还在推理
        if let final = text.range(of: harmonyFinalMarker, options: .backwards) {
            text = String(text[final.upperBound...])
        } else if text.contains(harmonyChannelMarker) {
            return ""
        }
        text = removeHarmonyTokens(text)

        // 有结束标签：结束标签之前的都是推理（同时覆盖成对标签和只有结束标签两种情况）
        if let close = lastClosingTag(in: text) {
            text = String(text[close.upperBound...])
        }
        // 还有未闭合的开始标签：推理尚未结束，丢掉从开始标签起的内容
        if let open = firstOpeningTag(in: text) {
            text = String(text[..<open.lowerBound])
        }
        return text
    }

    /// 输出中是否出现过推理（结束标签或 harmony 频道标记）
    public static func containsReasoning(_ raw: String) -> Bool {
        lastClosingTag(in: raw) != nil
            || firstOpeningTag(in: raw) != nil
            || raw.contains(harmonyChannelMarker)
    }

    /// 推理是否已经结束（出现了结束标签或 harmony 的 final 频道）
    public static func reasoningFinished(_ raw: String) -> Bool {
        lastClosingTag(in: raw) != nil || raw.contains(harmonyFinalMarker)
    }

    /// 文本（去掉开头空白后）是否可能是推理标签的开头，例如流式输出只收到了 "<th"
    public static func mayStartWithReasoningTag(_ raw: String) -> Bool {
        let head = raw.drop(while: { $0.isWhitespace || $0.isNewline }).lowercased()
        guard head.hasPrefix("<") else { return false }
        let candidates = tagNames.map { "<\($0)>" } + [harmonyChannelMarker, "<|start|>"]
        return candidates.contains { $0.hasPrefix(head) || head.hasPrefix($0) }
    }

    private static func lastClosingTag(in text: String) -> Range<String.Index>? {
        tagNames
            .compactMap { text.range(of: "</\($0)>", options: [.caseInsensitive, .backwards]) }
            .max(by: { $0.upperBound < $1.upperBound })
    }

    private static func firstOpeningTag(in text: String) -> Range<String.Index>? {
        tagNames
            .compactMap { text.range(of: "<\($0)>", options: .caseInsensitive) }
            .min(by: { $0.lowerBound < $1.lowerBound })
    }

    /// 去掉 `<|end|>`、`<|start|>`、`<|message|>` 之类的特殊标记
    private static func removeHarmonyTokens(_ text: String) -> String {
        guard text.contains("<|") else { return text }
        return text.replacingOccurrences(of: #"<\|[^|<>]{0,40}\|>"#, with: "", options: .regularExpression)
    }
}

/// 流式翻译输出的显示过滤：推理还没结束时不显示，只显示正文（决策 D18）
public struct StreamingTranslationFilter: Sendable {
    /// 这个模型之前输出过推理：本次在推理结束标记出现之前都不显示
    public let expectsReasoning: Bool
    /// AI 校对模式：输出包含 <source> 和 <translation>，只显示译文部分
    public let correctsSource: Bool
    public private(set) var raw = ""

    public init(expectsReasoning: Bool = false, correctsSource: Bool = false) {
        self.expectsReasoning = expectsReasoning
        self.correctsSource = correctsSource
    }

    /// 本次输出中是否出现了推理内容
    public var sawReasoning: Bool { ReasoningFilter.containsReasoning(raw) }

    /// 追加一段流式输出，返回现在可以显示的译文；nil 表示暂时不显示
    public mutating func append(_ piece: String) -> String? {
        raw += piece
        let finished = ReasoningFilter.reasoningFinished(raw)
        if expectsReasoning, !finished {
            return nil
        }
        if ReasoningFilter.mayStartWithReasoningTag(raw), !finished {
            return nil
        }
        let text = correctsSource
            ? SourceCorrection.parse(raw, isPartial: true).translation
            : TranslationPrompt.cleanOutput(raw)
        return text.isEmpty ? nil : text
    }

    /// 完整输出清理后的译文
    public var finalText: String {
        correctsSource ? SourceCorrection.parse(raw).translation : TranslationPrompt.cleanOutput(raw)
    }

    /// AI 校对模式下的完整解析结果
    public var correction: SourceCorrection.Result { SourceCorrection.parse(raw) }
}
