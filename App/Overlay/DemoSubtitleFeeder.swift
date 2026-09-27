import Foundation
import Observation
import ZimuCore

/// 演示字幕：定时滚动一些假字幕，方便调整外观
@MainActor
@Observable
final class DemoSubtitleFeeder {
    private(set) var isRunning = false
    @ObservationIgnored private var task: Task<Void, Never>?

    private let samples: [(String, String)] = [
        ("Welcome to the show, everyone.", "欢迎大家收看本期节目。"),
        ("Today we're going to talk about how subtitles are made.", "今天我们来聊聊字幕是怎么制作的。"),
        ("It all starts with listening very carefully.", "一切都从仔细聆听开始。"),
        ("Then the words are translated, line by line.", "然后逐行翻译台词。"),
        ("Finally, they appear right here on your screen.", "最后，它们就出现在你的屏幕上。"),
        ("You can drag this window anywhere you like.", "你可以把这个窗口拖到任何地方。"),
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
                let (original, translation) = samples[index % samples.count]
                let start = Date()
                let words = original.split(separator: " ")
                for count in 1...words.count {
                    store.setLiveText(words.prefix(count).joined(separator: " "))
                    try? await Task.sleep(for: .milliseconds(170))
                    if Task.isCancelled { return }
                }
                store.clearLiveText()
                let id = store.commit(SubtitleSegment(text: original, start: start, end: Date()), needsTranslation: true)
                var shown = ""
                for character in translation {
                    shown.append(character)
                    store.updateTranslation(id: id, text: shown, isFinal: false)
                    try? await Task.sleep(for: .milliseconds(35))
                    if Task.isCancelled { return }
                }
                store.updateTranslation(id: id, text: translation, isFinal: true)
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
