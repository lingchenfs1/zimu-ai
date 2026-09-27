import SwiftUI
import ZimuCore

/// 点击菜单栏图标弹出的控制面板
struct MenuBarContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var store = model.settingsStore

        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "captions.bubble.fill")
                    .foregroundStyle(Color.accentColor)
                Text(ZimuCore.appName)
                    .font(.headline)
                Spacer()
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Toggle("显示字幕窗", isOn: $store.settings.overlayVisible)
                Toggle("锁定字幕窗（鼠标穿透）", isOn: $store.settings.overlayLocked)
                Picker("显示", selection: $store.settings.displayMode) {
                    ForEach(SubtitleDisplayMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.menu)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("背景不透明度 \(Int(store.settings.backgroundOpacity * 100))%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Slider(value: $store.settings.backgroundOpacity, in: 0...1)
                Text("译文字号 \(Int(store.settings.translationFontSize))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Slider(value: $store.settings.translationFontSize, in: 12...72, step: 1)
            }

            Divider()

            HStack {
                Button(model.demo.isRunning ? "停止演示" : "演示字幕") { model.toggleDemo() }
                Spacer()
                Button("设置…") { model.openSettings() }
                Button("退出") { NSApp.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 300)
    }
}
