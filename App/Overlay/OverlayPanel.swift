import AppKit

/// 悬浮字幕窗：无边框、不抢焦点、所有桌面可见、可以显示在全屏视频之上
final class OverlayPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        isMovable = false
        isMovableByWindowBackground = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        titleVisibility = .hidden
    }

    // 不成为 key window，避免抢走视频播放器的键盘焦点
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
