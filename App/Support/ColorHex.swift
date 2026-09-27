import AppKit
import SwiftUI

extension Color {
    /// 从 "#RRGGBB" / "#RRGGBBAA" 创建颜色
    init(hex: String, fallback: Color = .white) {
        var string = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if string.hasPrefix("#") { string.removeFirst() }
        guard string.count == 6 || string.count == 8, let value = UInt64(string, radix: 16) else {
            self = fallback
            return
        }
        let red, green, blue, alpha: Double
        if string.count == 8 {
            red = Double((value >> 24) & 0xFF) / 255
            green = Double((value >> 16) & 0xFF) / 255
            blue = Double((value >> 8) & 0xFF) / 255
            alpha = Double(value & 0xFF) / 255
        } else {
            red = Double((value >> 16) & 0xFF) / 255
            green = Double((value >> 8) & 0xFF) / 255
            blue = Double(value & 0xFF) / 255
            alpha = 1
        }
        self = Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha)
    }

    /// 转成 "#RRGGBB"
    func hexString() -> String {
        let color = NSColor(self).usingColorSpace(.sRGB) ?? .white
        func component(_ value: CGFloat) -> Int {
            max(0, min(255, Int((value * 255).rounded())))
        }
        return String(
            format: "#%02X%02X%02X",
            component(color.redComponent),
            component(color.greenComponent),
            component(color.blueComponent)
        )
    }
}
