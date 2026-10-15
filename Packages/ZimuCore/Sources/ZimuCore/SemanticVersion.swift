import Foundation

/// 版本号（语义化版本）：`v1.4.0`、`1.4`、`1.4.0-beta.1`。
///
/// 缺少的段按 0 处理（`1.4` 等于 `1.4.0`）；带预发布后缀的版本低于同号正式版。
public struct SemanticVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int
    /// 预发布标识，例如 `beta.1` → ["beta", "1"]；正式版为空
    public let prerelease: [String]

    public init(major: Int, minor: Int = 0, patch: Int = 0, prerelease: [String] = []) {
        self.major = major
        self.minor = minor
        self.patch = patch
        self.prerelease = prerelease
    }

    public init?(_ text: String) {
        var string = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if string.hasPrefix("v") || string.hasPrefix("V") {
            string.removeFirst()
        }
        // 去掉构建元数据（+ 之后）
        if let plus = string.firstIndex(of: "+") {
            string = String(string[..<plus])
        }
        var prerelease: [String] = []
        if let dash = string.firstIndex(of: "-") {
            prerelease = string[string.index(after: dash)...].split(separator: ".").map(String.init)
            string = String(string[..<dash])
            guard !prerelease.isEmpty, prerelease.allSatisfy({ !$0.isEmpty }) else { return nil }
        }
        let parts = string.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.allSatisfy(\.isASCII), part.allSatisfy(\.isNumber), let value = Int(part) else { return nil }
            numbers.append(value)
        }
        while numbers.count < 3 { numbers.append(0) }
        self.init(major: numbers[0], minor: numbers[1], patch: numbers[2], prerelease: prerelease)
    }

    public var isPrerelease: Bool { !prerelease.isEmpty }

    public var description: String {
        let core = "\(major).\(minor).\(patch)"
        return prerelease.isEmpty ? core : core + "-" + prerelease.joined(separator: ".")
    }

    public static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }
        // 正式版高于预发布版
        switch (lhs.prerelease.isEmpty, rhs.prerelease.isEmpty) {
        case (true, true): return false
        case (true, false): return false
        case (false, true): return true
        case (false, false): break
        }
        for (a, b) in zip(lhs.prerelease, rhs.prerelease) where a != b {
            switch (Int(a), Int(b)) {
            case let (x?, y?): return x < y
            case (_?, nil): return true // 数字标识低于字母标识
            case (nil, _?): return false
            case (nil, nil): return a < b
            }
        }
        return lhs.prerelease.count < rhs.prerelease.count
    }
}
