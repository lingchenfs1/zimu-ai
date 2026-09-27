import Foundation

/// 翻译引擎抽象。Apple 本地翻译在 App 层实现，OpenAI 兼容翻译在本包实现。
public protocol TranslationEngine: Sendable {
    /// 翻译一句字幕。
    /// - Parameters:
    ///   - text: 要翻译的句子
    ///   - sourceLanguage: 原文语言（BCP-47）；nil 表示未知，由引擎自行判断
    ///   - context: 前文（仅作参考）
    ///   - onPartial: 流式输出时收到的「累计译文」
    /// - Returns: 最终译文
    func translate(
        _ text: String,
        sourceLanguage: String?,
        context: [String],
        onPartial: @escaping @MainActor @Sendable (String) -> Void
    ) async throws -> String

    /// 一次翻译多句（不流式）。返回数量与输入相同。
    func translateBatch(_ texts: [String], sourceLanguage: String?) async throws -> [String]

    /// 批量翻译时每批最多几句；1 表示不批量
    var maxBatchSize: Int { get }
}

extension TranslationEngine {
    public var maxBatchSize: Int { 1 }

    public func translateBatch(_ texts: [String], sourceLanguage: String?) async throws -> [String] {
        var results: [String] = []
        for text in texts {
            results.append(try await translate(text, sourceLanguage: sourceLanguage, context: []) { _ in })
        }
        return results
    }

    /// 便捷方法：不指定源语言
    public func translate(
        _ text: String,
        context: [String],
        onPartial: @escaping @MainActor @Sendable (String) -> Void
    ) async throws -> String {
        try await translate(text, sourceLanguage: nil, context: context, onPartial: onPartial)
    }
}

/// 待翻译的一句字幕
public struct TranslationJob: Sendable, Equatable {
    public let id: Int
    public let text: String
    public let language: String?

    public init(id: Int, text: String, language: String?) {
        self.id = id
        self.text = text
        self.language = language
    }
}

/// 翻译调度：控制并发数、把排队的句子合并成批、积压过多时丢弃最旧的句子。
public struct TranslationScheduler: Sendable {
    /// 同时进行的翻译请求数
    public var maxConcurrent: Int
    /// 排队（尚未开始）的句子上限，超出时丢弃最旧的
    public var maxQueued: Int
    /// 每个请求最多包含几句（引擎支持批量时 > 1）
    public var maxBatchSize: Int

    public private(set) var queued: [TranslationJob] = []
    public private(set) var runningCount = 0

    public init(maxConcurrent: Int = 2, maxQueued: Int = 4, maxBatchSize: Int = 1) {
        self.maxConcurrent = max(1, maxConcurrent)
        self.maxQueued = max(1, maxQueued)
        self.maxBatchSize = max(1, maxBatchSize)
    }

    /// 加入队列，返回被丢弃的旧句子
    @discardableResult
    public mutating func enqueue(_ job: TranslationJob) -> [TranslationJob] {
        queued.append(job)
        guard queued.count > maxQueued else { return [] }
        let overflow = queued.count - maxQueued
        let dropped = Array(queued.prefix(overflow))
        queued.removeFirst(overflow)
        return dropped
    }

    /// 取出现在可以开始的批次（每批中的句子语言相同）
    public mutating func nextBatches() -> [[TranslationJob]] {
        var batches: [[TranslationJob]] = []
        while runningCount < maxConcurrent, let first = queued.first {
            var batch = [first]
            var index = 1
            while batch.count < maxBatchSize, index < queued.count, queued[index].language == first.language {
                batch.append(queued[index])
                index += 1
            }
            queued.removeFirst(batch.count)
            runningCount += 1
            batches.append(batch)
        }
        return batches
    }

    /// 一个批次完成（成功或失败）
    public mutating func finishBatch() {
        runningCount = max(0, runningCount - 1)
    }

    public mutating func reset() {
        queued.removeAll()
        runningCount = 0
    }
}
