import SwiftUI
import ZimuCore

/// 悬浮窗中的字幕视图
struct SubtitleOverlayView: View {
    let settingsStore: SettingsStore
    let subtitles: SubtitleStore
    let controller: OverlayController

    var body: some View {
        let settings = settingsStore.settings
        let items = subtitles.displayItems(for: settings)
        let locked = settings.overlayLocked

        ZStack(alignment: .bottom) {
            if !locked {
                UnlockedChrome(controller: controller, cornerRadius: settings.cornerRadius, isEmpty: items.isEmpty)
            }

            if !items.isEmpty {
                VStack(spacing: 6) {
                    ForEach(items) { item in
                        SubtitleItemView(item: item, settings: settings)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: settings.cornerRadius, style: .continuous)
                        .fill(Color.black.opacity(settings.backgroundOpacity))
                )
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
                .animation(.easeOut(duration: 0.15), value: items)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 2)
                .onChanged { _ in if !locked { controller.dragChanged() } }
                .onEnded { _ in if !locked { controller.dragEnded() } }
        )
    }
}

/// 一条字幕：译文在上（大字），同时翻译成的其他语言居中（中号字），原文在下（小字），与常见双语字幕一致
private struct SubtitleItemView: View {
    let item: SubtitleDisplayItem
    let settings: AppSettings

    /// 其他语言译文的字号：介于原文和主译文之间
    private var additionalFontSize: Double {
        max(settings.originalFontSize, (settings.translationFontSize + settings.originalFontSize) / 2)
    }

    var body: some View {
        VStack(spacing: 2) {
            if let translation = item.translation {
                Text(translation)
                    .font(.system(size: settings.translationFontSize, weight: settings.boldText ? .semibold : .regular))
                    .foregroundStyle(Color(hex: settings.translationColorHex, fallback: .yellow).opacity(item.isLive ? 0.85 : 1))
                    .lineLimit(item.isLive ? 2 : 3)
                    .truncationMode(item.isLive ? .head : .tail)
            }
            ForEach(Array(item.additionalTranslations.enumerated()), id: \.offset) { _, translation in
                Text(translation)
                    .font(.system(size: additionalFontSize, weight: settings.boldText ? .medium : .regular))
                    .foregroundStyle(Color(hex: settings.translationColorHex, fallback: .yellow).opacity(item.isLive ? 0.75 : 0.9))
                    .lineLimit(2)
                    .truncationMode(item.isLive ? .head : .tail)
            }
            if let original = item.original {
                Text(original)
                    .font(.system(size: settings.originalFontSize, weight: settings.boldText && !item.dimOriginal ? .medium : .regular))
                    .foregroundStyle(Color(hex: settings.originalColorHex).opacity(item.dimOriginal ? 0.75 : 1))
                    .italic(item.isLive)
                    .lineLimit(item.isLive ? 2 : 3)
                    .truncationMode(item.isLive ? .head : .tail)
            }
        }
        .multilineTextAlignment(.center)
        .shadow(color: .black.opacity(0.85), radius: 2, x: 0, y: 1)
        .opacity(settings.textOpacity)
        .frame(maxWidth: .infinity)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// 解锁状态下的边框、提示和操作按钮
private struct UnlockedChrome: View {
    let controller: OverlayController
    let cornerRadius: Double
    let isEmpty: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color.black.opacity(0.18))
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(Color.white.opacity(0.7), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))

            VStack {
                HStack(alignment: .top) {
                    Label("拖动移动 · 拖边缘或四角调整大小", systemImage: "hand.draw")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.9))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Color.black.opacity(0.45)))
                    Spacer()
                    Button {
                        controller.toggleLocked()
                    } label: {
                        Label("锁定", systemImage: "lock.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(Color.accentColor))
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                    .help("锁定后字幕窗不再响应鼠标，点击会穿透到下面的窗口")
                }
                Spacer()
                if isEmpty {
                    Text("字幕会显示在这里")
                        .font(.system(size: 15))
                        .foregroundStyle(.white.opacity(0.75))
                    Spacer()
                }
            }
            // 避开四角的缩放手柄（OverlayContainerView.cornerSize = 22），否则「锁定」按钮的一部分点不到
            .padding(.horizontal, 26)
            .padding(.vertical, 10)
        }
        // 只是提示图标；真正的缩放由盖在窗口四边四角上的 AppKit 手柄处理（OverlayContainerView）
        .overlay(alignment: .bottomTrailing) {
            ResizeGripIcon()
                .padding(3)
        }
    }
}

private struct ResizeGripIcon: View {
    var body: some View {
        Image(systemName: "arrow.up.left.and.arrow.down.right")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 18, height: 18)
            .background(Circle().fill(Color.black.opacity(0.55)))
            .allowsHitTesting(false)
    }
}
