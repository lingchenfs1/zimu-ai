import Foundation

/// App 包 Info.plist 中与更新有关的字段
public struct BundleInfo: Sendable, Equatable {
    public var identifier: String
    public var shortVersion: String
    public var build: String?
    public var executable: String?
    public var minimumSystemVersion: String?

    public init(identifier: String, shortVersion: String, build: String? = nil, executable: String? = nil, minimumSystemVersion: String? = nil) {
        self.identifier = identifier
        self.shortVersion = shortVersion
        self.build = build
        self.executable = executable
        self.minimumSystemVersion = minimumSystemVersion
    }

    public enum ParseError: Error, Equatable {
        case notAPropertyList
        case missingField(String)
    }

    public init(plistData: Data) throws {
        guard let plist = try? PropertyListSerialization.propertyList(from: plistData, options: [], format: nil) as? [String: Any] else {
            throw ParseError.notAPropertyList
        }
        guard let identifier = plist["CFBundleIdentifier"] as? String, !identifier.isEmpty else {
            throw ParseError.missingField("CFBundleIdentifier")
        }
        guard let version = plist["CFBundleShortVersionString"] as? String, !version.isEmpty else {
            throw ParseError.missingField("CFBundleShortVersionString")
        }
        self.init(
            identifier: identifier,
            shortVersion: version,
            build: plist["CFBundleVersion"] as? String,
            executable: plist["CFBundleExecutable"] as? String,
            minimumSystemVersion: plist["LSMinimumSystemVersion"] as? String
        )
    }
}

/// 安装前检查解压出来的新 App（代码签名在 App 层另外校验）
public enum StagedBundleValidator {
    /// 返回发现的问题（中文说明）；为空表示可以安装
    public static func problems(
        staged: BundleInfo,
        expectedIdentifier: String,
        expectedVersion: SemanticVersion,
        currentVersion: SemanticVersion,
        systemVersion: SemanticVersion
    ) -> [String] {
        var problems: [String] = []
        if staged.identifier != expectedIdentifier {
            problems.append("安装包里的应用标识不一致（\(staged.identifier)）")
        }
        if let version = SemanticVersion(staged.shortVersion) {
            if version != expectedVersion {
                problems.append("安装包的版本（\(staged.shortVersion)）与发布的版本（\(expectedVersion)）不一致")
            } else if !(currentVersion < version) {
                problems.append("安装包的版本（\(staged.shortVersion)）不比当前版本新")
            }
        } else {
            problems.append("无法识别安装包的版本号（\(staged.shortVersion)）")
        }
        if let minimum = staged.minimumSystemVersion.flatMap(SemanticVersion.init), systemVersion < minimum {
            problems.append("新版本需要 macOS \(minimum) 或更高")
        }
        if staged.executable?.isEmpty ?? true {
            problems.append("安装包缺少可执行文件信息")
        }
        return problems
    }
}

/// 当前 App 所在位置能否原地更新
public enum InstallLocationProblem: Sendable, Equatable {
    /// 从「下载」等位置直接打开，被系统随机转移到只读位置运行（App Translocation）
    case translocated
    /// 在只读卷上运行（例如直接从挂载的 DMG 打开）
    case readOnlyVolume
    /// 没有权限修改 App 所在的文件夹
    case notWritable

    public var message: String {
        switch self {
        case .translocated:
            return "字幕AI 正在从临时位置运行，无法原地更新。请在访达中把字幕AI 拖到「应用程序」文件夹，然后从那里重新打开。"
        case .readOnlyVolume:
            return "字幕AI 正在从安装包（DMG）里直接运行，无法更新。请先把它拖到「应用程序」文件夹，然后从那里打开。"
        case .notWritable:
            return "没有权限替换字幕AI 所在的文件夹（可能需要管理员账号）。可以下载安装包手动安装。"
        }
    }
}

public enum InstallLocationCheck {
    public static func problem(
        bundlePath: String,
        isOnReadOnlyVolume: Bool,
        parentWritable: Bool,
        bundleWritable: Bool
    ) -> InstallLocationProblem? {
        if bundlePath.contains("/AppTranslocation/") { return .translocated }
        if isOnReadOnlyVolume { return .readOnlyVolume }
        if !parentWritable || !bundleWritable { return .notWritable }
        return nil
    }
}

/// 安装更新前写下的标记：新版本启动时据此清理旧版本、提示「已更新」、检查开机启动
public struct PendingUpdateMarker: Codable, Sendable, Equatable {
    public var fromVersion: String
    public var toVersion: String
    /// 安装位置（交换后是新版本）
    public var installedPath: String
    /// 交换后旧版本所在的位置（需要删除）
    public var previousBundlePath: String
    /// 暂存目录（需要删除）
    public var stagingRoot: String
    public var launchAtLoginWasEnabled: Bool
    public var createdAt: Date

    public init(
        fromVersion: String,
        toVersion: String,
        installedPath: String,
        previousBundlePath: String,
        stagingRoot: String,
        launchAtLoginWasEnabled: Bool,
        createdAt: Date
    ) {
        self.fromVersion = fromVersion
        self.toVersion = toVersion
        self.installedPath = installedPath
        self.previousBundlePath = previousBundlePath
        self.stagingRoot = stagingRoot
        self.launchAtLoginWasEnabled = launchAtLoginWasEnabled
        self.createdAt = createdAt
    }

    public enum Outcome: Sendable, Equatable {
        /// 已运行新版本
        case succeeded
        /// 运行的不是新版本（更新没有生效）
        case notApplied
        /// 标记太旧，直接清理
        case stale
    }

    public static let staleInterval: TimeInterval = 86_400

    public func outcome(runningVersion: String, now: Date) -> Outcome {
        if now.timeIntervalSince(createdAt) > Self.staleInterval || now < createdAt.addingTimeInterval(-60) {
            return .stale
        }
        guard let running = SemanticVersion(runningVersion), let target = SemanticVersion(toVersion) else {
            return .notApplied
        }
        return running == target ? .succeeded : .notApplied
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> PendingUpdateMarker {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(PendingUpdateMarker.self, from: data)
    }
}
