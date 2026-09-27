import AppKit
import SwiftUI
import ZimuCore

/// 管理悬浮字幕窗：创建、显示 / 隐藏、锁定（鼠标穿透）、拖动、缩放、位置记忆
@MainActor
final class OverlayController {
    private let settingsStore: SettingsStore
    private let subtitles: SubtitleStore
    private var panel: OverlayPanel?

    private var moveStart: (origin: NSPoint, mouse: NSPoint)?
    private var resizeStart: (frame: NSRect, mouse: NSPoint)?

    static let minimumSize = NSSize(width: 280, height: 70)

    init(settingsStore: SettingsStore, subtitles: SubtitleStore) {
        self.settingsStore = settingsStore
        self.subtitles = subtitles
    }

    func setUp() {
        guard panel == nil else { return }
        let panel = OverlayPanel(contentRect: initialFrame())
        let root = SubtitleOverlayView(
            settingsStore: settingsStore,
            subtitles: subtitles,
            controller: self
        )
        let hosting = OverlayHostingView(rootView: root)
        hosting.sizingOptions = []
        panel.contentView = hosting
        self.panel = panel

        ChangeObserver.observe({ [settingsStore] in settingsStore.settings.overlayLocked }) { [weak self] locked in
            self?.panel?.ignoresMouseEvents = locked
        }
        ChangeObserver.observe({ [settingsStore] in settingsStore.settings.overlayVisible }) { [weak self] visible in
            self?.applyVisibility(visible)
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.ensureOnScreen()
            }
        }
    }

    private func applyVisibility(_ visible: Bool) {
        guard let panel else { return }
        if visible {
            panel.orderFrontRegardless()
        } else {
            panel.orderOut(nil)
        }
    }

    // MARK: 锁定 / 显示

    var isLocked: Bool { settingsStore.settings.overlayLocked }

    func toggleLocked() {
        settingsStore.settings.overlayLocked.toggle()
    }

    func toggleVisible() {
        settingsStore.settings.overlayVisible.toggle()
    }

    func resetPosition() {
        guard let panel else { return }
        panel.setFrame(defaultFrame(), display: true)
        saveFrame()
        settingsStore.settings.overlayVisible = true
        panel.orderFrontRegardless()
    }

    // MARK: 拖动与缩放（使用屏幕坐标，避免窗口移动带来的坐标抖动）

    func dragChanged() {
        guard let panel else { return }
        let mouse = NSEvent.mouseLocation
        if moveStart == nil {
            moveStart = (panel.frame.origin, mouse)
        }
        guard let start = moveStart else { return }
        let origin = NSPoint(x: start.origin.x + mouse.x - start.mouse.x, y: start.origin.y + mouse.y - start.mouse.y)
        panel.setFrameOrigin(origin)
    }

    func dragEnded() {
        moveStart = nil
        saveFrame()
    }

    func resizeChanged() {
        guard let panel else { return }
        let mouse = NSEvent.mouseLocation
        if resizeStart == nil {
            resizeStart = (panel.frame, mouse)
        }
        guard let start = resizeStart else { return }
        let dx = mouse.x - start.mouse.x
        let dy = mouse.y - start.mouse.y
        let width = max(Self.minimumSize.width, start.frame.width + dx)
        let height = max(Self.minimumSize.height, start.frame.height - dy)
        // 右下角拖动：左上角固定
        let frame = NSRect(x: start.frame.minX, y: start.frame.maxY - height, width: width, height: height)
        panel.setFrame(frame, display: true)
    }

    func resizeEnded() {
        resizeStart = nil
        saveFrame()
    }

    // MARK: 位置记忆

    private func saveFrame() {
        guard let frame = panel?.frame else { return }
        settingsStore.settings.overlayFrame = OverlayFrame(
            x: frame.origin.x,
            y: frame.origin.y,
            width: frame.width,
            height: frame.height
        )
    }

    private func initialFrame() -> NSRect {
        if let saved = settingsStore.settings.overlayFrame {
            let rect = NSRect(x: saved.x, y: saved.y, width: saved.width, height: saved.height)
            if NSScreen.screens.contains(where: { $0.visibleFrame.intersects(rect) }) {
                return rect
            }
        }
        return defaultFrame()
    }

    private func defaultFrame() -> NSRect {
        let screen = NSScreen.main ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let width = min(960, max(Self.minimumSize.width, visible.width * 0.62))
        let height: CGFloat = 170
        return NSRect(x: visible.midX - width / 2, y: visible.minY + 60, width: width, height: height)
    }

    private func ensureOnScreen() {
        guard let panel else { return }
        if !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(panel.frame) }) {
            panel.setFrame(defaultFrame(), display: true)
            saveFrame()
        }
    }
}
