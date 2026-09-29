import Foundation
import Observation
import ZimuCore

/// 悬浮窗要显示的一条字幕（原文 / 译文）
struct SubtitleDisplayItem: Identifiable, Equatable {
    let id: String
    var original: String?
    /// 主目标语言的译文
    var translation: String?
    /// 同时翻译成的其他语言的译文（按设置中的顺序，只包含已有的）
    var additionalTranslations: [String] = []
    /// 实时草稿（还在识别中）
    var isLive: Bool
    /// 原文是否以「弱化」样式显示（仅译文模式下译文还没出来时）
    var dimOriginal: Bool
}

/// 字幕数据：包装 SubtitleTimeline，并定时刷新可见性
@MainActor
@Observable
final class SubtitleStore {
    private(set) var timeline = SubtitleTimeline()
    /// 用于计算过期的当前时间；只在可见内容变化时更新，避免无谓的重绘
    private(set) var now = Date()

    @ObservationIgnored private var tickTask: Task<Void, Never>?
    @ObservationIgnored var settingsProvider: @MainActor () -> AppSettings = { AppSettings() }

    init() {
        tickTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                self?.tick()
            }
        }
    }

    // MARK: 写入

    func setLiveText(_ text: String) {
        timeline.setLiveText(text, at: Date())
        now = Date()
    }

    /// 提交一句字幕；targets 为要翻译成的语言（主目标语言在前），为空表示不翻译
    @discardableResult
    func commit(_ segment: SubtitleSegment, targets: [String]) -> Int {
        let id = timeline.commit(segment, targets: targets, at: Date())
        now = Date()
        return id
    }

    func updateTranslation(id: Int, target: String, text: String, isFinal: Bool) {
        timeline.updateTranslation(id: id, target: target, text: text, isFinal: isFinal, at: Date())
        now = Date()
    }

    func updateOriginal(id: Int, text: String) {
        timeline.updateOriginal(id: id, text: text)
        now = Date()
    }

    func markTranslationFailed(id: Int, target: String, message: String) {
        timeline.markTranslationFailed(id: id, target: target, message: message, at: Date())
        now = Date()
    }

    func setLiveTranslation(_ text: String, source: String, target: String, isComplete: Bool) {
        timeline.setLiveTranslation(text, source: source, target: target, isComplete: isComplete)
        now = Date()
    }

    func markTranslationSkipped(id: Int, target: String) {
        timeline.markTranslationSkipped(id: id, target: target)
    }

    func startSession() {
        timeline.startSession(at: Date())
    }

    func clearLiveText() {
        timeline.clearLiveText()
        now = Date()
    }

    func reset() {
        timeline.reset()
        now = Date()
    }

    func recentOriginals(before id: Int, count: Int) -> [String] {
        guard count > 0 else { return [] }
        let previous = timeline.entries.filter { $0.id < id }
        return previous.suffix(count).map(\.original)
    }

    var hasHistory: Bool { !timeline.entries.isEmpty }

    // MARK: 显示

    func displayItems(for settings: AppSettings) -> [SubtitleDisplayItem] {
        let mode = settings.displayMode
        var items: [SubtitleDisplayItem] = timeline
            .visibleEntries(now: now, maxCount: max(1, settings.maxVisibleEntries), clearAfter: settings.clearAfterSeconds)
            .map { entry in
                let texts = entry.translations.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
                return makeItem(id: "entry-\(entry.id)", original: entry.original, translations: texts, isLive: false, mode: mode)
            }
        if settings.showLiveText, timeline.isLiveTextVisible(now: now, clearAfter: settings.clearAfterSeconds) {
            // 实时译文的目标语言顺序以本次运行提交的字幕为准，没有时按设置
            let targets = timeline.entries.last?.translations.map(\.target) ?? settings.translationTargets
            let texts = targets.map { timeline.liveTranslation(for: $0) ?? "" }
            items.append(makeItem(id: "live", original: timeline.liveText, translations: texts, isLive: true, mode: mode))
        }
        return items
    }

    /// translations 第一个是主目标语言，空字符串表示该语言的译文还没有
    private func makeItem(id: String, original: String, translations: [String], isLive: Bool, mode: SubtitleDisplayMode) -> SubtitleDisplayItem {
        let primary = translations.first.flatMap { $0.isEmpty ? nil : $0 }
        let additional = translations.dropFirst().filter { !$0.isEmpty }
        let hasTranslation = mode.showsTranslation && (primary != nil || !additional.isEmpty)
        return SubtitleDisplayItem(
            id: id,
            // 仅译文模式下译文还没到（或不翻译 / 翻译失败），先弱化显示原文
            original: mode.showsOriginal || !hasTranslation ? original : nil,
            translation: mode.showsTranslation ? primary : nil,
            additionalTranslations: mode.showsTranslation ? Array(additional) : [],
            isLive: isLive,
            dimOriginal: isLive || !mode.showsOriginal
        )
    }

    private func visibilitySignature(at date: Date, settings: AppSettings) -> [Int] {
        var ids = timeline
            .visibleEntries(now: date, maxCount: max(1, settings.maxVisibleEntries), clearAfter: settings.clearAfterSeconds)
            .map(\.id)
        if timeline.isLiveTextVisible(now: date, clearAfter: settings.clearAfterSeconds) { ids.append(-1) }
        return ids
    }

    private func tick() {
        let settings = settingsProvider()
        let date = Date()
        if visibilitySignature(at: date, settings: settings) != visibilitySignature(at: now, settings: settings) {
            now = date
        }
    }
}
