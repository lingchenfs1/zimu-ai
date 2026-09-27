import AppKit
import SwiftUI
import ZimuCore

/// 通用设置：捕获来源、语言、开机启动、权限
struct GeneralSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var audioApps: [AudioApp] = []
    @State private var sourceLocales: [Locale] = []
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var launchError: String?

    var body: some View {
        @Bindable var store = model.settingsStore

        Form {
            Section("音频来源") {
                Picker("捕获", selection: $store.settings.captureBundleID) {
                    Text("全部系统音频（推荐）").tag(String?.none)
                    ForEach(audioApps) { app in
                        Text(app.isPlaying ? "\(app.name)  🔊" : app.name).tag(String?.some(app.bundleID))
                    }
                    if let selected = store.settings.captureBundleID, !audioApps.contains(where: { $0.bundleID == selected }) {
                        Text("\(selected)（当前未运行）").tag(String?.some(selected))
                    }
                }
                HStack {
                    Text("只捕获某个应用时，请先让它开始播放声音，再点刷新。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("刷新列表") { reloadApps() }
                }
            }

            Section("语言") {
                Picker("原声语言", selection: $store.settings.sourceLanguage) {
                    if store.settings.transcriptionEngine == .openAICompatible {
                        Text("自动检测").tag("auto")
                    }
                    ForEach(sourceLocales, id: \.identifier) { locale in
                        Text(localeName(locale)).tag(locale.identifier(.bcp47))
                    }
                    if !sourceLocales.contains(where: { $0.identifier(.bcp47) == store.settings.sourceLanguage }) && store.settings.sourceLanguage != "auto" {
                        Text(localeName(Locale(identifier: store.settings.sourceLanguage))).tag(store.settings.sourceLanguage)
                    }
                }
                Picker("翻译成", selection: $store.settings.targetLanguage) {
                    ForEach(Languages.targets) { language in
                        Text(language.name).tag(language.code)
                    }
                }
                Text("Apple 本地识别需要手动选择原声语言；云端识别可以自动检测。识别和翻译相关的设置在下次开始字幕时生效。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("权限") {
                Text("第一次开始字幕时，系统会请求「录制系统音频」权限。如果没有声音电平，请在 系统设置 › 隐私与安全性 › 屏幕与系统录音 中允许「字幕AI」。")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("打开隐私设置") { SystemSettings.openAudioCapturePrivacy() }
                    Button("录制 10 秒系统音频测试…") { model.recordTestAudio() }
                        .disabled(model.isRecordingTestAudio)
                    if model.isRecordingTestAudio {
                        ProgressView().controlSize(.small)
                    }
                }
            }

            Section("启动") {
                Toggle("登录时自动启动", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        do {
                            try LaunchAtLogin.setEnabled(enabled)
                            launchError = nil
                        } catch {
                            launchError = error.localizedDescription
                            launchAtLogin = LaunchAtLogin.isEnabled
                        }
                    }
                if let launchError {
                    Text(launchError).font(.caption).foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .task {
            reloadApps()
            sourceLocales = await SpeechLocaleCatalog.supportedLocales()
        }
    }

    private func reloadApps() {
        audioApps = AudioProcessList.applications()
    }

    private func localeName(_ locale: Locale) -> String {
        let id = locale.identifier(.bcp47)
        let name = Locale.current.localizedString(forIdentifier: id) ?? id
        return "\(name)（\(id)）"
    }
}

enum SystemSettings {
    static func openAudioCapturePrivacy() {
        let candidates = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture",
            "x-apple.systempreferences:com.apple.preference.security",
        ]
        for string in candidates {
            if let url = URL(string: string), NSWorkspace.shared.open(url) {
                return
            }
        }
    }
}
