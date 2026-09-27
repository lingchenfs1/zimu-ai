import AppKit
import AudioToolbox
import CoreAudio

enum AudioCaptureError: LocalizedError {
    case coreAudio(String, OSStatus)
    case noAudioProcess(String)
    case invalidFormat

    var errorDescription: String? {
        switch self {
        case .coreAudio(let action, let status):
            return "系统音频捕获失败（\(action)，错误码 \(status)）"
        case .noAudioProcess(let bundleID):
            return "所选应用（\(bundleID)）当前没有音频输出。请先让它开始播放，或改为捕获全部系统音频。"
        case .invalidFormat:
            return "无法读取系统音频格式"
        }
    }
}

/// Core Audio 属性读取工具
enum CoreAudioUtils {
    static let systemObject = AudioObjectID(kAudioObjectSystemObject)

    static func makeAddress(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    static func read<T>(_ objectID: AudioObjectID, _ selector: AudioObjectPropertySelector, default value: T) throws -> T {
        var address = makeAddress(selector)
        var size = UInt32(MemoryLayout<T>.size)
        var result = value
        let status = withUnsafeMutablePointer(to: &result) { pointer in
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, pointer)
        }
        guard status == noErr else { throw AudioCaptureError.coreAudio("读取属性 \(fourCC(selector))", status) }
        return result
    }

    static func readString(_ objectID: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> String {
        var address = makeAddress(selector)
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var value: Unmanaged<CFString>?
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, pointer)
        }
        guard status == noErr else { throw AudioCaptureError.coreAudio("读取属性 \(fourCC(selector))", status) }
        guard let string = value?.takeRetainedValue() else { return "" }
        return string as String
    }

    static func readObjectList(_ objectID: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> [AudioObjectID] {
        var address = makeAddress(selector)
        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(objectID, &address, 0, nil, &size)
        guard status == noErr else { throw AudioCaptureError.coreAudio("读取列表大小 \(fourCC(selector))", status) }
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        guard count > 0 else { return [] }
        var list = [AudioObjectID](repeating: AudioObjectID(kAudioObjectUnknown), count: count)
        status = list.withUnsafeMutableBufferPointer { buffer in
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, buffer.baseAddress!)
        }
        guard status == noErr else { throw AudioCaptureError.coreAudio("读取列表 \(fourCC(selector))", status) }
        return Array(list.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }

    /// 进程 PID → Core Audio 进程对象
    static func processObjectID(for pid: pid_t) -> AudioObjectID? {
        var address = makeAddress(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var pid = pid
        var objectID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafeMutablePointer(to: &objectID) { pointer in
            AudioObjectGetPropertyData(systemObject, &address, UInt32(MemoryLayout<pid_t>.size), &pid, &size, pointer)
        }
        guard status == noErr, objectID != AudioObjectID(kAudioObjectUnknown) else { return nil }
        return objectID
    }

    /// 聚合设备的时钟设备：优先使用默认输出设备（媒体播放的设备），其次是系统提示音设备
    static func defaultOutputDevice() throws -> AudioDeviceID {
        let unknown = AudioDeviceID(kAudioObjectUnknown)
        for selector in [kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDefaultSystemOutputDevice] {
            if let id: AudioDeviceID = try? read(systemObject, selector, default: unknown), id != unknown {
                return id
            }
        }
        throw AudioCaptureError.coreAudio("读取默认输出设备", OSStatus(kAudioHardwareBadDeviceError))
    }

    static func fourCC(_ value: UInt32) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((value >> UInt32($0)) & 0xFF) }
        if bytes.allSatisfy({ $0 >= 32 && $0 < 127 }) {
            return String(decoding: bytes, as: UTF8.self)
        }
        return String(value)
    }
}

/// 正在使用音频的应用
struct AudioApp: Identifiable, Hashable {
    let bundleID: String
    let name: String
    let isPlaying: Bool

    var id: String { bundleID }
}

/// 列出 Core Audio 知道的音频进程
enum AudioProcessList {
    struct Process {
        let objectID: AudioObjectID
        let pid: pid_t
        let bundleID: String
        let isRunningOutput: Bool
    }

    static func processes() -> [Process] {
        let ids = (try? CoreAudioUtils.readObjectList(CoreAudioUtils.systemObject, kAudioHardwarePropertyProcessObjectList)) ?? []
        let ownPID = ProcessInfo.processInfo.processIdentifier
        return ids.compactMap { id in
            let pid: pid_t = (try? CoreAudioUtils.read(id, kAudioProcessPropertyPID, default: pid_t(-1))) ?? -1
            guard pid > 0, pid != ownPID else { return nil }
            let bundleID = (try? CoreAudioUtils.readString(id, kAudioProcessPropertyBundleID)) ?? ""
            guard !bundleID.isEmpty else { return nil }
            let running: UInt32 = (try? CoreAudioUtils.read(id, kAudioProcessPropertyIsRunningOutput, default: UInt32(0))) ?? 0
            return Process(objectID: id, pid: pid, bundleID: bundleID, isRunningOutput: running != 0)
        }
    }

    /// 供设置界面选择的应用列表（按 bundle ID 去重）
    static func applications() -> [AudioApp] {
        var result: [String: AudioApp] = [:]
        for process in processes() {
            let name = NSRunningApplication(processIdentifier: process.pid)?.localizedName ?? process.bundleID
            let existing = result[process.bundleID]
            result[process.bundleID] = AudioApp(
                bundleID: process.bundleID,
                name: existing?.name ?? name,
                isPlaying: (existing?.isPlaying ?? false) || process.isRunningOutput
            )
        }
        return result.values.sorted { lhs, rhs in
            if lhs.isPlaying != rhs.isPlaying { return lhs.isPlaying }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    /// 与 bundle ID 匹配的进程（包括 "com.google.Chrome.helper" 这类子进程）
    static func objectIDs(matching bundleID: String) -> [AudioObjectID] {
        processes()
            .filter { $0.bundleID == bundleID || $0.bundleID.hasPrefix(bundleID + ".") }
            .map(\.objectID)
    }
}
