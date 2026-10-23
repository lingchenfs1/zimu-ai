import SwiftUI
import ZimuCore

/// 设置窗口的标签页
enum SettingsTab: Hashable {
    case general, transcription, translation, appearance, shortcuts, update
}

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        TabView(selection: $model.settingsTab) {
            GeneralSettingsView()
                .tabItem { Label("通用", systemImage: "gearshape") }
                .tag(SettingsTab.general)
            TranscriptionSettingsView()
                .tabItem { Label("识别", systemImage: "waveform") }
                .tag(SettingsTab.transcription)
            TranslationSettingsView()
                .tabItem { Label("翻译", systemImage: "character.bubble") }
                .tag(SettingsTab.translation)
            AppearanceSettingsView()
                .tabItem { Label("外观", systemImage: "textformat.size") }
                .tag(SettingsTab.appearance)
            ShortcutsSettingsView()
                .tabItem { Label("快捷键", systemImage: "keyboard") }
                .tag(SettingsTab.shortcuts)
            UpdateSettingsView()
                .tabItem { Label("更新与关于", systemImage: "arrow.down.circle") }
                .tag(SettingsTab.update)
        }
        .frame(minWidth: 580, minHeight: 460)
    }
}

/// 外观设置
struct AppearanceSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var store = model.settingsStore

        Form {
            Section("显示内容") {
                Picker("显示模式", selection: $store.settings.displayMode) {
                    ForEach(SubtitleDisplayMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                Stepper("同时显示 \(store.settings.maxVisibleEntries) 条字幕", value: $store.settings.maxVisibleEntries, in: 1...4)
                Toggle("显示识别中的实时文字", isOn: $store.settings.showLiveText)
                LabeledSlider(title: "无新内容后隐藏", value: $store.settings.clearAfterSeconds, range: 2...30, step: 1, format: { "\(Int($0)) 秒" })
            }

            Section("文字") {
                LabeledSlider(title: "译文字号", value: $store.settings.translationFontSize, range: 12...72, step: 1, format: { "\(Int($0))" })
                LabeledSlider(title: "原文字号", value: $store.settings.originalFontSize, range: 10...60, step: 1, format: { "\(Int($0))" })
                ColorPicker("译文颜色", selection: hexBinding($store.settings.translationColorHex), supportsOpacity: false)
                ColorPicker("原文颜色", selection: hexBinding($store.settings.originalColorHex), supportsOpacity: false)
                Toggle("粗体", isOn: $store.settings.boldText)
                LabeledSlider(title: "文字不透明度", value: $store.settings.textOpacity, range: 0.2...1, step: 0.05, format: { "\(Int($0 * 100))%" })
            }

            Section("背景与窗口") {
                LabeledSlider(title: "背景不透明度", value: $store.settings.backgroundOpacity, range: 0...1, step: 0.05, format: { "\(Int($0 * 100))%" })
                LabeledSlider(title: "圆角", value: $store.settings.cornerRadius, range: 0...30, step: 1, format: { "\(Int($0))" })
                Toggle("显示字幕窗", isOn: $store.settings.overlayVisible)
                Toggle("锁定字幕窗（鼠标点击穿透）", isOn: $store.settings.overlayLocked)
                HStack {
                    Button("重置字幕窗位置") { model.overlay.resetPosition() }
                    Button(model.demo.isRunning ? "停止演示字幕" : "播放演示字幕") { model.toggleDemo() }
                    Spacer()
                    Button("恢复默认外观") { store.resetAppearance() }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func hexBinding(_ hex: Binding<String>) -> Binding<Color> {
        Binding(
            get: { Color(hex: hex.wrappedValue) },
            set: { hex.wrappedValue = $0.hexString() }
        )
    }
}

/// 带数值显示的滑块
struct LabeledSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let format: (Double) -> String

    var body: some View {
        LabeledContent(title) {
            HStack {
                Slider(value: $value, in: range, step: step)
                Text(format(value))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 52, alignment: .trailing)
            }
        }
    }
}
