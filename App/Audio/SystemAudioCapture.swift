import AudioToolbox
import AVFoundation
import CoreAudio

/// 用 Core Audio Process Tap 捕获系统音频（全部系统音频，或指定应用）。
/// 需要 Info.plist 中的 NSAudioCaptureUsageDescription，首次使用时系统会请求「录制系统音频」权限。
final class SystemAudioCapture {
    private let queue = DispatchQueue(label: "zimu.audio.capture", qos: .userInitiated)

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?

    // 以下状态只在 queue 上访问
    private var converter: AudioFormatConverter?
    private var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    private var onLevel: ((Float) -> Void)?
    private var recorder: AudioFileRecorder?
    private var recorderCompletion: ((URL?) -> Void)?
    private var lastLevelTime: CFAbsoluteTime = 0

    private(set) var tapFormat: AVAudioFormat?
    private(set) var isRunning = false

    deinit {
        stop()
    }

    /// 开始捕获
    /// - Parameters:
    ///   - bundleID: 只捕获该应用（及其子进程）；nil 表示全部系统音频（排除本应用）
    ///   - outputFormat: 回调中 buffer 的格式（识别引擎需要的格式）；nil 表示不回调音频（只测电平 / 录音）
    func start(
        bundleID: String?,
        outputFormat: AVAudioFormat?,
        onBuffer: @escaping (AVAudioPCMBuffer) -> Void,
        onLevel: @escaping (Float) -> Void
    ) throws {
        guard !isRunning else { return }

        // 1. 创建 Process Tap
        let description: CATapDescription
        if let bundleID {
            let processes = AudioProcessList.objectIDs(matching: bundleID)
            guard !processes.isEmpty else { throw AudioCaptureError.noAudioProcess(bundleID) }
            description = CATapDescription(stereoMixdownOfProcesses: processes)
        } else {
            let excluded = CoreAudioUtils.processObjectID(for: ProcessInfo.processInfo.processIdentifier).map { [$0] } ?? []
            description = CATapDescription(stereoGlobalTapButExcludeProcesses: excluded)
        }
        description.uuid = UUID()
        description.name = "ZimuAI System Audio Tap"
        description.isPrivate = true
        description.muteBehavior = .unmuted

        var newTapID = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(description, &newTapID)
        guard status == noErr else {
            throw AudioCaptureError.coreAudio("创建音频 Tap", status)
        }
        tapID = newTapID

        do {
            // 2. 读取 Tap 的音频格式
            var streamDescription: AudioStreamBasicDescription = try CoreAudioUtils.read(
                tapID,
                kAudioTapPropertyFormat,
                default: AudioStreamBasicDescription()
            )
            guard let format = AVAudioFormat(streamDescription: &streamDescription) else {
                throw AudioCaptureError.invalidFormat
            }
            tapFormat = format

            // 3. 创建包含 Tap 的私有聚合设备（以默认输出设备为时钟）
            let outputDevice = try CoreAudioUtils.defaultSystemOutputDevice()
            let outputUID = try CoreAudioUtils.readString(outputDevice, kAudioDevicePropertyDeviceUID)
            let aggregateDescription: [String: Any] = [
                kAudioAggregateDeviceNameKey: "ZimuAI Aggregate",
                kAudioAggregateDeviceUIDKey: UUID().uuidString,
                kAudioAggregateDeviceMainSubDeviceKey: outputUID,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceSubDeviceListKey: [
                    [kAudioSubDeviceUIDKey: outputUID],
                ],
                kAudioAggregateDeviceTapListKey: [
                    [
                        kAudioSubTapDriftCompensationKey: true,
                        kAudioSubTapUIDKey: description.uuid.uuidString,
                    ],
                ],
            ]
            var newAggregateID = AudioObjectID(kAudioObjectUnknown)
            status = AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &newAggregateID)
            guard status == noErr else {
                throw AudioCaptureError.coreAudio("创建聚合设备", status)
            }
            aggregateDeviceID = newAggregateID

            // 4. 准备回调状态
            queue.sync {
                self.converter = outputFormat.map { AudioFormatConverter(outputFormat: $0) }
                self.onBuffer = onBuffer
                self.onLevel = onLevel
            }

            // 5. 注册 IOProc 并启动
            var procID: AudioDeviceIOProcID?
            status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateDeviceID, queue) { [weak self] _, inputData, _, _, _ in
                self?.handleInput(inputData, format: format)
            }
            guard status == noErr, let procID else {
                throw AudioCaptureError.coreAudio("注册音频回调", status)
            }
            ioProcID = procID

            status = AudioDeviceStart(aggregateDeviceID, procID)
            guard status == noErr else {
                throw AudioCaptureError.coreAudio("启动音频设备", status)
            }
            isRunning = true
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        if aggregateDeviceID != AudioObjectID(kAudioObjectUnknown) {
            if let ioProcID {
                AudioDeviceStop(aggregateDeviceID, ioProcID)
                AudioDeviceDestroyIOProcID(aggregateDeviceID, ioProcID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
        }
        ioProcID = nil
        aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)

        if tapID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyProcessTap(tapID)
        }
        tapID = AudioObjectID(kAudioObjectUnknown)

        // 等待队列中剩余的回调执行完，再清理状态
        queue.sync {
            if let recorder = self.recorder {
                self.recorderCompletion?(recorder.url)
            }
            self.recorder = nil
            self.recorderCompletion = nil
            self.onBuffer = nil
            self.onLevel = nil
            self.converter = nil
        }
        isRunning = false
    }

    /// 调试：把接下来 duration 秒的系统音频录成 WAV
    func record(to url: URL, duration: TimeInterval, completion: @escaping (URL?) -> Void) {
        queue.async {
            guard let format = self.tapFormat else {
                completion(nil)
                return
            }
            do {
                self.recorder = try AudioFileRecorder(
                    url: url,
                    sampleRate: format.sampleRate,
                    channels: min(2, max(1, format.channelCount)),
                    duration: duration
                )
                self.recorderCompletion = completion
            } catch {
                NSLog("ZimuAI: cannot create recording: \(error)")
                completion(nil)
            }
        }
    }

    // 在 queue 上执行
    private func handleInput(_ inputData: UnsafePointer<AudioBufferList>, format: AVAudioFormat) {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: inputData, deallocator: nil),
              buffer.frameLength > 0
        else { return }

        let now = CFAbsoluteTimeGetCurrent()
        if now - lastLevelTime >= 0.06 {
            lastLevelTime = now
            onLevel?(AudioLevel.normalized(AudioLevel.rms(of: buffer)))
        }

        if let recorder, recorder.write(buffer) {
            let url = recorder.url
            self.recorder = nil
            let completion = recorderCompletion
            recorderCompletion = nil
            completion?(url)
        }

        // 没有指定输出格式时（例如只录音测试）不回调音频
        if let converter, let converted = converter.convert(buffer) {
            onBuffer?(converted)
        }
    }
}
