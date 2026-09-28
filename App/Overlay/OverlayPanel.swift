import AppKit
import SwiftUI
import ZimuCore

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
        acceptsMouseMovedEvents = true
    }

    // 不成为 key window，避免抢走视频播放器的键盘焦点
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// 窗口不是 key window 时也直接响应第一次点击 / 拖动
final class OverlayHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// 悬浮窗的根视图：SwiftUI 字幕内容铺满窗口，四条边和四个角盖一层 AppKit 缩放手柄。
///
/// 缩放手柄放在 SwiftUI 内容之上，不会被字幕背景挡住，也不会触发 SwiftUI 的拖动移动手势（决策 D16）。
final class OverlayContainerView: NSView {
    private let content: NSView
    private var handles: [ResizeHandleView] = []

    /// 边的可拖动厚度
    static let edgeThickness: CGFloat = 8
    /// 角的可拖动区域边长
    static let cornerSize: CGFloat = 22

    init(content: NSView, controller: OverlayController) {
        self.content = content
        super.init(frame: .zero)
        content.autoresizingMask = [.width, .height]
        addSubview(content)
        // allHandles 先列四条边、再列四个角，角后添加、位于最上层
        for edges in ResizeEdges.allHandles {
            let handle = ResizeHandleView(edges: edges, controller: controller)
            handles.append(handle)
            addSubview(handle)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 锁定时隐藏缩放手柄
    var resizingEnabled = true {
        didSet {
            for handle in handles {
                handle.isHidden = !resizingEnabled
                window?.invalidateCursorRects(for: handle)
            }
        }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutHandles()
    }

    override func layout() {
        super.layout()
        layoutHandles()
    }

    private func layoutHandles() {
        content.frame = bounds
        let w = bounds.width
        let h = bounds.height
        let t = Self.edgeThickness
        let c = Self.cornerSize
        for handle in handles {
            let rect: NSRect
            switch handle.edges {
            case .left: rect = NSRect(x: 0, y: c, width: t, height: max(0, h - 2 * c))
            case .right: rect = NSRect(x: w - t, y: c, width: t, height: max(0, h - 2 * c))
            case .top: rect = NSRect(x: c, y: h - t, width: max(0, w - 2 * c), height: t)
            case .bottom: rect = NSRect(x: c, y: 0, width: max(0, w - 2 * c), height: t)
            case .topLeft: rect = NSRect(x: 0, y: h - c, width: c, height: c)
            case .topRight: rect = NSRect(x: w - c, y: h - c, width: c, height: c)
            case .bottomLeft: rect = NSRect(x: 0, y: 0, width: c, height: c)
            default: rect = NSRect(x: w - c, y: 0, width: c, height: c)
            }
            handle.frame = rect
        }
    }
}

/// 一条边或一个角上的缩放手柄：透明，鼠标移上去显示缩放光标，拖动时调整窗口大小
final class ResizeHandleView: NSView {
    let edges: ResizeEdges
    private weak var controller: OverlayController?
    private var trackingArea: NSTrackingArea?

    init(edges: ResizeEdges, controller: OverlayController) {
        self.edges = edges
        self.controller = controller
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private var cursor: NSCursor {
        let position: NSCursor.FrameResizePosition
        switch edges {
        case .left: position = .left
        case .right: position = .right
        case .top: position = .top
        case .bottom: position = .bottom
        case .topLeft: position = .topLeft
        case .topRight: position = .topRight
        case .bottomLeft: position = .bottomLeft
        default: position = .bottomRight
        }
        return NSCursor.frameResize(position: position, directions: .all)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // 悬浮窗不会成为 key window，光标区域（cursor rect）不一定生效，所以同时用 tracking area 主动设置光标
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: cursor)
    }

    override func updateTrackingAreas() {
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        cursor.set()
    }

    override func mouseMoved(with event: NSEvent) {
        cursor.set()
    }

    override func mouseExited(with event: NSEvent) {
        if controller?.isResizing != true {
            NSCursor.arrow.set()
        }
    }

    override func mouseDown(with event: NSEvent) {
        cursor.set()
        controller?.beginResize(edges: edges)
    }

    override func mouseDragged(with event: NSEvent) {
        cursor.set()
        controller?.continueResize()
    }

    override func mouseUp(with event: NSEvent) {
        controller?.endResize()
        if !(bounds.contains(convert(event.locationInWindow, from: nil))) {
            NSCursor.arrow.set()
        }
    }
}
