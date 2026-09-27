import Foundation

/// 识别引擎输出的事件
public enum TranscriptEvent: Sendable, Equatable {
    /// 草稿：会被后续草稿或定稿替换
    case partial(String)
    /// 定稿片段：增量文本，不会再变化；language 为识别出的语言（BCP-47，未知为 nil）
    case final(String, language: String? = nil)
}

/// 一条字幕（原文 + 译文）
public struct SubtitleEntry: Identifiable, Sendable, Equatable {
    public enum TranslationState: Sendable, Equatable {
        /// 不需要翻译
        case none
        /// 等待翻译
        case pending
        /// 正在流式输出译文
        case streaming
        case done
        case failed(String)
        /// 积压太多被跳过
        case skipped
    }

    public let id: Int
    public var original: String
    public var translation: String
    public var state: TranslationState
    public var start: Date
    public var end: Date
    public var updatedAt: Date
    /// 原文语言（BCP-47，未知为 nil）
    public var language: String?

    public init(
        id: Int,
        original: String,
        translation: String = "",
        state: TranslationState,
        start: Date,
        end: Date,
        updatedAt: Date,
        language: String? = nil
    ) {
        self.id = id
        self.original = original
        self.translation = translation
        self.state = state
        self.start = start
        self.end = end
        self.updatedAt = updatedAt
        self.language = language
    }
}

/// 字幕时间线：保存已定稿的字幕、当前实时草稿，并决定哪些字幕应该显示。
public struct SubtitleTimeline: Sendable {
    public private(set) var entries: [SubtitleEntry] = []
    /// 正在识别中的文本（已定稿但未成句的部分 + 草稿）
    public private(set) var liveText: String = ""
    public private(set) var liveUpdatedAt: Date?
    /// 识别中文字的实时译文，以及它对应的原文
    public private(set) var liveTranslation: String = ""
    public private(set) var liveTranslationSource: String = ""
    public private(set) var sessionStart: Date?
    public var historyLimit: Int = 5000
    private var nextID = 1

    public init() {}

    public mutating func startSession(at date: Date) {
        if sessionStart == nil { sessionStart = date }
    }

    public mutating func setLiveText(_ text: String, at date: Date) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != liveText else { return }
        liveText = trimmed
        liveUpdatedAt = date
    }

    /// 设置实时译文（source 是翻译时的原文快照）
    public mutating func setLiveTranslation(_ translation: String, source: String) {
        liveTranslation = translation.trimmingCharacters(in: .whitespacesAndNewlines)
        liveTranslationSource = source
    }

    /// 实时译文是否仍然对应当前的识别文字（当前文字以翻译时的原文开头）
    public var liveTranslationMatchesLiveText: Bool {
        guard !liveTranslation.isEmpty, !liveTranslationSource.isEmpty else { return false }
        let live = TextUtilities.normalizedForComparison(liveText)
        let source = TextUtilities.normalizedForComparison(liveTranslationSource)
        return !source.isEmpty && live.hasPrefix(source)
    }

    /// 如果实时译文恰好对应这句原文，返回它（提交整句时可直接复用，省去一次翻译）
    public func reusableLiveTranslation(for text: String) -> String? {
        guard !liveTranslation.isEmpty else { return nil }
        let source = TextUtilities.normalizedForComparison(liveTranslationSource)
        return !source.isEmpty && source == TextUtilities.normalizedForComparison(text) ? liveTranslation : nil
    }

    /// 提交一条完整字幕，返回它的 id
    @discardableResult
    public mutating func commit(_ segment: SubtitleSegment, needsTranslation: Bool, at date: Date) -> Int {
        startSession(at: segment.start)
        let id = nextID
        nextID += 1
        entries.append(SubtitleEntry(
            id: id,
            original: segment.text,
            state: needsTranslation ? .pending : .none,
            start: segment.start,
            end: segment.end,
            updatedAt: date,
            language: segment.language
        ))
        if entries.count > historyLimit {
            entries.removeFirst(entries.count - historyLimit)
        }
        return id
    }

    /// 最新一条字幕的 id
    public var latestID: Int? { entries.last?.id }

    public func entry(id: Int) -> SubtitleEntry? {
        entries.last(where: { $0.id == id })
    }

    /// 更新译文；已结束（done / failed / skipped）的条目不再接受流式片段
    public mutating func updateTranslation(id: Int, text: String, isFinal: Bool, at date: Date) {
        guard let index = entries.lastIndex(where: { $0.id == id }) else { return }
        switch entries[index].state {
        case .done, .failed, .skipped:
            if !isFinal { return }
        default:
            break
        }
        entries[index].translation = text
        entries[index].state = isFinal ? .done : .streaming
        entries[index].updatedAt = date
    }

    public mutating func markTranslationFailed(id: Int, message: String, at date: Date) {
        guard let index = entries.lastIndex(where: { $0.id == id }) else { return }
        entries[index].state = .failed(message)
        entries[index].updatedAt = date
    }

    public mutating func markTranslationSkipped(id: Int) {
        guard let index = entries.lastIndex(where: { $0.id == id }) else { return }
        entries[index].state = .skipped
    }

    /// 当前应显示的字幕（最近 maxCount 条，且在 clearAfter 秒内有更新）
    public func visibleEntries(now: Date, maxCount: Int, clearAfter: TimeInterval) -> [SubtitleEntry] {
        guard maxCount > 0 else { return [] }
        let recent = entries.suffix(maxCount)
        return recent.filter { now.timeIntervalSince($0.updatedAt) <= clearAfter }
    }

    public func isLiveTextVisible(now: Date, clearAfter: TimeInterval) -> Bool {
        guard !liveText.isEmpty, let updated = liveUpdatedAt else { return false }
        return now.timeIntervalSince(updated) <= clearAfter
    }

    /// 导出用的字幕记录（时间相对于会话开始）
    public func records() -> [SubtitleRecord] {
        guard let origin = sessionStart ?? entries.first?.start else { return [] }
        return entries.map { entry in
            SubtitleRecord(
                start: max(0, entry.start.timeIntervalSince(origin)),
                end: max(0, entry.end.timeIntervalSince(origin)),
                original: entry.original,
                translation: entry.translation.isEmpty ? nil : entry.translation
            )
        }
    }

    public mutating func clearLiveText() {
        liveText = ""
        liveUpdatedAt = nil
        liveTranslation = ""
        liveTranslationSource = ""
    }

    /// 清空字幕。id 不会重新从 1 开始，避免上一轮迟到的译文写到新字幕上。
    public mutating func reset() {
        entries.removeAll()
        liveText = ""
        liveUpdatedAt = nil
        liveTranslation = ""
        liveTranslationSource = ""
        sessionStart = nil
    }
}
