import Foundation

/// 导出用的一条字幕
public struct SubtitleRecord: Sendable, Equatable {
    public var start: TimeInterval
    public var end: TimeInterval
    public var original: String
    /// 各目标语言的译文（主目标语言在前，只包含已有的译文）
    public var translations: [String]

    public init(start: TimeInterval, end: TimeInterval, original: String, translations: [String]) {
        self.start = start
        self.end = end
        self.original = original
        self.translations = translations
    }

    public init(start: TimeInterval, end: TimeInterval, original: String, translation: String?) {
        self.init(start: start, end: end, original: original, translations: translation.map { [$0] } ?? [])
    }
}

/// SRT 字幕文件格式化
public enum SRTFormatter {
    public static let minimumDuration: TimeInterval = 1.0

    public static func format(_ records: [SubtitleRecord], mode: SubtitleDisplayMode) -> String {
        var blocks: [String] = []
        var index = 1
        for record in records {
            var lines: [String] = []
            let translations = record.translations
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            switch mode {
            case .bilingual:
                lines.append(contentsOf: translations)
                lines.append(record.original)
            case .translationOnly:
                lines.append(contentsOf: translations.isEmpty ? [record.original] : translations)
            case .originalOnly:
                lines.append(record.original)
            }
            let end = max(record.end, record.start + minimumDuration)
            blocks.append("\(index)\n\(timestamp(record.start)) --> \(timestamp(end))\n\(lines.joined(separator: "\n"))")
            index += 1
        }
        return blocks.isEmpty ? "" : blocks.joined(separator: "\n\n") + "\n"
    }

    /// 秒 → "HH:MM:SS,mmm"
    public static func timestamp(_ seconds: TimeInterval) -> String {
        let totalMillis = Int((max(0, seconds) * 1000).rounded())
        let millis = totalMillis % 1000
        let totalSeconds = totalMillis / 1000
        let s = totalSeconds % 60
        let m = (totalSeconds / 60) % 60
        let h = totalSeconds / 3600
        return String(format: "%02d:%02d:%02d,%03d", h, m, s, millis)
    }
}
