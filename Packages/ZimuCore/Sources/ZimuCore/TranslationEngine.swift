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

/// 待翻译的一句字幕（翻译成一种目标语言）
public struct TranslationJob: Sendable, Equatable {
    public let id: Int
    public let text: String
    /// 原文语言（BCP-47，未知为 nil）
    public let language: String?
    /// 目标语言（BCP-47）
    public let target: String

    public init(id: Int, text: String, language: String?, target: String) {
        self.id = id
        self.text = text
        self.language = language
        self.target = target
    }
}

/// 翻译调度：控制并发数、把排队的句子合并成批、积压过多时丢弃最旧的句子。
///
/// 同时翻译成多种语言时，每句字幕按目标语言拆成多个任务；每种目标语言的并发数单独限制，
/// 一批中的句子目标语言相同（决策 D17）。
public struct TranslationScheduler: Sendable {
    /// 同时进行的翻译请求数（所有目标语言合计）
    public var maxConcurrent: Int
    /// 每种目标语言同时进行的请求数
    public var maxConcurrentPerTarget: Int
    /// 排队（尚未开始）的任务上限，超出时丢弃最旧的
    public var maxQueued: Int
    /// 每个请求最多包含几句（引擎支持批量时 > 1）
    public var maxBatchSize: Int

    public private(set) var queued: [TranslationJob] = []
    public private(set) var runningCount = 0
    private var runningByTarget: [String: Int] = [:]

    public init(maxConcurrent: Int = 2, maxConcurrentPerTarget: Int? = nil, maxQueued: Int = 4, maxBatchSize: Int = 1) {
        self.maxConcurrent = max(1, maxConcurrent)
        self.maxConcurrentPerTarget = max(1, maxConcurrentPerTarget ?? maxConcurrent)
        self.maxQueued = max(1, maxQueued)
        self.maxBatchSize = max(1, maxBatchSize)
    }

    /// 加入队列，返回被丢弃的旧任务
    @discardableResult
    public mutating func enqueue(_ job: TranslationJob) -> [TranslationJob] {
        queued.append(job)
        guard queued.count > maxQueued else { return [] }
        let overflow = queued.count - maxQueued
        let dropped = Array(queued.prefix(overflow))
        queued.removeFirst(overflow)
        return dropped
    }

    /// 取出现在可以开始的批次。
    /// 每批中的句子目标语言和原文语言都相同，并保持同一目标语言内的先后顺序；
    /// 原文语言未知的句子不合并，避免混入不同语言。
    public mutating func nextBatches() -> [[TranslationJob]] {
        var batches: [[TranslationJob]] = []
        while runningCount < maxConcurrent,
              let firstIndex = queued.firstIndex(where: { runningByTarget[$0.target, default: 0] < maxConcurrentPerTarget }) {
            let first = queued[firstIndex]
            var indices = [firstIndex]
            var index = firstIndex + 1
            while first.language != nil, indices.count < maxBatchSize, index < queued.count {
                let job = queued[index]
                if job.target == first.target {
                    // 同一目标语言遇到不同原文语言就停止，保证译文按顺序完成
                    guard job.language == first.language else { break }
                    indices.append(index)
                }
                index += 1
            }
            let batch = indices.map { queued[$0] }
            for index in indices.reversed() {
                queued.remove(at: index)
            }
            runningCount += 1
            runningByTarget[first.target, default: 0] += 1
            batches.append(batch)
        }
        return batches
    }

    /// 一个批次完成（成功或失败）
    public mutating func finishBatch(target: String) {
        runningCount = max(0, runningCount - 1)
        runningByTarget[target] = max(0, runningByTarget[target, default: 0] - 1)
    }

    public mutating func reset() {
        queued.removeAll()
        runningCount = 0
        runningByTarget.removeAll()
    }
}
