import Foundation
import Observation
import ZimuCore

/// 用户设置：以 JSON 形式保存在 UserDefaults
@MainActor
@Observable
final class SettingsStore {
    private static let storageKey = "zimu.settings.v1"

    @ObservationIgnored private let defaults: UserDefaults

    var settings: AppSettings {
        didSet {
            if settings != oldValue { save() }
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.settings = SettingsCoder.decode(defaults.data(forKey: Self.storageKey))
    }

    private func save() {
        defaults.set(SettingsCoder.encode(settings), forKey: Self.storageKey)
    }

    /// 恢复外观相关的默认值
    func resetAppearance() {
        let defaults = AppSettings()
        settings.displayMode = defaults.displayMode
        settings.originalFontSize = defaults.originalFontSize
        settings.translationFontSize = defaults.translationFontSize
        settings.originalColorHex = defaults.originalColorHex
        settings.translationColorHex = defaults.translationColorHex
        settings.backgroundOpacity = defaults.backgroundOpacity
        settings.textOpacity = defaults.textOpacity
        settings.cornerRadius = defaults.cornerRadius
        settings.boldText = defaults.boldText
        settings.maxVisibleEntries = defaults.maxVisibleEntries
        settings.clearAfterSeconds = defaults.clearAfterSeconds
        settings.showLiveText = defaults.showLiveText
    }
}
