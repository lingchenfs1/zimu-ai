import AVFoundation

/// 调试用：把采集到的系统音频录成 WAV 文件
final class AudioFileRecorder {
    let url: URL
    private let file: AVAudioFile
    private let converter: AudioFormatConverter
    private let maxFrames: AVAudioFramePosition
    private(set) var isFinished = false

    init(url: URL, sampleRate: Double, channels: AVAudioChannelCount, duration: TimeInterval) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        self.url = url
        self.file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        self.converter = AudioFormatConverter(outputFormat: file.processingFormat)
        self.maxFrames = AVAudioFramePosition(sampleRate * duration)
    }

    /// 写入一段音频；达到时长后返回 true
    @discardableResult
    func write(_ buffer: AVAudioPCMBuffer) -> Bool {
        guard !isFinished else { return true }
        if let converted = converter.convert(buffer) {
            do {
                try file.write(from: converted)
            } catch {
                NSLog("ZimuAI: recording write failed: \(error)")
                isFinished = true
            }
        }
        if file.length >= maxFrames {
            isFinished = true
        }
        return isFinished
    }
}
