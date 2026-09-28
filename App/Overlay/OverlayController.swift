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
    private var resizeStart: (frame: NSRect, mouse: NSPoint, edges: ResizeEdges)?
    private var container: OverlayContainerView?

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
        let container = OverlayContainerView(content: hosting, controller: self)
        panel.contentView = container
        self.panel = panel
        self.container = container

        ChangeObserver.observe({ [settingsStore] in settingsStore.settings.overlayLocked }) { [weak self] locked in
            guard let self else { return }
            self.panel?.ignoresMouseEvents = locked
            self.container?.resizingEnabled = !locked
            if locked {
                self.moveStart = nil
                self.endResize()
            }
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
        guard let panel, !isResizing else { return }
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

    /// 由四边四角的 AppKit 缩放手柄调用（见 OverlayContainerView）
    var isResizing: Bool { resizeStart != nil }

    func beginResize(edges: ResizeEdges) {
        guard let panel, !isLocked else { return }
        moveStart = nil
        resizeStart = (panel.frame, NSEvent.mouseLocation, edges)
    }

    func continueResize() {
        guard let panel, let start = resizeStart else { return }
        let mouse = NSEvent.mouseLocation
        let frame = OverlayGeometry.resized(
            OverlayFrame(start.frame),
            edges: start.edges,
            dx: mouse.x - start.mouse.x,
            dy: mouse.y - start.mouse.y,
            minWidth: Self.minimumSize.width,
            minHeight: Self.minimumSize.height
        )
        panel.setFrame(NSRect(frame), display: true)
    }

    func endResize() {
        guard resizeStart != nil else { return }
        resizeStart = nil
        saveFrame()
    }

    // MARK: 位置记忆

    private func saveFrame() {
        guard let frame = panel?.frame else { return }
        settingsStore.settings.overlayFrame = OverlayFrame(frame)
    }

    private func initialFrame() -> NSRect {
        if let saved = settingsStore.settings.overlayFrame {
            let rect = NSRect(saved)
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

extension OverlayFrame {
    init(_ rect: NSRect) {
        self.init(x: rect.origin.x, y: rect.origin.y, width: rect.width, height: rect.height)
    }
}

extension NSRect {
    init(_ frame: OverlayFrame) {
        self.init(x: frame.x, y: frame.y, width: frame.width, height: frame.height)
    }
}
