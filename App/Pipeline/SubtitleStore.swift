import Foundation
import Observation
import ZimuCore

/// 悬浮窗要显示的一行（原文 / 译文）
struct SubtitleDisplayItem: Identifiable, Equatable {
    let id: String
    var original: String?
    var translation: String?
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

    @discardableResult
    func commit(_ segment: SubtitleSegment, needsTranslation: Bool) -> Int {
        let id = timeline.commit(segment, needsTranslation: needsTranslation, at: Date())
        now = Date()
        return id
    }

    func updateTranslation(id: Int, text: String, isFinal: Bool) {
        timeline.updateTranslation(id: id, text: text, isFinal: isFinal, at: Date())
        now = Date()
    }

    func markTranslationFailed(id: Int, message: String) {
        timeline.markTranslationFailed(id: id, message: message, at: Date())
        now = Date()
    }

    func setLiveTranslation(_ text: String, source: String, isComplete: Bool) {
        timeline.setLiveTranslation(text, source: source, isComplete: isComplete)
        now = Date()
    }

    func markTranslationSkipped(id: Int) {
        timeline.markTranslationSkipped(id: id)
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
                let translation = entry.translation.trimmingCharacters(in: .whitespacesAndNewlines)
                let hasTranslation = !translation.isEmpty
                var original: String? = mode.showsOriginal ? entry.original : nil
                var dim = false
                if !mode.showsOriginal && !hasTranslation {
                    // 仅译文模式下译文还没到（或不翻译 / 翻译失败），先弱化显示原文
                    original = entry.original
                    dim = true
                }
                return SubtitleDisplayItem(
                    id: "entry-\(entry.id)",
                    original: original,
                    translation: mode.showsTranslation && hasTranslation ? translation : nil,
                    isLive: false,
                    dimOriginal: dim
                )
            }
        if settings.showLiveText, timeline.isLiveTextVisible(now: now, clearAfter: settings.clearAfterSeconds) {
            let liveTranslation = timeline.liveTranslationMatchesLiveText ? timeline.liveTranslation : ""
            let hasTranslation = mode.showsTranslation && !liveTranslation.isEmpty
            items.append(SubtitleDisplayItem(
                id: "live",
                original: mode.showsOriginal || !hasTranslation ? timeline.liveText : nil,
                translation: hasTranslation ? liveTranslation : nil,
                isLive: true,
                dimOriginal: true
            ))
        }
        return items
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
