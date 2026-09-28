import Foundation
import Observation
import ZimuCore

/// 演示字幕：定时滚动一些假字幕，方便调整外观
@MainActor
@Observable
final class DemoSubtitleFeeder {
    private(set) var isRunning = false
    @ObservationIgnored private var task: Task<Void, Never>?

    /// （原文，中文译文，日文译文——设置了「同时翻译成」其他语言时用来预览多语译文的样式）
    private let samples: [(String, String, String)] = [
        ("Welcome to the show, everyone.", "欢迎大家收看本期节目。", "皆さん、番組へようこそ。"),
        ("Today we're going to talk about how subtitles are made.", "今天我们来聊聊字幕是怎么制作的。", "今日は字幕の作り方についてお話しします。"),
        ("It all starts with listening very carefully.", "一切都从仔细聆听开始。", "すべては注意深く聞くことから始まります。"),
        ("Then the words are translated, line by line.", "然后逐行翻译台词。", "そして、セリフを一行ずつ翻訳します。"),
        ("Finally, they appear right here on your screen.", "最后，它们就出现在你的屏幕上。", "最後に、画面に表示されます。"),
        ("You can drag this window anywhere you like.", "你可以把这个窗口拖到任何地方。", "このウィンドウは好きな場所にドラッグできます。"),
    ]

    func toggle(store: SubtitleStore) {
        isRunning ? stop() : start(store: store)
    }

    func start(store: SubtitleStore) {
        stop()
        isRunning = true
        store.reset()
        store.startSession()
        task = Task { @MainActor [samples] in
            var index = 0
            while !Task.isCancelled {
                let (original, translation, extra) = samples[index % samples.count]
                let showsExtra = !store.settingsProvider().additionalTargetLanguages.isEmpty
                let start = Date()
                let words = original.split(separator: " ")
                for count in 1...words.count {
                    store.setLiveText(words.prefix(count).joined(separator: " "))
                    try? await Task.sleep(for: .milliseconds(170))
                    if Task.isCancelled { return }
                }
                store.clearLiveText()
                // 演示用的目标语言标识，只用于区分主译文和其他译文
                let targets = showsExtra ? ["demo", "demo-extra"] : ["demo"]
                let id = store.commit(SubtitleSegment(text: original, start: start, end: Date()), targets: targets)
                var shown = ""
                for character in translation {
                    shown.append(character)
                    store.updateTranslation(id: id, target: "demo", text: shown, isFinal: false)
                    try? await Task.sleep(for: .milliseconds(35))
                    if Task.isCancelled { return }
                }
                store.updateTranslation(id: id, target: "demo", text: translation, isFinal: true)
                if showsExtra {
                    store.updateTranslation(id: id, target: "demo-extra", text: extra, isFinal: true)
                }
                try? await Task.sleep(for: .milliseconds(1400))
                index += 1
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        isRunning = false
    }
}
