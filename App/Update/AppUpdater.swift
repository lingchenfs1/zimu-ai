import AppKit
import Observation
import ZimuCore

/// 软件内在线更新（决策 D21）：自动 / 手动检查、下载、校验、安装并重启
@MainActor
@Observable
final class AppUpdater {
    enum Phase: Equatable {
        case idle
        case checking(manual: Bool)
        case upToDate(checkedAt: Date)
        case available(UpdateInfo)
        case downloading(UpdateInfo, progress: Double)
        case preparing(UpdateInfo)
        /// 正在字幕或演示时，安装前先确认
        case awaitingConfirmation(UpdateInfo)
        case installing(UpdateInfo)
        case failed(UpdateInfo?, message: String)

        /// 正在下载 / 校验 / 安装，不能再开始检查
        var isBusy: Bool {
            switch self {
            case .checking, .downloading, .preparing, .awaitingConfirmation, .installing: return true
            default: return false
            }
        }

        /// 当前提示的新版本
        var info: UpdateInfo? {
            switch self {
            case .available(let info), .downloading(let info, _), .preparing(let info),
                 .awaitingConfirmation(let info), .installing(let info):
                return info
            case .failed(let info, _):
                return info
            default:
                return nil
            }
        }
    }

    private(set) var phase: Phase = .idle
    /// 刚从旧版本更新过来（显示「已更新到 vX」）
    private(set) var justUpdatedTo: String?
    /// 开机启动在更新后需要用户重新允许
    private(set) var loginItemNeedsApproval = false

    let configuration: UpdateConfiguration
    let currentVersion: SemanticVersion
    let currentVersionString: String

    /// 由 AppModel 设置：是否正在字幕 / 演示、安装前停止它们、退出软件
    @ObservationIgnored var isSubtitleActive: () -> Bool = { false }
    @ObservationIgnored var prepareForInstall: () async -> Void = {}
    @ObservationIgnored var terminate: () -> Void = { NSApp.terminate(nil) }

    @ObservationIgnored private let settingsStore: SettingsStore
    @ObservationIgnored private let installer: UpdateInstaller
    @ObservationIgnored private var schedulerTask: Task<Void, Never>?
    @ObservationIgnored private var workTask: Task<Void, Never>?
    @ObservationIgnored private var downloader: UpdateDownloader?
    @ObservationIgnored private var prepared: UpdateInstaller.Prepared?
    /// 旧版本没能放回原处时它所在的位置（安装位置上没有 App）
    @ObservationIgnored private var orphanedBackup: String?
    @ObservationIgnored private var wakeObserver: NSObjectProtocol?

    private static let lastCheckKey = "zimu.update.lastSuccessfulCheck"
    private static let rateLimitKey = "zimu.update.rateLimitedUntil"

    init(settingsStore: SettingsStore, bundle: Bundle = .main) {
        self.settingsStore = settingsStore
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        self.currentVersionString = version
        self.currentVersion = SemanticVersion(version) ?? SemanticVersion(major: 0)
        var repository = bundle.object(forInfoDictionaryKey: "ZimuUpdateRepository") as? String ?? "lingchenfs1/zimu-ai"
        #if DEBUG
        // 调试时可以指向测试用的发布仓库
        if let override = UserDefaults.standard.string(forKey: "ZimuUpdateRepositoryOverride"), !override.isEmpty {
            repository = override
        }
        #endif
        self.configuration = UpdateConfiguration(repository: repository)
        self.installer = UpdateInstaller(currentVersion: currentVersion, bundleIdentifier: bundle.bundleIdentifier ?? "io.github.lingchenfs1.ZimuAI")
    }

    /// 是否会校验「新版本与当前版本同一签名」（当前 App 用固定证书签名）
    var verifiesSameSigner: Bool { installer.verifiesSameSigner }

    var releasesPage: URL? { configuration.releasesPage }

    /// 旧版本没能放回原处、安装位置上仍然没有 App 时，旧版本所在的位置
    private var orphanedBackupIfInstallMissing: String? {
        guard let orphanedBackup, !FileManager.default.fileExists(atPath: installer.installedApp.path) else { return nil }
        return orphanedBackup
    }

    // MARK: 启动与定时检查

    func start() {
        if let result = UpdateInstaller.handlePendingUpdate(installedApp: installer.installedApp, runningVersion: currentVersionString) {
            justUpdatedTo = result.updatedTo
            restoreLaunchAtLoginIfNeeded(wasEnabled: result.launchAtLoginWasEnabled)
        }
        schedulerTask?.cancel()
        schedulerTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(UpdatePolicy.launchDelay))
            while !Task.isCancelled {
                self?.checkIfDue()
                try? await Task.sleep(for: .seconds(3600))
            }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.checkIfDue()
            }
        }
    }

    private func checkIfDue() {
        // 旧版本没能放回原处时保持失败提示（里面有旧版本的位置），不自动检查
        if orphanedBackupIfInstallMissing != nil { return }
        let defaults = UserDefaults.standard
        let due = UpdatePolicy.isAutoCheckDue(
            now: Date(),
            lastSuccessfulCheck: defaults.object(forKey: Self.lastCheckKey) as? Date,
            rateLimitedUntil: defaults.object(forKey: Self.rateLimitKey) as? Date,
            enabled: settingsStore.settings.autoCheckUpdates
        )
        guard due, !phase.isBusy else { return }
        // 已经在提示新版本时不重复检查
        if case .available = phase { return }
        runCheck(manual: false)
    }

    // MARK: 操作

    /// 手动「检查更新」
    func checkNow() {
        guard !phase.isBusy else { return }
        runCheck(manual: true)
    }

    private func runCheck(manual: Bool) {
        let previous = phase
        phase = .checking(manual: manual)
        let checker = UpdateChecker(
            configuration: configuration,
            currentVersion: currentVersion,
            userAgent: "ZimuAI/\(currentVersionString)",
            client: URLSessionHTTPClient(session: URLSession(configuration: .ephemeral))
        )
        workTask = Task { @MainActor [weak self] in
            do {
                let outcome = try await checker.check()
                guard let self else { return }
                UserDefaults.standard.set(Date(), forKey: Self.lastCheckKey)
                UserDefaults.standard.removeObject(forKey: Self.rateLimitKey)
                switch outcome {
                case .upToDate:
                    self.phase = .upToDate(checkedAt: Date())
                case .available(let info):
                    if UpdatePolicy.shouldNotify(info, skippedVersion: self.settingsStore.settings.skippedUpdateVersion, manual: manual) {
                        self.phase = .available(info)
                    } else {
                        self.phase = .upToDate(checkedAt: Date())
                    }
                }
            } catch {
                guard let self, !(error is CancellationError) else { return }
                if case UpdateCheckError.rateLimited(let until) = error {
                    UserDefaults.standard.set(until ?? Date().addingTimeInterval(UpdatePolicy.maximumRateLimitWait), forKey: Self.rateLimitKey)
                }
                // 自动检查失败不打扰用户；手动检查失败时保留已经发现的新版本
                self.phase = manual ? .failed(previous.info, message: error.localizedDescription) : (previous.isBusy ? .idle : previous)
            }
        }
    }

    /// 「下载并安装」
    func downloadAndInstall() {
        guard let info = phase.info, !phase.isBusy else { return }
        guard let asset = info.asset else {
            openInstaller(for: info)
            return
        }
        #if DEBUG
        phase = .failed(info, message: "调试版本不支持软件内更新，请下载安装包手动安装")
        return
        #else
        if let problem = installer.locationProblem() {
            if let backup = orphanedBackupIfInstallMissing {
                // 重试只会因为安装位置上没有 App 而失败：继续指向旧版本，不要换成「没有权限」
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: backup)])
                phase = .failed(info, message: BundleSwapError.rollbackFailed(previousAt: backup).localizedDescription)
            } else {
                phase = .failed(info, message: problem.message)
            }
            return
        }
        phase = .downloading(info, progress: 0)
        let downloader = UpdateDownloader(
            asset: asset,
            repository: configuration.repository,
            destinationDirectory: UpdateInstaller.downloadDirectory
        ) { [weak self] fraction in
            guard let self, case .downloading(let current, _) = self.phase, current == info else { return }
            self.phase = .downloading(info, progress: fraction)
        }
        self.downloader = downloader
        workTask = Task { @MainActor [weak self] in
            do {
                let archive = try await downloader.start()
                guard let self else { return }
                self.downloader = nil
                // 下载刚结束、回到主线程之前按的「取消」也要生效
                if downloader.isCancelled {
                    try? FileManager.default.removeItem(at: archive)
                    throw UpdateDownloadError.cancelled
                }
                self.phase = .preparing(info)
                let prepared = try await self.installer.prepare(archive: archive, info: info)
                self.prepared = prepared
                if self.isSubtitleActive() {
                    self.phase = .awaitingConfirmation(info)
                } else {
                    await self.install(prepared)
                }
            } catch {
                guard let self else { return }
                self.downloader = nil
                if case .cancelled = error as? UpdateDownloadError {
                    self.phase = .available(info)
                } else {
                    UpdateInstaller.log("update to \(info.versionString) failed: \(error)")
                    self.phase = .failed(info, message: error.localizedDescription)
                }
            }
        }
        #endif
    }

    /// 正在字幕时确认安装
    func confirmInstall() {
        guard case .awaitingConfirmation = phase, let prepared else { return }
        workTask = Task { @MainActor [weak self] in
            await self?.install(prepared)
        }
    }

    /// 暂不安装：删除已解压的新版本，回到「发现新版本」提示（之后再更新会重新下载）
    func postponeInstall() {
        guard case .awaitingConfirmation(let info) = phase else { return }
        phase = .available(info)
        if let prepared {
            UpdateInstaller.removeStagingRoot(prepared.stagingRoot, installedApp: installer.installedApp)
            self.prepared = nil
        }
    }

    /// 退出软件时调用：删除还没替换进去的新版本（包括「正在安装」但还在停止字幕 / 重新校验时）。
    /// 替换成功后 install 会清空 prepared：那时暂存目录里是旧版本，由新版本启动时按标记清理
    func discardPreparedUpdate() {
        guard let prepared else { return }
        UpdateInstaller.removeStagingRoot(prepared.stagingRoot, installedApp: installer.installedApp)
        self.prepared = nil
    }

    func cancelDownload() {
        downloader?.cancel()
    }

    func skipCurrentVersion() {
        guard let info = phase.info, !phase.isBusy else { return }
        settingsStore.settings.skippedUpdateVersion = info.versionString
        phase = .idle
    }

    func dismissUpdatedNotice() {
        justUpdatedTo = nil
    }

    func openReleasePage(for info: UpdateInfo? = nil) {
        if let url = info?.releasePage ?? phase.info?.releasePage ?? configuration.releasesPage {
            NSWorkspace.shared.open(url)
        }
    }

    /// 打开 DMG 下载地址手动安装（没有 DMG 时打开发布页面）
    func openInstaller(for info: UpdateInfo? = nil) {
        let info = info ?? phase.info
        if let url = info?.installerURL ?? info?.releasePage ?? configuration.releasesPage {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: 安装

    private func install(_ prepared: UpdateInstaller.Prepared) async {
        let info = prepared.info
        phase = .installing(info)
        // 先停止字幕和演示，释放音频设备
        await prepareForInstall()
        let relaunchScheduled: Bool
        do {
            relaunchScheduled = try await installer.install(prepared, launchAtLoginEnabled: LaunchAtLogin.isEnabled)
        } catch {
            self.prepared = nil
            if case .rollbackFailed(let previousAt) = error as? BundleSwapError {
                orphanedBackup = previousAt
                // 安装位置上已经没有 App：在访达中显示旧版本，方便用户拖回原处
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: previousAt)])
            }
            phase = .failed(info, message: error.localizedDescription)
            return
        }
        // 已替换：暂存目录里现在是旧版本，交给新版本启动时按标记清理，退出时不能删
        self.prepared = nil
        if !relaunchScheduled {
            let alert = NSAlert()
            alert.messageText = "已安装字幕AI \(info.versionString)"
            alert.informativeText = "没能自动重新打开，请在退出后手动打开字幕AI。"
            NSApp.activate()
            alert.runModal()
        }
        terminate()
    }

    private func restoreLaunchAtLoginIfNeeded(wasEnabled: Bool) {
        guard wasEnabled, !LaunchAtLogin.isEnabled else { return }
        do {
            try LaunchAtLogin.setEnabled(true)
        } catch {
            UpdateInstaller.log("re-register login item failed: \(error)")
        }
        loginItemNeedsApproval = LaunchAtLogin.requiresApproval
    }
}
