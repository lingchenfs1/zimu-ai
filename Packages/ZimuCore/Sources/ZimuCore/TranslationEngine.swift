import Foundation

/// 翻译引擎抽象。Apple 本地翻译在 App 层实现，OpenAI 兼容翻译在本包实现。
public protocol TranslationEngine: Sendable {
    /// 翻译一句字幕。
    /// - Parameters:
    ///   - text: 要翻译的句子
    ///   - context: 前文（仅作参考）
    ///   - onPartial: 流式输出时收到的「累计译文」
    /// - Returns: 最终译文
    func translate(
        _ text: String,
        context: [String],
        onPartial: @escaping @MainActor @Sendable (String) -> Void
    ) async throws -> String
}
