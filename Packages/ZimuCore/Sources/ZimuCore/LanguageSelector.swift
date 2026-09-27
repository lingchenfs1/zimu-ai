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

    /// 当前语言连续多少个结果没有出现后开始衰减它的得分
    public var missesBeforeDecay: Int = 3
    /// 每多错过一个结果，当前语言得分乘以这个系数
    public var decayFactor: Double = 0.85

    private var scores: [String: Double] = [:]
    private var samples: [String: Int] = [:]
    /// 当前语言连续没有出结果的次数（其他语言出结果时累加）
    private var activeMisses = 0

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

        if language == active {
            activeMisses = 0
            return false
        }
        // 当前语言的识别器长时间没有结果（可能已不在说这种语言），逐步降低它的得分
        activeMisses += 1
        if activeMisses >= missesBeforeDecay, let activeScore = scores[active] {
            scores[active] = activeScore * decayFactor
        }
        guard sampleCount(for: language) >= minimumSamples else { return false }
        if score(for: language) > score(for: active) + switchMargin {
            active = language
            activeMisses = 0
            return true
        }
        return false
    }

    public mutating func reset() {
        scores.removeAll()
        samples.removeAll()
        activeMisses = 0
        active = candidates[0]
    }
}
