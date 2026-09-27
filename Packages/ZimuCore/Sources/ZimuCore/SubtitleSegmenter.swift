import Foundation

/// 一条完整的字幕句子
public struct SubtitleSegment: Sendable, Equatable {
    public var text: String
    public var start: Date
    public var end: Date

    public init(text: String, start: Date, end: Date) {
        self.text = text
        self.start = start
        self.end = end
    }
}

/// 把识别引擎输出的「定稿片段」合并、切分成适合做字幕的句子。
public struct SubtitleSegmenter: Sendable {
    /// 拉丁等语言一条字幕的最大字符数
    public var maxCharacters: Int
    /// 中日文一条字幕的最大字符数
    public var maxNoSpaceCharacters: Int
    /// 一条字幕最长持续时间（秒），超过则强制输出
    public var maxDuration: TimeInterval
    /// 多久没有新的识别活动就把缓存的文本输出（秒）
    public var idleFlushInterval: TimeInterval

    /// 已定稿但尚未组成完整句子的文本
    public private(set) var pendingText: String = ""
    private var pendingStart: Date?
    private var lastActivity: Date?

    public init(
        maxCharacters: Int = 90,
        maxNoSpaceCharacters: Int = 32,
        maxDuration: TimeInterval = 7,
        idleFlushInterval: TimeInterval = 1.2
    ) {
        self.maxCharacters = maxCharacters
        self.maxNoSpaceCharacters = maxNoSpaceCharacters
        self.maxDuration = maxDuration
        self.idleFlushInterval = idleFlushInterval
    }

    /// 收到草稿（说明还在说话），记录活动时间
    public mutating func notePartial(at date: Date) {
        if pendingStart == nil { pendingStart = date }
        lastActivity = date
    }

    /// 追加一段定稿文本，返回其中已完整的句子
    public mutating func appendFinal(_ text: String, at date: Date) -> [SubtitleSegment] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        lastActivity = date
        guard !trimmed.isEmpty else { return [] }
        if pendingStart == nil {
            pendingStart = date
        }
        pendingText = TextUtilities.join(pendingText, trimmed)
        return extractCompleted(at: date)
    }

    /// 定期调用：长时间无活动或超过最长时长时输出缓存文本
    public mutating func flushIfNeeded(now: Date) -> [SubtitleSegment] {
        guard !pendingText.isEmpty else { return [] }
        if let last = lastActivity, now.timeIntervalSince(last) >= idleFlushInterval {
            return flush(now: now)
        }
        if let start = pendingStart, now.timeIntervalSince(start) >= maxDuration {
            return flush(now: now)
        }
        return []
    }

    /// 立即输出全部缓存文本
    public mutating func flush(now: Date) -> [SubtitleSegment] {
        defer {
            pendingText = ""
            pendingStart = nil
        }
        let text = pendingText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !TextUtilities.isOnlyPunctuation(text) else { return [] }
        return [SubtitleSegment(text: text, start: pendingStart ?? now, end: now)]
    }

    public mutating func reset() {
        pendingText = ""
        pendingStart = nil
        lastActivity = nil
    }

    private func limit(for text: String) -> Int {
        TextUtilities.isMostlyNoSpaceScript(text) ? maxNoSpaceCharacters : maxCharacters
    }

    private mutating func extractCompleted(at date: Date) -> [SubtitleSegment] {
        var result: [SubtitleSegment] = []
        while let cut = SentenceSplitter.firstBoundary(in: pendingText, maxLength: limit(for: pendingText)) {
            let sentence = String(pendingText[..<cut]).trimmingCharacters(in: .whitespacesAndNewlines)
            let rest = String(pendingText[cut...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !sentence.isEmpty, !TextUtilities.isOnlyPunctuation(sentence) {
                result.append(SubtitleSegment(text: sentence, start: pendingStart ?? date, end: date))
            }
            pendingText = rest
            pendingStart = rest.isEmpty ? nil : date
            if rest.isEmpty { break }
        }
        return result
    }
}
