import Foundation

/// 多语言并行识别时，根据各语言识别结果的置信度决定当前在说哪种语言。
public struct LanguageSelector: Sendable {
    public let candidates: [String]
    public private(set) var active: String
    /// 平滑系数：新结果对得分的影响（0...1）
    public var smoothing: Double = 0.45
    /// 另一种语言的得分要比当前语言高出多少才切换
    public var switchMargin: Double = 0.08
    /// 切换前该语言至少要有几个结果
    public var minimumSamples: Int = 2

    private var scores: [String: Double] = [:]
    private var samples: [String: Int] = [:]

    public init(candidates: [String]) {
        precondition(!candidates.isEmpty, "at least one candidate language")
        self.candidates = candidates
        self.active = candidates[0]
    }

    public func score(for language: String) -> Double {
        scores[language] ?? 0
    }

    public func sampleCount(for language: String) -> Int {
        samples[language] ?? 0
    }

    /// 记录某种语言的一个定稿结果。
    /// - Parameters:
    ///   - confidence: 平均置信度 0...1（空结果传 0）
    ///   - characters: 结果的字符数，越短权重越低
    /// - Returns: 是否因此切换了当前语言
    @discardableResult
    public mutating func record(language: String, confidence: Double, characters: Int) -> Bool {
        guard candidates.contains(language) else { return false }
        let weight = smoothing * min(1, max(0.25, Double(characters) / 20))
        let clamped = max(0, min(1, confidence))
        let previous = scores[language] ?? clamped
        scores[language] = previous * (1 - weight) + clamped * weight
        samples[language, default: 0] += 1

        guard language != active, sampleCount(for: language) >= minimumSamples else { return false }
        if score(for: language) > score(for: active) + switchMargin {
            active = language
            return true
        }
        return false
    }

    public mutating func reset() {
        scores.removeAll()
        samples.removeAll()
        active = candidates[0]
    }
}
