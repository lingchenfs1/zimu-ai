import Foundation

/// 文本拼接、CJK 判断等小工具
public enum TextUtilities {
    /// 汉字、假名、CJK 标点、全角字符：这些字符之间拼接时不加空格
    public static func isNoSpaceScript(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3000...0x303F, // CJK 标点
             0x3040...0x30FF, // 平假名、片假名
             0x3400...0x4DBF, // CJK 扩展 A
             0x4E00...0x9FFF, // CJK 统一汉字
             0xF900...0xFAFF, // CJK 兼容汉字
             0xFF00...0xFFEF, // 全角字符
             0x20000...0x2FA1F: // CJK 扩展 B 及以后
            return true
        default:
            return false
        }
    }

    /// 文本中「不加空格」文字的占比是否较高（用于决定字幕长度上限）
    public static func isMostlyNoSpaceScript(_ text: String) -> Bool {
        var total = 0
        var cjk = 0
        for scalar in text.unicodeScalars where !scalar.properties.isWhitespace {
            total += 1
            if isNoSpaceScript(scalar) { cjk += 1 }
        }
        guard total > 0 else { return false }
        return Double(cjk) / Double(total) >= 0.3
    }

    /// 把两段识别文本拼起来：中日文直接相连，其他语言用空格分隔
    public static func join(_ lhs: String, _ rhs: String) -> String {
        let a = lhs.trimmingCharacters(in: .whitespacesAndNewlines)
        let b = rhs.trimmingCharacters(in: .whitespacesAndNewlines)
        if a.isEmpty { return b }
        if b.isEmpty { return a }
        if let last = a.unicodeScalars.last, let first = b.unicodeScalars.first,
           isNoSpaceScript(last) || isNoSpaceScript(first) {
            return a + b
        }
        return a + " " + b
    }

    /// 去掉空白和标点并转小写，用于比较识别文字是否「基本相同」
    public static func normalizedForComparison(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if scalar.properties.isWhitespace
                || CharacterSet.punctuationCharacters.contains(scalar)
                || CharacterSet.symbols.contains(scalar) {
                continue
            }
            scalars.append(scalar)
        }
        return String(scalars).lowercased()
    }

    /// 是否只包含标点和空白
    public static func isOnlyPunctuation(_ text: String) -> Bool {
        text.unicodeScalars.allSatisfy { scalar in
            scalar.properties.isWhitespace
                || CharacterSet.punctuationCharacters.contains(scalar)
                || CharacterSet.symbols.contains(scalar)
        }
    }
}
