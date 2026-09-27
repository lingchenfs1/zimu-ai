import AppKit
import SwiftUI

/// 设置窗口。菜单栏应用没有 Dock 图标，打开设置时临时切换为普通应用，方便窗口置前。
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?

    func show(model: AppModel) {
        if window == nil {
            let hosting = NSHostingController(rootView: SettingsView().environment(model))
            let window = NSWindow(contentViewController: hosting)
            window.title = "字幕AI 设置"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 640, height: 560))
            window.minSize = NSSize(width: 560, height: 420)
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            self.window = window
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}
