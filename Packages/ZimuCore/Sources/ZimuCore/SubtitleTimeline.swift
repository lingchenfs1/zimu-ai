import Foundation

/// 识别引擎输出的事件
public enum TranscriptEvent: Sendable, Equatable {
    /// 草稿：会被后续草稿或定稿替换
    case partial(String)
    /// 定稿片段：增量文本，不会再变化；language 为识别出的语言（BCP-47，未知为 nil）
    case final(String, language: String? = nil)
}

/// 一条字幕（原文 + 一种或多种目标语言的译文）
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

    /// 一种目标语言的译文
    public struct Translation: Sendable, Equatable {
        /// 目标语言（BCP-47）
        public let target: String
        public var text: String
        public var state: TranslationState

        public init(target: String, text: String = "", state: TranslationState = .pending) {
            self.target = target
            self.text = text
            self.state = state
        }
    }

    public let id: Int
    public var original: String
    /// 各目标语言的译文，顺序与提交时的目标语言一致（第一个是主目标语言）；不翻译时为空
    public var translations: [Translation]
    public var start: Date
    public var end: Date
    public var updatedAt: Date
    /// 原文语言（BCP-47，未知为 nil）
    public var language: String?

    public init(
        id: Int,
        original: String,
        translations: [Translation] = [],
        start: Date,
        end: Date,
        updatedAt: Date,
        language: String? = nil
    ) {
        self.id = id
        self.original = original
        self.translations = translations
        self.start = start
        self.end = end
        self.updatedAt = updatedAt
        self.language = language
    }

    /// 主目标语言的译文
    public var translation: String { translations.first?.text ?? "" }

    /// 主目标语言的翻译状态
    public var state: TranslationState { translations.first?.state ?? .none }

    public func translation(for target: String) -> Translation? {
        translations.first(where: { $0.target == target })
    }
}

/// 识别中文字的实时译文（每种目标语言一份）
public struct LiveTranslation: Sendable, Equatable {
    public var text: String
    /// 翻译时的原文快照
    public var source: String
    /// 是否已完整（流式输出中为 false，不能复用为整句译文）
    public var isComplete: Bool

    public init(text: String, source: String, isComplete: Bool) {
        self.text = text
        self.source = source
        self.isComplete = isComplete
    }
}

/// 字幕时间线：保存已定稿的字幕、当前实时草稿，并决定哪些字幕应该显示。
public struct SubtitleTimeline: Sendable {
    public private(set) var entries: [SubtitleEntry] = []
    /// 正在识别中的文本（已定稿但未成句的部分 + 草稿）
    public private(set) var liveText: String = ""
    public private(set) var liveUpdatedAt: Date?
    /// 识别中文字的实时译文，按目标语言保存
    public private(set) var liveTranslations: [String: LiveTranslation] = [:]
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

    /// 设置某种目标语言的实时译文（source 是翻译时的原文快照；流式输出中的片段 isComplete 为 false）
    public mutating func setLiveTranslation(_ translation: String, source: String, target: String, isComplete: Bool = true) {
        liveTranslations[target] = LiveTranslation(
            text: translation.trimmingCharacters(in: .whitespacesAndNewlines),
            source: source,
            isComplete: isComplete
        )
    }

    /// 某种目标语言的实时译文最近一次是按哪段原文翻译的
    public func liveTranslationSource(for target: String) -> String {
        liveTranslations[target]?.source ?? ""
    }

    /// 仍然对应当前识别文字的实时译文（当前文字以翻译时的原文开头）；不对应时返回 nil
    public func liveTranslation(for target: String) -> String? {
        guard let live = liveTranslations[target], !live.text.isEmpty, !live.source.isEmpty else { return nil }
        let current = TextUtilities.normalizedForComparison(liveText)
        let source = TextUtilities.normalizedForComparison(live.source)
        return !source.isEmpty && current.hasPrefix(source) ? live.text : nil
    }

    /// 如果实时译文恰好对应这句原文，返回它（提交整句时可直接复用，省去一次翻译）
    public func reusableLiveTranslation(for text: String, target: String) -> String? {
        guard let live = liveTranslations[target], live.isComplete, !live.text.isEmpty else { return nil }
        let source = TextUtilities.normalizedForComparison(live.source)
        return !source.isEmpty && source == TextUtilities.normalizedForComparison(text) ? live.text : nil
    }

    /// 提交一条完整字幕，返回它的 id。targets 为要翻译成的语言（主目标语言在前），为空表示不翻译
    @discardableResult
    public mutating func commit(_ segment: SubtitleSegment, targets: [String], at date: Date) -> Int {
        startSession(at: segment.start)
        let id = nextID
        nextID += 1
        entries.append(SubtitleEntry(
            id: id,
            original: segment.text,
            translations: targets.map { SubtitleEntry.Translation(target: $0) },
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

    /// 更新某种目标语言的译文；已结束（done / failed / skipped）的译文不再接受流式片段
    public mutating func updateTranslation(id: Int, target: String, text: String, isFinal: Bool, at date: Date) {
        guard let (index, slot) = location(id: id, target: target) else { return }
        switch entries[index].translations[slot].state {
        case .done, .failed, .skipped:
            if !isFinal { return }
        default:
            break
        }
        entries[index].translations[slot].text = text
        entries[index].translations[slot].state = isFinal ? .done : .streaming
        entries[index].updatedAt = date
    }

    public mutating func markTranslationFailed(id: Int, target: String, message: String, at date: Date) {
        guard let (index, slot) = location(id: id, target: target) else { return }
        entries[index].translations[slot].state = .failed(message)
        entries[index].updatedAt = date
    }

    public mutating func markTranslationSkipped(id: Int, target: String) {
        guard let (index, slot) = location(id: id, target: target) else { return }
        entries[index].translations[slot].state = .skipped
    }

    private func location(id: Int, target: String) -> (entry: Int, slot: Int)? {
        guard let index = entries.lastIndex(where: { $0.id == id }),
              let slot = entries[index].translations.firstIndex(where: { $0.target == target })
        else { return nil }
        return (index, slot)
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
                translations: entry.translations.map(\.text).filter { !$0.isEmpty }
            )
        }
    }

    public mutating func clearLiveText() {
        liveText = ""
        liveUpdatedAt = nil
        liveTranslations.removeAll()
    }

    /// 清空字幕。id 不会重新从 1 开始，避免上一轮迟到的译文写到新字幕上。
    public mutating func reset() {
        entries.removeAll()
        liveText = ""
        liveUpdatedAt = nil
        liveTranslations.removeAll()
        sessionStart = nil
    }
}
