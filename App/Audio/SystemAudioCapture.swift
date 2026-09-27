import AudioToolbox
import AVFoundation
import CoreAudio

/// 用 Core Audio Process Tap 捕获系统音频（全部系统音频，或指定应用）。
/// 需要 Info.plist 中的 NSAudioCaptureUsageDescription，首次使用时系统会请求「录制系统音频」权限。
/// 线程约束：Core Audio 的创建 / 停止在 controlQueue 上，音频回调状态在 queue 上，因此标注为 @unchecked Sendable。
final class SystemAudioCapture: @unchecked Sendable {
    private let queue = DispatchQueue(label: "zimu.audio.capture", qos: .userInitiated)
    /// Core Audio 的创建 / 启动 / 停止放在这个队列上执行：
    /// 首次使用时系统授权弹窗会阻塞调用线程，不能放在主线程（决策 D11）
    private static let controlQueue = DispatchQueue(label: "zimu.audio.control", qos: .userInitiated)

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
        let status = AudioHardwareCreateProcessTap(description, &newTapID)
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
            NSLog("ZimuAI: tap format \(format)")

            // 3. 创建包含 Tap 的私有聚合设备，并注册 IOProc 启动。
            //    优先使用「只含 Tap」的聚合设备（不把输出设备加进来，避免连带打开耳机麦克风）；
            //    失败时退回 AudioCap 的做法（以默认输出设备为主设备）。
            queue.sync {
                self.converter = outputFormat.map { AudioFormatConverter(outputFormat: $0) }
                self.onBuffer = onBuffer
                self.onLevel = onLevel
            }
            let tapUID = description.uuid.uuidString
            do {
                aggregateDeviceID = try createTapOnlyAggregate(tapUID: tapUID)
                try startIO(format: format)
            } catch {
                NSLog("ZimuAI: tap-only aggregate failed (\(error)), falling back to output-device aggregate")
                destroyAggregate()
                aggregateDeviceID = try createOutputDeviceAggregate(tapUID: tapUID)
                try startIO(format: format)
            }
            isRunning = true
        } catch {
            stop()
            throw error
        }
    }

    /// 在后台队列上启动（不阻塞主线程）
    func startInBackground(
        bundleID: String?,
        outputFormat: AVAudioFormat?,
        onBuffer: @escaping (AVAudioPCMBuffer) -> Void,
        onLevel: @escaping (Float) -> Void
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            Self.controlQueue.async {
                do {
                    try self.start(bundleID: bundleID, outputFormat: outputFormat, onBuffer: onBuffer, onLevel: onLevel)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// 在后台队列上停止；超过 timeout 秒不再等待（返回 false）
    @discardableResult
    func stopInBackground(timeout: TimeInterval = 3) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let lock = NSLock()
            var resumed = false
            func finish(_ value: Bool) {
                lock.lock()
                defer { lock.unlock() }
                guard !resumed else { return }
                resumed = true
                continuation.resume(returning: value)
            }
            Self.controlQueue.async {
                self.stop()
                finish(true)
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                finish(false)
            }
        }
    }

    func stop() {
        destroyAggregate()

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

    // MARK: 聚合设备

    private func createTapOnlyAggregate(tapUID: String) throws -> AudioObjectID {
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "ZimuAI Aggregate",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceSubDeviceListKey: [] as CFArray,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
        ]
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &deviceID)
        guard status == noErr else { throw AudioCaptureError.coreAudio("创建聚合设备", status) }

        var address = CoreAudioUtils.makeAddress(kAudioAggregateDevicePropertyTapList)
        var tapList = [tapUID] as CFArray
        status = withUnsafeMutablePointer(to: &tapList) { pointer in
            AudioObjectSetPropertyData(deviceID, &address, 0, nil, UInt32(MemoryLayout<CFArray>.stride), pointer)
        }
        guard status == noErr else {
            AudioHardwareDestroyAggregateDevice(deviceID)
            throw AudioCaptureError.coreAudio("把 Tap 加入聚合设备", status)
        }
        return deviceID
    }

    private func createOutputDeviceAggregate(tapUID: String) throws -> AudioObjectID {
        let outputDevice = try CoreAudioUtils.defaultOutputDevice()
        let outputUID = try CoreAudioUtils.readString(outputDevice, kAudioDevicePropertyDeviceUID)
        let description: [String: Any] = [
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
                    kAudioSubTapUIDKey: tapUID,
                ],
            ],
        ]
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &deviceID)
        guard status == noErr else { throw AudioCaptureError.coreAudio("创建聚合设备", status) }
        return deviceID
    }

    private func startIO(format: AVAudioFormat) throws {
        var procID: AudioDeviceIOProcID?
        var status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateDeviceID, queue) { [weak self] _, inputData, _, _, _ in
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
    }

    private func destroyAggregate() {
        if aggregateDeviceID != AudioObjectID(kAudioObjectUnknown) {
            if let ioProcID {
                AudioDeviceStop(aggregateDeviceID, ioProcID)
                AudioDeviceDestroyIOProcID(aggregateDeviceID, ioProcID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
        }
        ioProcID = nil
        aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
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
        guard let buffer = makeBuffer(from: inputData, format: format), buffer.frameLength > 0 else { return }

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

    private var loggedBufferMismatch = false

    /// 把 IOProc 的输入包装成 PCM buffer。
    /// 如果默认输出设备本身带输入流（例如带麦克风的耳机），聚合设备的输入里会多出设备自己的流，
    /// 这时 bufferListNoCopy 会失败；Tap 的流排在最后，取最后几个 buffer 复制出来。
    private func makeBuffer(from inputData: UnsafePointer<AudioBufferList>, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
        let expected = format.isInterleaved ? 1 : Int(format.channelCount)
        if list.count == expected {
            return AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: inputData, deallocator: nil)
        }
        if !loggedBufferMismatch {
            loggedBufferMismatch = true
            NSLog("ZimuAI: aggregate input has \(list.count) buffers, tap format expects \(expected); using the last ones")
        }
        guard list.count > expected else { return nil }
        let tapBuffers = Array(list.suffix(expected))
        let bytesPerFrame = Int(format.streamDescription.pointee.mBytesPerFrame)
        guard bytesPerFrame > 0, let first = tapBuffers.first else { return nil }
        let frames = AVAudioFrameCount(Int(first.mDataByteSize) / bytesPerFrame)
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buffer.frameLength = frames
        let destination = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        for (index, source) in tapBuffers.enumerated() where index < destination.count {
            guard let src = source.mData, let dst = destination[index].mData else { continue }
            memcpy(dst, src, Int(min(source.mDataByteSize, destination[index].mDataByteSize)))
        }
        return buffer
    }
}
