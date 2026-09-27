import Foundation

/// 基于能量的简易语音活动检测（VAD），用于把连续音频切成适合上传识别的片段。
/// 输入：单声道 Float 采样（默认 16kHz）。
public struct EnergyVAD: Sendable {
    public struct Configuration: Sendable, Equatable {
        public var sampleRate: Double = 16_000
        public var frameDuration: TimeInterval = 0.03
        /// 灵敏度 0...1，越高越容易判定为有人说话
        public var sensitivity: Double = 0.5
        /// 说话结束判定：连续静音时长
        public var silenceToEnd: TimeInterval = 0.6
        /// 片段最长时长，超过则强制切分
        public var maxSegmentDuration: TimeInterval = 8
        /// 片段中有声部分至少多长才算有效
        public var minSpeechDuration: TimeInterval = 0.25
        /// 片段开头额外保留的音频
        public var preRollDuration: TimeInterval = 0.2
        /// 绝对能量下限（RMS）
        public var absoluteThreshold: Float = 0.003

        public init() {}
    }

    public var configuration: Configuration
    public private(set) var isSpeaking = false

    /// 正在进行中的片段（说话中，尚未结束）
    public var currentSegment: [Float] { isSpeaking ? segment : [] }
    public private(set) var noiseFloor: Float = 0.002

    private var carry: [Float] = []
    private var preRoll: [[Float]] = []
    private var segment: [Float] = []
    private var voicedFrames = 0
    private var silentFrames = 0

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    var frameLength: Int { max(1, Int(configuration.sampleRate * configuration.frameDuration)) }

    /// 当前判定阈值
    public var threshold: Float {
        let sensitivity = Float(max(0, min(1, configuration.sensitivity)))
        let multiplier: Float = 4.0 - 2.5 * sensitivity
        return max(noiseFloor * multiplier, configuration.absoluteThreshold * (1.5 - sensitivity))
    }

    /// 送入一段采样，返回已经完成的语音片段
    public mutating func process(_ samples: [Float]) -> [[Float]] {
        var completed: [[Float]] = []
        carry.append(contentsOf: samples)
        let n = frameLength
        var offset = 0
        while carry.count - offset >= n {
            let frame = Array(carry[offset..<(offset + n)])
            offset += n
            if let segment = processFrame(frame) {
                completed.append(segment)
            }
        }
        if offset > 0 {
            carry.removeFirst(offset)
        }
        return completed
    }

    /// 结束时输出尚未完成的片段
    public mutating func flush() -> [Float]? {
        defer { resetSegment() }
        guard isSpeaking, hasEnoughSpeech else { return nil }
        return segment
    }

    public mutating func reset() {
        carry.removeAll()
        preRoll.removeAll()
        resetSegment()
    }

    private var hasEnoughSpeech: Bool {
        Double(voicedFrames) * configuration.frameDuration >= configuration.minSpeechDuration
    }

    private mutating func resetSegment() {
        isSpeaking = false
        segment.removeAll()
        voicedFrames = 0
        silentFrames = 0
    }

    private mutating func processFrame(_ frame: [Float]) -> [Float]? {
        let rms = Self.rms(frame)
        let voiced = rms > threshold

        if !isSpeaking {
            // 更新噪声基准：向下快速跟随，向上缓慢跟随
            if rms < noiseFloor {
                noiseFloor = max(0.0001, noiseFloor * 0.9 + rms * 0.1)
            } else if !voiced {
                noiseFloor = noiseFloor * 0.995 + rms * 0.005
            }
            if voiced {
                isSpeaking = true
                segment = preRoll.flatMap { $0 }
                segment.append(contentsOf: frame)
                voicedFrames = 1
                silentFrames = 0
                preRoll.removeAll()
            } else {
                preRoll.append(frame)
                let maxPreRollFrames = max(0, Int(configuration.preRollDuration / configuration.frameDuration))
                if preRoll.count > maxPreRollFrames {
                    preRoll.removeFirst(preRoll.count - maxPreRollFrames)
                }
            }
            return nil
        }

        segment.append(contentsOf: frame)
        if voiced {
            voicedFrames += 1
            silentFrames = 0
        } else {
            silentFrames += 1
        }

        let silence = Double(silentFrames) * configuration.frameDuration
        let duration = Double(segment.count) / configuration.sampleRate
        guard silence >= configuration.silenceToEnd || duration >= configuration.maxSegmentDuration else {
            return nil
        }
        let result = hasEnoughSpeech ? segment : nil
        resetSegment()
        return result
    }

    public static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for s in samples { sum += s * s }
        return (sum / Float(samples.count)).squareRoot()
    }
}
