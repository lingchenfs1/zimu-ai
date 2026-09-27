import AppKit
import Carbon.HIToolbox

/// 全局快捷键（Carbon RegisterEventHotKey，不需要辅助功能权限）
@MainActor
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    struct HotKey: Identifiable {
        let id: UInt32
        let keyCode: UInt32
        let modifiers: UInt32
        let title: String
        let display: String
    }

    /// 内置快捷键：⌃⌥S 开始/停止，⌃⌥L 锁定/解锁，⌃⌥H 显示/隐藏
    static let startStop = HotKey(id: 1, keyCode: UInt32(kVK_ANSI_S), modifiers: UInt32(controlKey | optionKey), title: "开始 / 停止字幕", display: "⌃⌥S")
    static let lockToggle = HotKey(id: 2, keyCode: UInt32(kVK_ANSI_L), modifiers: UInt32(controlKey | optionKey), title: "锁定 / 解锁字幕窗", display: "⌃⌥L")
    static let visibilityToggle = HotKey(id: 3, keyCode: UInt32(kVK_ANSI_H), modifiers: UInt32(controlKey | optionKey), title: "显示 / 隐藏字幕窗", display: "⌃⌥H")
    static let all: [HotKey] = [startStop, lockToggle, visibilityToggle]

    private var eventHandler: EventHandlerRef?
    private var registered: [UInt32: EventHotKeyRef] = [:]
    private var actions: [UInt32: () -> Void] = [:]
    /// 注册失败的快捷键（通常是被其他应用占用）
    private(set) var failedHotKeys: [HotKey] = []

    private static let signature: OSType = 0x5A_49_4D_55 // "ZIMU"

    private init() {}

    private func installHandlerIfNeeded() {
        guard eventHandler == nil else { return }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, _ -> OSStatus in
                guard let event else { return OSStatus(eventNotHandledErr) }
                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard status == noErr else { return status }
                let id = hotKeyID.id
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        HotKeyCenter.shared.perform(id)
                    }
                }
                return noErr
            },
            1,
            &eventType,
            nil,
            &eventHandler
        )
        if status != noErr {
            NSLog("ZimuAI: InstallEventHandler failed: \(status)")
        }
    }

    func register(_ hotKey: HotKey, action: @escaping () -> Void) {
        installHandlerIfNeeded()
        unregister(hotKey.id)
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: hotKey.id)
        let status = RegisterEventHotKey(hotKey.keyCode, hotKey.modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
        if status == noErr, let ref {
            registered[hotKey.id] = ref
            actions[hotKey.id] = action
            failedHotKeys.removeAll { $0.id == hotKey.id }
        } else {
            failedHotKeys.append(hotKey)
            NSLog("ZimuAI: RegisterEventHotKey \(hotKey.display) failed: \(status)")
        }
    }

    func unregister(_ id: UInt32) {
        if let ref = registered.removeValue(forKey: id) {
            UnregisterEventHotKey(ref)
        }
        actions.removeValue(forKey: id)
    }

    func unregisterAll() {
        for id in Array(registered.keys) {
            unregister(id)
        }
        failedHotKeys.removeAll()
    }

    private func perform(_ id: UInt32) {
        actions[id]?()
    }
}
