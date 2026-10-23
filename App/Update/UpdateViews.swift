import SwiftUI
import ZimuCore

/// 菜单栏面板里的更新提示
struct UpdateBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let updater = model.updater
        Group {
            switch updater.phase {
            case .available(let info):
                HStack(spacing: 8) {
                    Image(systemName: "arrow.down.circle.fill")
                        .foregroundStyle(Color.accentColor)
                    Text("发现新版本 \(info.versionString)")
                        .font(.callout.weight(.medium))
                    Spacer()
                    Button("详情…") { model.openSettings(tab: .update) }
                        .controlSize(.small)
                    Button(info.asset == nil ? "下载" : "更新") { updater.downloadAndInstall() }
                        .controlSize(.small)
                        .buttonStyle(.borderedProminent)
                }
            case .downloading(_, let progress):
                HStack(spacing: 8) {
                    ProgressView(value: progress) {
                        Text("正在下载新版本… \(Int((progress * 100).rounded()))%").font(.caption)
                    }
                    Button("取消") { updater.cancelDownload() }
                        .controlSize(.small)
                }
            case .preparing:
                ProgressView { Text("正在校验新版本…").font(.caption) }
                    .progressViewStyle(.linear)
            case .awaitingConfirmation(let info):
                VStack(alignment: .leading, spacing: 6) {
                    Text("新版本 \(info.versionString) 已准备好。安装会停止字幕并重启软件。")
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Spacer()
                        Button("稍后") { updater.postponeInstall() }
                            .controlSize(.small)
                        Button("立即安装") { updater.confirmInstall() }
                            .controlSize(.small)
                            .buttonStyle(.borderedProminent)
                    }
                }
            case .installing:
                ProgressView { Text("正在安装，软件即将重启…").font(.caption) }
                    .progressViewStyle(.linear)
            case .failed(let info?, let message):
                VStack(alignment: .leading, spacing: 6) {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Spacer()
                        Button("手动下载") { updater.openInstaller(for: info) }
                            .controlSize(.small)
                        if info.asset != nil {
                            Button("重试") { updater.downloadAndInstall() }
                                .controlSize(.small)
                        }
                    }
                }
            default:
                if let version = updater.justUpdatedTo {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text("已更新到 \(version)")
                            .font(.callout)
                        Spacer()
                        Button("更新说明") {
                            updater.dismissUpdatedNotice()
                            updater.openReleasePage()
                        }
                        .controlSize(.small)
                        Button {
                            updater.dismissUpdatedNotice()
                        } label: {
                            Image(systemName: "xmark")
                        }
                        .buttonStyle(.plain)
                        .help("关闭提示")
                    }
                }
            }
        }
    }

    /// 是否有内容需要显示（没有时菜单栏面板不留空白）
    static func isVisible(for updater: AppUpdater) -> Bool {
        switch updater.phase {
        case .available, .downloading, .preparing, .awaitingConfirmation, .installing:
            return true
        case .failed(let info, _):
            // 没有新版本信息时 body 走 default，显示「已更新到 vX」
            return info != nil || updater.justUpdatedTo != nil
        default:
            return updater.justUpdatedTo != nil
        }
    }
}

/// 设置 › 更新与关于
struct UpdateSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var store = model.settingsStore
        let updater = model.updater

        Form {
            Section("软件更新") {
                LabeledContent("当前版本", value: AppInfo.versionString)
                Toggle("自动检查更新", isOn: $store.settings.autoCheckUpdates)
                Text("启动时和每天检查一次新版本，发现后在菜单栏面板提示。只访问 GitHub 上的公开发布页面，不会上传任何数据。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("检查更新") { updater.checkNow() }
                        .disabled(updater.phase.isBusy)
                    statusText(updater.phase)
                }
                if let version = updater.justUpdatedTo {
                    Text("✅ 已更新到 \(version)")
                        .font(.callout)
                }
                if updater.loginItemNeedsApproval {
                    Text("更新后「登录时自动启动」需要重新允许：系统设置 › 通用 › 登录项。")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            if let info = updater.phase.info {
                Section("新版本 \(info.versionString)") {
                    if let date = info.publishedAt {
                        LabeledContent("发布时间", value: date.formatted(date: .abbreviated, time: .shortened))
                    }
                    if !info.notes.isEmpty {
                        ScrollView {
                            Text(Self.notes(info.notes))
                                .font(.callout)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 200)
                    }
                    if let reason = info.manualOnlyReason {
                        Text(reason)
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    actions(updater, info: info)
                }
            }

            Section("关于") {
                if let page = updater.releasesPage {
                    Link("发布页面（所有版本）", destination: page)
                }
                Text(updater.verifiesSameSigner
                     ? "安装更新前会校验文件的 SHA-256，并确认新版本与当前版本使用同一签名。"
                     : "安装更新前会校验文件的 SHA-256 和代码签名的完整性。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func statusText(_ phase: AppUpdater.Phase) -> some View {
        switch phase {
        case .checking:
            ProgressView().controlSize(.small)
            Text("正在检查…").font(.caption).foregroundStyle(.secondary)
        case .upToDate(let date):
            Text("已是最新版本（\(date.formatted(date: .omitted, time: .shortened)) 检查）")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .failed(nil, let message):
            Text(message)
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private func actions(_ updater: AppUpdater, info: UpdateInfo) -> some View {
        switch updater.phase {
        case .downloading(_, let progress):
            HStack {
                ProgressView(value: progress) {
                    Text("正在下载… \(Int((progress * 100).rounded()))%").font(.caption)
                }
                Button("取消") { updater.cancelDownload() }
            }
        case .preparing:
            ProgressView { Text("正在校验新版本…").font(.caption) }
                .progressViewStyle(.linear)
        case .awaitingConfirmation:
            HStack {
                Text("安装会停止字幕并重启软件。").font(.caption)
                Spacer()
                Button("稍后") { updater.postponeInstall() }
                Button("立即安装") { updater.confirmInstall() }
                    .buttonStyle(.borderedProminent)
            }
        case .installing:
            ProgressView { Text("正在安装，软件即将重启…").font(.caption) }
                .progressViewStyle(.linear)
        default:
            if case .failed(_, let message) = updater.phase {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if info.asset != nil {
                    Button("下载并安装") { updater.downloadAndInstall() }
                        .buttonStyle(.borderedProminent)
                }
                Button("下载安装包") { updater.openInstaller(for: info) }
                Button("查看发布页面") { updater.openReleasePage(for: info) }
                Spacer()
                Button("跳过这个版本") { updater.skipCurrentVersion() }
            }
        }
    }

    /// 更新说明：只渲染行内 Markdown（粗体、链接、代码），保留换行
    private static func notes(_ markdown: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: markdown, options: options)) ?? AttributedString(markdown)
    }
}
