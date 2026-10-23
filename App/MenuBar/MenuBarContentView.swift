import SwiftUI
import ZimuCore

/// 点击菜单栏图标弹出的控制面板
struct MenuBarContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var store = model.settingsStore
        let pipeline = model.pipeline

        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "captions.bubble.fill")
                    .foregroundStyle(Color.accentColor)
                Text(ZimuCore.appName)
                    .font(.headline)
                Spacer()
                StatusBadge(state: pipeline.state)
            }

            Button {
                model.toggleSubtitles()
            } label: {
                HStack {
                    Image(systemName: pipeline.isActive ? "stop.fill" : "play.fill")
                    Text(pipeline.isActive ? "停止字幕" : "开始字幕")
                    Spacer()
                    Text("⌃⌥S").foregroundStyle(.secondary).font(.caption)
                }
                .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .tint(pipeline.isActive ? .red : .accentColor)

            VStack(alignment: .leading, spacing: 4) {
                if pipeline.state == .running {
                    HStack(spacing: 6) {
                        Text(pipeline.runningDescription)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let language = pipeline.activeLanguage {
                            Text("当前：\(Locale.current.localizedString(forIdentifier: language) ?? language)")
                                .font(.caption)
                                .foregroundStyle(Color.accentColor)
                        }
                        Spacer()
                        LevelMeter(level: pipeline.level)
                            .frame(width: 80, height: 6)
                    }
                }
                switch pipeline.state {
                case .preparing(let message):
                    PreparationProgressView(status: PreparationStatus(message, fraction: pipeline.preparationProgress))
                case .failed(let message):
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                default:
                    EmptyView()
                }
                if let warning = pipeline.warning {
                    Text(warning)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
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

            if UpdateBanner.isVisible(for: model.updater) {
                Divider()
                UpdateBanner()
            }

            Divider()

            HStack {
                Button(model.demo.isRunning ? "停止演示" : "演示字幕") { model.toggleDemo() }
                Button("导出 SRT…") { model.exportSubtitles() }
                    .disabled(!model.subtitles.hasHistory)
                Spacer()
                Button("设置…") { model.openSettings() }
                Button("退出") { model.quit() }
                    .keyboardShortcut("q")
                    .help("退出字幕AI")
            }
        }
        .padding(14)
        .frame(width: 320)
    }
}

private struct StatusBadge: View {
    let state: PipelineController.State

    var body: some View {
        let (text, color): (String, Color) = {
            switch state {
            case .idle: return ("未开始", .secondary)
            case .preparing: return ("准备中", .orange)
            case .running: return ("识别中", .green)
            case .stopping: return ("停止中", .orange)
            case .failed: return ("出错", .red)
            }
        }()
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text).font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct LevelMeter: View {
    let level: Float

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.2))
                Capsule()
                    .fill(level > 0.85 ? Color.red : Color.green)
                    .frame(width: proxy.size.width * CGFloat(max(0, min(1, level))))
            }
        }
        .animation(.linear(duration: 0.08), value: level)
    }
}
