import Foundation

/// 悬浮字幕窗从哪条边 / 哪个角缩放
public struct ResizeEdges: OptionSet, Hashable, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let left = ResizeEdges(rawValue: 1 << 0)
    public static let right = ResizeEdges(rawValue: 1 << 1)
    public static let top = ResizeEdges(rawValue: 1 << 2)
    public static let bottom = ResizeEdges(rawValue: 1 << 3)

    public static let topLeft: ResizeEdges = [.top, .left]
    public static let topRight: ResizeEdges = [.top, .right]
    public static let bottomLeft: ResizeEdges = [.bottom, .left]
    public static let bottomRight: ResizeEdges = [.bottom, .right]

    /// 四条边 + 四个角
    public static let allHandles: [ResizeEdges] = [
        .left, .right, .top, .bottom, .topLeft, .topRight, .bottomLeft, .bottomRight,
    ]
}

public enum OverlayGeometry {
    /// 拖动缩放后的窗口位置和大小。
    ///
    /// 使用屏幕坐标（原点在左下角，y 向上）；`dx` / `dy` 是鼠标相对按下时的位移。
    /// 被拖动的边跟着鼠标走，对边保持不动；宽高不小于最小值。
    public static func resized(
        _ start: OverlayFrame,
        edges: ResizeEdges,
        dx: Double,
        dy: Double,
        minWidth: Double,
        minHeight: Double
    ) -> OverlayFrame {
        var frame = start
        if edges.contains(.right) {
            frame.width = max(minWidth, start.width + dx)
        } else if edges.contains(.left) {
            frame.width = max(minWidth, start.width - dx)
            frame.x = start.x + start.width - frame.width
        }
        if edges.contains(.top) {
            frame.height = max(minHeight, start.height + dy)
        } else if edges.contains(.bottom) {
            frame.height = max(minHeight, start.height - dy)
            frame.y = start.y + start.height - frame.height
        }
        return frame
    }
}
