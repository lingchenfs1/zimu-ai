import AVFoundation
import ZimuCore

/// 语音识别引擎抽象（放在 App 层，因为输入是 AVAudioPCMBuffer，见决策 D7）
protocol TranscriptionEngine: AnyObject {
    /// 准备引擎（检查语言、下载模型等），返回需要的输入音频格式
    @MainActor func prepare(status: @escaping @MainActor (String) -> Void) async throws -> AVAudioFormat

    /// 开始识别。事件和错误都在主线程按顺序回调；isFatal 为 true 表示识别已中断、不会再有结果。
    @MainActor func start(
        onEvent: @escaping @MainActor (TranscriptEvent) -> Void,
        onError: @escaping @MainActor (_ error: Error, _ isFatal: Bool) -> Void
    ) async throws

    /// 送入已转换为 `prepare` 返回格式的音频；可在任意线程调用
    func append(_ buffer: AVAudioPCMBuffer)

    /// 停止识别，并尽量输出剩余结果（停止前的结果仍会通过 onEvent 回调）
    @MainActor func stop() async
}

enum TranscriptionError: LocalizedError {
    case unavailable
    case unsupportedLocale(String)
    case noAudioFormat
    case missingConfiguration(String)
    case autoDetectNotSupported

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "这台 Mac 不支持 Apple 本地语音识别"
        case .unsupportedLocale(let locale):
            return "Apple 本地识别不支持该语言：\(locale)"
        case .noAudioFormat:
            return "无法确定语音识别需要的音频格式"
        case .missingConfiguration(let message):
            return message
        case .autoDetectNotSupported:
            return "Apple 本地识别不能自动检测语言，请在 设置 › 通用 中选择原声语言"
        }
    }
}
