import AppKit
import Observation
import ZimuCore

/// 应用的全局状态
@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    let settingsStore: SettingsStore
    let subtitles: SubtitleStore
    let demo: DemoSubtitleFeeder
    let overlay: OverlayController
    let settingsWindow: SettingsWindowController

    private init() {
        let settingsStore = SettingsStore()
        let subtitles = SubtitleStore()
        self.settingsStore = settingsStore
        self.subtitles = subtitles
        self.demo = DemoSubtitleFeeder()
        self.overlay = OverlayController(settingsStore: settingsStore, subtitles: subtitles)
        self.settingsWindow = SettingsWindowController()
        subtitles.settingsProvider = { [unowned settingsStore] in settingsStore.settings }
    }

    var settings: AppSettings {
        get { settingsStore.settings }
        set { settingsStore.settings = newValue }
    }

    func applicationDidFinishLaunching() {
        overlay.setUp()
    }

    func toggleDemo() {
        demo.toggle(store: subtitles)
        if demo.isRunning {
            settingsStore.settings.overlayVisible = true
        }
    }

    func openSettings() {
        settingsWindow.show(model: self)
    }
}
