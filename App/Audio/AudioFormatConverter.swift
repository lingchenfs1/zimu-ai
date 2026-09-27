import AVFoundation

/// 把采集到的音频转换为目标格式（重采样 + 混音为单声道等）。
/// 非线程安全：只在同一个串行队列上使用。
final class AudioFormatConverter {
    let outputFormat: AVAudioFormat
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?

    init(outputFormat: AVAudioFormat) {
        self.outputFormat = outputFormat
    }

    /// 转换一段音频，返回新分配的 buffer（输入 buffer 可能只在回调期间有效）
    func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard buffer.frameLength > 0 else { return nil }
        if converter == nil || inputFormat != buffer.format {
            let newConverter = AVAudioConverter(from: buffer.format, to: outputFormat)
            newConverter?.downmix = true
            newConverter?.primeMethod = .none
            converter = newConverter
            inputFormat = buffer.format
        }
        guard let converter else { return nil }

        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return nil }

        var consumed = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if consumed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            inputStatus.pointee = .haveData
            return buffer
        }
        if status == .error {
            if let error { NSLog("ZimuAI: audio conversion failed: \(error)") }
            return nil
        }
        return output.frameLength > 0 ? output : nil
    }
}

enum AudioLevel {
    /// 计算 Float32 buffer 的 RMS
    static func rms(of buffer: AVAudioPCMBuffer) -> Float {
        guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else { return 0 }
        let frames = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        let stride = buffer.stride
        var sum: Float = 0
        var count = 0
        if buffer.format.isInterleaved {
            let data = channels[0]
            for i in 0..<(frames * channelCount) {
                let sample = data[i]
                sum += sample * sample
            }
            count = frames * channelCount
        } else {
            for channel in 0..<channelCount {
                let data = channels[channel]
                for i in 0..<frames {
                    let sample = data[i * stride]
                    sum += sample * sample
                }
            }
            count = frames * channelCount
        }
        return count > 0 ? (sum / Float(count)).squareRoot() : 0
    }

    /// RMS → 0...1 的电平（-60dB ~ 0dB）
    static func normalized(_ rms: Float) -> Float {
        guard rms > 0 else { return 0 }
        let db = 20 * log10(rms)
        return max(0, min(1, (db + 60) / 60))
    }
}
