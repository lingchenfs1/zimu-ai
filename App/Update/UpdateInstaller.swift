import CoreServices
import Foundation
import ZimuCore

enum UpdateInstallError: LocalizedError {
    case extractFailed(String)
    case noAppInArchive
    case invalidBundle([String])
    case unreadableBundle(String)

    var errorDescription: String? {
        switch self {
        case .extractFailed(let detail):
            return "解压更新包失败：\(detail)"
        case .noAppInArchive:
            return "更新包里没有找到应用"
        case .invalidBundle(let problems):
            return "新版本没有通过检查：" + problems.joined(separator: "；")
        case .unreadableBundle(let detail):
            return "无法读取新版本的信息：\(detail)"
        }
    }
}

/// 解压、校验并替换 App（决策 D21）
@MainActor
final class UpdateInstaller {
    /// 解压并校验好的新版本
    struct Prepared {
        let info: UpdateInfo
        let stagingRoot: URL
        let stagedApp: URL
    }

    /// 当前 App 的安装位置（解析符号链接；保留用户改过的名字）
    let installedApp: URL
    let currentVersion: SemanticVersion
    let bundleIdentifier: String
    /// 启动时读取的当前签名身份（替换 App 包之前读取）
    let runningIdentity: CodeSignature.Identity?

    init(installedApp: URL = Bundle.main.bundleURL.resolvingSymlinksInPath(), currentVersion: SemanticVersion, bundleIdentifier: String) {
        self.installedApp = installedApp
        self.currentVersion = currentVersion
        self.bundleIdentifier = bundleIdentifier
        self.runningIdentity = try? CodeSignature.runningApp()
    }

    // MARK: 位置

    static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("ZimuAI", isDirectory: true)
    }

    static var downloadDirectory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("io.github.lingchenfs1.ZimuAI/Updates", isDirectory: true)
    }

    static var logFile: URL {
        let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Logs/ZimuAI/update.log")
    }

    private static var markerFile: URL {
        supportDirectory.appendingPathComponent("pending-update.json")
    }

    /// 用过的后备暂存目录（在 App 旁边而不是临时文件夹里，系统不会清理）
    private static let fallbackRootsKey = "zimu.update.fallbackStagingRoots"

    /// 当前位置能否原地更新
    func locationProblem() -> InstallLocationProblem? {
        let values = try? installedApp.resourceValues(forKeys: [.volumeIsReadOnlyKey])
        let parent = installedApp.deletingLastPathComponent()
        return InstallLocationCheck.problem(
            bundlePath: installedApp.path,
            isOnReadOnlyVolume: values?.volumeIsReadOnly ?? false,
            parentWritable: access(parent.path, W_OK) == 0,
            bundleWritable: access(installedApp.path, W_OK) == 0
        )
    }

    /// 是否能做「同一签名」校验（当前 App 用固定证书签名）
    var verifiesSameSigner: Bool {
        runningIdentity.map { !$0.isAdHocOrUnsigned } ?? false
    }

    // MARK: 暂存与校验

    func prepare(archive: URL, info: UpdateInfo) async throws -> Prepared {
        let root = try makeStagingRoot()
        do {
            let extracted = root.appendingPathComponent("extracted", isDirectory: true)
            try FileManager.default.createDirectory(at: extracted, withIntermediateDirectories: true)
            let unzip = try await ProcessRunner.run("/usr/bin/ditto", ["-x", "-k", archive.path, extracted.path], timeout: 300)
            guard unzip.status == 0, !unzip.timedOut else {
                throw UpdateInstallError.extractFailed(unzip.stderrText.isEmpty ? "退出码 \(unzip.status)" : unzip.stderrText)
            }

            // 压缩包顶层必须恰好有一个 .app，且不是符号链接
            let items = try FileManager.default.contentsOfDirectory(at: extracted, includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey])
            let apps = items.filter { $0.pathExtension == "app" }
            guard apps.count == 1, let app = apps.first,
                  let values = try? app.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey]),
                  values.isSymbolicLink != true, values.isDirectory == true
            else { throw UpdateInstallError.noAppInArchive }

            let staged = root.appendingPathComponent(installedApp.lastPathComponent, isDirectory: true)
            try FileManager.default.moveItem(at: app, to: staged)
            try? FileManager.default.removeItem(at: extracted)
            try? FileManager.default.removeItem(at: archive)

            try await validate(staged: staged, info: info)

            // 自己下载的文件没有隔离属性，这里再保险地去掉一次
            _ = try? await ProcessRunner.run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", staged.path], timeout: 60)
            return Prepared(info: info, stagingRoot: root, stagedApp: staged)
        } catch {
            Self.removeStagingRoot(root, installedApp: installedApp)
            throw error
        }
    }

    private func validate(staged: URL, info: UpdateInfo) async throws {
        let bundle: BundleInfo
        do {
            bundle = try BundleInfo(plistData: Data(contentsOf: staged.appendingPathComponent("Contents/Info.plist")))
        } catch {
            throw UpdateInstallError.unreadableBundle(error.localizedDescription)
        }
        let os = ProcessInfo.processInfo.operatingSystemVersion
        var problems = StagedBundleValidator.problems(
            staged: bundle,
            expectedIdentifier: bundleIdentifier,
            expectedVersion: info.version,
            currentVersion: currentVersion,
            systemVersion: SemanticVersion(major: os.majorVersion, minor: os.minorVersion, patch: os.patchVersion)
        )
        if let executable = bundle.executable, !executable.isEmpty,
           !FileManager.default.isExecutableFile(atPath: staged.appendingPathComponent("Contents/MacOS/\(executable)").path) {
            problems.append("安装包缺少可执行文件")
        }
        guard problems.isEmpty else { throw UpdateInstallError.invalidBundle(problems) }

        // 当前 App 用固定证书签名时，新版本必须满足当前 App 的指定要求（同一签名）；ad-hoc 时只能校验完整性。
        // 严格校验要读完整个 App 包，放到后台线程，免得卡住字幕和菜单
        let requirement = verifiesSameSigner ? runningIdentity?.designatedRequirement : nil
        try await Task.detached(priority: .userInitiated) {
            try CodeSignature.validate(bundle: staged, satisfying: requirement)
        }.value
    }

    /// 与安装位置在同一个卷上的暂存目录（原子替换需要同卷）
    private func makeStagingRoot() throws -> URL {
        let manager = FileManager.default
        let parent = installedApp.deletingLastPathComponent()
        if let root = try? manager.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: installedApp, create: true),
           Self.sameVolume(root, parent) {
            return root
        }
        let fallback = parent.appendingPathComponent(".ZimuAI-update-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: fallback, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        // 记下来，万一遗留（例如等待确认安装时崩溃），下次启动时删除
        let defaults = UserDefaults.standard
        defaults.set((defaults.stringArray(forKey: Self.fallbackRootsKey) ?? []) + [fallback.path], forKey: Self.fallbackRootsKey)
        return fallback
    }

    private static func sameVolume(_ a: URL, _ b: URL) -> Bool {
        let key = URLResourceKey.volumeIdentifierKey
        guard let first = try? a.resourceValues(forKeys: [key]).volumeIdentifier as? NSObject,
              let second = try? b.resourceValues(forKeys: [key]).volumeIdentifier as? NSObject
        else { return false }
        return first.isEqual(second)
    }

    // MARK: 安装

    /// 在软件仍在运行时替换 App，然后安排重启。返回是否成功安排了重启（失败时需要用户手动打开）。
    /// 替换前重新校验暂存的新版本。失败时抛出错误：原来的 App 不变，暂存目录已删除；
    /// 只有旧版本没能放回原处时（BundleSwapError.rollbackFailed）安装位置上没有 App，这时保留暂存目录（新旧两个版本都在里面）。
    func install(_ prepared: Prepared, launchAtLoginEnabled: Bool) async throws -> Bool {
        let backup = prepared.stagingRoot.appendingPathComponent("previous-" + installedApp.lastPathComponent, isDirectory: true)
        let marker = PendingUpdateMarker(
            fromVersion: currentVersion.description,
            toVersion: prepared.info.versionString,
            installedPath: installedApp.path,
            previousBundlePath: backup.path,
            stagingRoot: prepared.stagingRoot.path,
            launchAtLoginWasEnabled: launchAtLoginEnabled,
            createdAt: Date()
        )
        do {
            // 等待确认期间新版本一直放在用户可写的暂存目录里，替换前再校验一次
            try await validate(staged: prepared.stagedApp, info: prepared.info)
            try FileManager.default.createDirectory(at: Self.supportDirectory, withIntermediateDirectories: true)
            try marker.encoded().write(to: Self.markerFile, options: .atomic)
        } catch {
            Self.removeStagingRoot(prepared.stagingRoot, installedApp: installedApp)
            Self.log("install aborted: \(error)")
            throw error
        }

        do {
            try BundleSwapper.swap(installed: installedApp.path, staged: prepared.stagedApp.path, backup: backup.path)
        } catch {
            try? FileManager.default.removeItem(at: Self.markerFile)
            if case .rollbackFailed = error as? BundleSwapError {
                // 安装位置上已经没有 App：暂存目录里是新旧两个版本仅有的副本，不能删除
                Self.log("swap failed, old version at \(backup.path), new version at \(prepared.stagedApp.path): \(error)")
            } else {
                Self.removeStagingRoot(prepared.stagingRoot, installedApp: installedApp)
                Self.log("swap failed: \(error)")
            }
            throw error
        }
        Self.log("installed \(prepared.info.versionString) at \(installedApp.path)")
        LSRegisterURL(installedApp as CFURL, true)

        do {
            try ProcessRunner.spawnDetached(
                "/bin/sh",
                UpdateScripts.relaunchArguments(pid: getpid(), appPath: installedApp.path, timeoutSeconds: 30),
                logFile: Self.logFile
            )
            return true
        } catch {
            Self.log("relaunch helper failed: \(error)")
            return false
        }
    }

    // MARK: 更新后

    struct PostUpdateResult {
        let updatedTo: String
        let launchAtLoginWasEnabled: Bool
    }

    /// 启动时调用：处理上次更新留下的标记，清理旧版本、暂存目录和下载缓存
    static func handlePendingUpdate(installedApp: URL, runningVersion: String) -> PostUpdateResult? {
        defer {
            try? FileManager.default.removeItem(at: downloadDirectory)
            removeLeftoverFallbackRoots(installedApp: installedApp)
        }
        guard let data = try? Data(contentsOf: markerFile) else { return nil }
        try? FileManager.default.removeItem(at: markerFile)
        guard let marker = try? PendingUpdateMarker.decode(data) else { return nil }
        removeStagingRoot(URL(fileURLWithPath: marker.stagingRoot, isDirectory: true), installedApp: installedApp)
        switch marker.outcome(runningVersion: runningVersion, now: Date()) {
        case .succeeded:
            log("now running \(runningVersion)")
            return PostUpdateResult(updatedTo: runningVersion, launchAtLoginWasEnabled: marker.launchAtLoginWasEnabled)
        case .notApplied, .stale:
            log("marker for \(marker.toVersion) ignored (running \(runningVersion))")
            return nil
        }
    }

    /// 只删除确实是更新暂存目录的路径，绝不删除 App 本身或它所在的文件夹。
    /// 安装位置上没有 App 时什么都不删：暂存目录里可能是仅有的副本（旧版本没能放回原处）
    static func removeStagingRoot(_ root: URL, installedApp: URL) {
        let path = root.standardizedFileURL.path
        let app = installedApp.standardizedFileURL.path
        let parent = installedApp.deletingLastPathComponent().standardizedFileURL.path
        let looksLikeStaging = path.contains("/TemporaryItems/") || path.contains("/.ZimuAI-update-") || path.contains("(A Document Being Saved By")
        guard looksLikeStaging, path != app, path != parent, !app.hasPrefix(path + "/"), path.count > 1,
              FileManager.default.fileExists(atPath: installedApp.appendingPathComponent("Contents/Info.plist").path)
        else { return }
        try? FileManager.default.removeItem(at: root)
    }

    /// 启动时删除遗留的后备暂存目录（例如等待确认安装时崩溃或被强制退出）。
    /// 只处理记录过的、就在当前 App 旁边的目录，不扫描文件夹（列出桌面、外接磁盘等位置会触发系统的访问提示）；
    /// 其他位置的记录留给那里的副本启动时处理
    private static func removeLeftoverFallbackRoots(installedApp: URL) {
        let defaults = UserDefaults.standard
        guard let paths = defaults.stringArray(forKey: fallbackRootsKey) else { return }
        let parent = installedApp.deletingLastPathComponent().standardizedFileURL.path
        var remaining: [String] = []
        for path in paths {
            let root = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
            // 只记录过 .ZimuAI-update-* 目录，其他记录直接丢弃
            guard root.lastPathComponent.hasPrefix(".ZimuAI-update-") else { continue }
            guard root.deletingLastPathComponent().standardizedFileURL.path == parent else {
                remaining.append(path)
                continue
            }
            guard FileManager.default.fileExists(atPath: path) else { continue }
            log("removing leftover \(path)")
            removeStagingRoot(root, installedApp: installedApp)
            if FileManager.default.fileExists(atPath: path) { remaining.append(path) }
        }
        if remaining.isEmpty {
            defaults.removeObject(forKey: fallbackRootsKey)
        } else {
            defaults.set(remaining, forKey: fallbackRootsKey)
        }
    }

    static func log(_ message: String) {
        let formatter = ISO8601DateFormatter()
        let line = "\(formatter.string(from: Date())) [app] \(message)\n"
        let url = logFile
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: url) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }
}
