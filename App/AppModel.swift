import AppKit
import Observation
import ZimuCore

/// 应用的全局状态
@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    let settingsStore: SettingsStore
    let apiKeys: APIKeyStore
    let subtitles: SubtitleStore
    let demo: DemoSubtitleFeeder
    let pipeline: PipelineController
    let overlay: OverlayController
    let settingsWindow: SettingsWindowController
    let updater: AppUpdater
    /// 设置窗口当前的标签页
    var settingsTab: SettingsTab = .general

    private(set) var isRecordingTestAudio = false
    private(set) var failedHotKeys: [String] = []

    private init() {
        let settingsStore = SettingsStore()
        let apiKeys = APIKeyStore()
        let subtitles = SubtitleStore()
        self.settingsStore = settingsStore
        self.apiKeys = apiKeys
        self.subtitles = subtitles
        self.demo = DemoSubtitleFeeder()
        self.pipeline = PipelineController(settingsStore: settingsStore, apiKeys: apiKeys, subtitles: subtitles)
        self.overlay = OverlayController(settingsStore: settingsStore, subtitles: subtitles)
        self.settingsWindow = SettingsWindowController()
        self.updater = AppUpdater(settingsStore: settingsStore)
        subtitles.settingsProvider = { [unowned settingsStore] in settingsStore.settings }
    }

    var settings: AppSettings {
        get { settingsStore.settings }
        set { settingsStore.settings = newValue }
    }

    func applicationDidFinishLaunching() {
        overlay.setUp()
        configureUpdater()
        ChangeObserver.observe({ [settingsStore] in settingsStore.settings.hotkeysEnabled }) { [weak self] enabled in
            self?.configureHotKeys(enabled: enabled)
        }
    }

    func applicationWillTerminate() {
        HotKeyCenter.shared.unregisterAll()
        // 等待确认安装时退出：删除暂存的新版本
        updater.discardPreparedUpdate()
    }

    // MARK: 退出（阶段 8.2）

    @ObservationIgnored private var isTerminating = false

    /// 菜单栏「退出」
    func quit() {
        demo.stop()
        // 兜底：无论什么原因 4 秒内没退出就强制退出（在后台线程计时，主线程卡住也有效）
        DispatchQueue.global().asyncAfter(deadline: .now() + 4) {
            exit(0)
        }
        NSApp.terminate(nil)
    }

    /// applicationShouldTerminate：需要时先停止音频捕获再退出
    func prepareForTermination() -> NSApplication.TerminateReply {
        guard pipeline.needsShutdown, !isTerminating else { return .terminateNow }
        isTerminating = true
        Task { @MainActor in
            await self.pipeline.shutdown(timeout: 2)
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    // MARK: 操作

    func toggleSubtitles() {
        if demo.isRunning { demo.stop() }
        pipeline.toggle()
        if pipeline.isActive {
            settingsStore.settings.overlayVisible = true
        }
    }

    func toggleDemo() {
        if pipeline.isActive { pipeline.stop() }
        demo.toggle(store: subtitles)
        if demo.isRunning {
            settingsStore.settings.overlayVisible = true
        }
    }

    func openSettings(tab: SettingsTab? = nil) {
        if let tab { settingsTab = tab }
        settingsWindow.show(model: self)
    }

    // MARK: 在线更新（阶段 11）

    private func configureUpdater() {
        updater.isSubtitleActive = { [unowned self] in pipeline.isActive || demo.isRunning }
        updater.prepareForInstall = { [unowned self] in
            demo.stop()
            if pipeline.needsShutdown {
                await pipeline.shutdown(timeout: 2)
            }
        }
        updater.terminate = { [unowned self] in quit() }
        updater.start()
    }

    func exportSubtitles() {
        SubtitleExporter.exportSRT(records: subtitles.timeline.records(), mode: settingsStore.settings.displayMode)
    }

    /// 调试：录制 10 秒系统音频为 WAV，保存到「下载」文件夹
    func recordTestAudio() {
        guard !isRecordingTestAudio else { return }
        isRecordingTestAudio = true
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let url = folder.appendingPathComponent("字幕AI-系统音频测试-\(formatter.string(from: Date())).wav")

        let bundleID = settingsStore.settings.captureBundleID
        Task { @MainActor in
            let capture = SystemAudioCapture()
            do {
                // 在后台线程启动：第一次使用时会弹出授权对话框（决策 D11）
                try await capture.startInBackground(
                    bundleID: bundleID,
                    outputFormat: nil,
                    onBuffer: { _ in },
                    onLevel: { _ in }
                )
            } catch {
                isRecordingTestAudio = false
                showAlert(title: "无法开始录制", message: error.localizedDescription)
                return
            }
            capture.record(to: url, duration: 10) { [weak self] savedURL in
                Task { @MainActor in
                    await capture.stopInBackground()
                    self?.isRecordingTestAudio = false
                    if let savedURL {
                        NSWorkspace.shared.activateFileViewerSelecting([savedURL])
                    } else {
                        self?.showAlert(title: "录制失败", message: "没有录到系统音频，请检查「录制系统音频」权限。")
                    }
                }
            }
        }
    }

    // MARK: 快捷键

    private func configureHotKeys(enabled: Bool) {
        let center = HotKeyCenter.shared
        center.unregisterAll()
        guard enabled else {
            failedHotKeys = []
            return
        }
        center.register(HotKeyCenter.startStop) { [weak self] in self?.toggleSubtitles() }
        center.register(HotKeyCenter.lockToggle) { [weak self] in self?.overlay.toggleLocked() }
        center.register(HotKeyCenter.visibilityToggle) { [weak self] in self?.overlay.toggleVisible() }
        failedHotKeys = center.failedHotKeys.map(\.display)
    }

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        NSApp.activate()
        alert.runModal()
    }
}
