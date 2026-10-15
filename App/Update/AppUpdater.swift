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
    @ObservationIgnored private var wakeObserver: NSObjectProtocol?

    private static let lastCheckKey = "zimu.update.lastSuccessfulCheck"
    private static let rateLimitKey = "zimu.update.rateLimitedUntil"

    init(settingsStore: SettingsStore, bundle: Bundle = .main) {
        self.settingsStore = settingsStore
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        self.currentVersionString = version
        self.currentVersion = SemanticVersion(version) ?? SemanticVersion(major: 0)
        var repository = bundle.object(forInfoDictionaryKey: "ZimuUpdateRepository") as? String ?? "lingchenfs1/zimu-ai-releases"
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
                    UserDefaults.standard.set(until ?? Date().addingTimeInterval(3600), forKey: Self.rateLimitKey)
                }
                // 自动检查失败不打扰用户
                self.phase = manual ? .failed(nil, message: error.localizedDescription) : (previous.isBusy ? .idle : previous)
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
            phase = .failed(info, message: problem.message)
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

    /// 暂不安装：保留已校验的新版本，稍后在提示里继续
    func postponeInstall() {
        guard case .awaitingConfirmation(let info) = phase else { return }
        phase = .available(info)
        if let prepared {
            UpdateInstaller.removeStagingRoot(prepared.stagingRoot, installedApp: installer.installedApp)
            self.prepared = nil
        }
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
            relaunchScheduled = try installer.install(prepared, launchAtLoginEnabled: LaunchAtLogin.isEnabled)
        } catch {
            self.prepared = nil
            phase = .failed(info, message: error.localizedDescription)
            return
        }
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
