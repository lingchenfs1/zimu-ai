import XCTest
@testable import ZimuCore

final class SubtitleTimelineTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 5_000)

    func testCommitAndTranslate() {
        var timeline = SubtitleTimeline()
        let id = timeline.commit(SubtitleSegment(text: "Hello.", start: t0, end: t0.addingTimeInterval(1)), targets: ["zh-Hans"], at: t0)
        XCTAssertEqual(timeline.entry(id: id)?.state, .pending)
        timeline.updateTranslation(id: id, target: "zh-Hans", text: "你", isFinal: false, at: t0)
        XCTAssertEqual(timeline.entry(id: id)?.state, .streaming)
        timeline.updateTranslation(id: id, target: "zh-Hans", text: "你好。", isFinal: true, at: t0)
        XCTAssertEqual(timeline.entry(id: id)?.translation, "你好。")
        XCTAssertEqual(timeline.entry(id: id)?.state, .done)
        // 迟到的流式片段不能覆盖最终译文
        timeline.updateTranslation(id: id, target: "zh-Hans", text: "你", isFinal: false, at: t0)
        XCTAssertEqual(timeline.entry(id: id)?.translation, "你好。")
    }

    func testVisibleEntriesRespectCountAndExpiry() {
        var timeline = SubtitleTimeline()
        for i in 0..<4 {
            let time = t0.addingTimeInterval(Double(i))
            timeline.commit(SubtitleSegment(text: "line \(i)", start: time, end: time), targets: [], at: time)
        }
        let visible = timeline.visibleEntries(now: t0.addingTimeInterval(3), maxCount: 2, clearAfter: 10)
        XCTAssertEqual(visible.map(\.original), ["line 2", "line 3"])
        let expired = timeline.visibleEntries(now: t0.addingTimeInterval(30), maxCount: 2, clearAfter: 10)
        XCTAssertTrue(expired.isEmpty)
    }

    func testIDsKeepIncreasingAfterReset() {
        var timeline = SubtitleTimeline()
        let first = timeline.commit(SubtitleSegment(text: "a", start: t0, end: t0), targets: ["zh-Hans"], at: t0)
        timeline.reset()
        let second = timeline.commit(SubtitleSegment(text: "b", start: t0, end: t0), targets: ["zh-Hans"], at: t0)
        XCTAssertNotEqual(first, second)
        timeline.updateTranslation(id: first, target: "zh-Hans", text: "late", isFinal: true, at: t0)
        XCTAssertEqual(timeline.entry(id: second)?.translation, "")
    }

    func testRecordsRelativeToSessionStart() {
        var timeline = SubtitleTimeline()
        timeline.startSession(at: t0)
        let id = timeline.commit(SubtitleSegment(text: "Hi", start: t0.addingTimeInterval(2), end: t0.addingTimeInterval(3)), targets: ["zh-Hans"], at: t0)
        timeline.updateTranslation(id: id, target: "zh-Hans", text: "嗨", isFinal: true, at: t0)
        XCTAssertEqual(timeline.records(), [SubtitleRecord(start: 2, end: 3, original: "Hi", translation: "嗨")])
    }

    func testMultipleTargetsTranslateIndependently() {
        var timeline = SubtitleTimeline()
        let id = timeline.commit(SubtitleSegment(text: "Hello.", start: t0, end: t0), targets: ["zh-Hans", "ja", "fr"], at: t0)
        XCTAssertEqual(timeline.entry(id: id)?.translations.map(\.target), ["zh-Hans", "ja", "fr"])
        timeline.updateTranslation(id: id, target: "ja", text: "こんにちは。", isFinal: true, at: t0)
        // 主目标语言还没翻译完：主译文为空、状态为等待
        XCTAssertEqual(timeline.entry(id: id)?.translation, "")
        XCTAssertEqual(timeline.entry(id: id)?.state, .pending)
        XCTAssertEqual(timeline.entry(id: id)?.translation(for: "ja")?.state, .done)
        timeline.updateTranslation(id: id, target: "zh-Hans", text: "你好。", isFinal: true, at: t0)
        timeline.markTranslationFailed(id: id, target: "fr", message: "boom", at: t0)
        XCTAssertEqual(timeline.entry(id: id)?.translation, "你好。")
        XCTAssertEqual(timeline.entry(id: id)?.translation(for: "fr")?.state, .failed("boom"))
        // 没有请求过的目标语言不会被写入
        timeline.updateTranslation(id: id, target: "de", text: "Hallo.", isFinal: true, at: t0)
        XCTAssertNil(timeline.entry(id: id)?.translation(for: "de"))
        XCTAssertEqual(timeline.records().first?.translations, ["你好。", "こんにちは。"])
    }

    func testNoTargetsMeansNoTranslation() {
        var timeline = SubtitleTimeline()
        let id = timeline.commit(SubtitleSegment(text: "Hello.", start: t0, end: t0), targets: [], at: t0)
        XCTAssertEqual(timeline.entry(id: id)?.state, SubtitleEntry.TranslationState.none)
        XCTAssertEqual(timeline.records().first?.translations, [])
    }
}

final class SRTFormatterTests: XCTestCase {
    func testTimestamp() {
        XCTAssertEqual(SRTFormatter.timestamp(0), "00:00:00,000")
        XCTAssertEqual(SRTFormatter.timestamp(3661.5), "01:01:01,500")
    }

    func testBilingualFormat() {
        let records = [
            SubtitleRecord(start: 1, end: 2.5, original: "Hello", translation: "你好"),
            SubtitleRecord(start: 3, end: 3, original: "Bye", translation: nil),
        ]
        let expected = """
        1
        00:00:01,000 --> 00:00:02,500
        你好
        Hello

        2
        00:00:03,000 --> 00:00:04,000
        Bye

        """
        XCTAssertEqual(SRTFormatter.format(records, mode: .bilingual), expected)
    }

    func testMultipleTranslations() {
        let records = [SubtitleRecord(start: 0, end: 2, original: "Hello", translations: ["你好", "こんにちは"])]
        XCTAssertEqual(SRTFormatter.format(records, mode: .bilingual), "1\n00:00:00,000 --> 00:00:02,000\n你好\nこんにちは\nHello\n")
        XCTAssertEqual(SRTFormatter.format(records, mode: .translationOnly), "1\n00:00:00,000 --> 00:00:02,000\n你好\nこんにちは\n")
        XCTAssertEqual(SRTFormatter.format(records, mode: .originalOnly), "1\n00:00:00,000 --> 00:00:02,000\nHello\n")
    }
}

final class SettingsCoderTests: XCTestCase {
    func testRoundTrip() {
        var settings = AppSettings()
        settings.targetLanguage = "ja"
        settings.backgroundOpacity = 0.8
        settings.overlayFrame = OverlayFrame(x: 1, y: 2, width: 3, height: 4)
        let decoded = SettingsCoder.decode(SettingsCoder.encode(settings))
        XCTAssertEqual(decoded, settings)
    }

    func testMissingKeysUseDefaults() {
        let json = #"{"targetLanguage":"fr","llmTranslation":{"model":"deepseek-chat"}}"#
        let decoded = SettingsCoder.decode(Data(json.utf8))
        XCTAssertEqual(decoded.targetLanguage, "fr")
        XCTAssertEqual(decoded.llmTranslation.model, "deepseek-chat")
        XCTAssertEqual(decoded.llmTranslation.baseURL, AppSettings().llmTranslation.baseURL)
        XCTAssertEqual(decoded.backgroundOpacity, AppSettings().backgroundOpacity)
    }

    func testGarbageFallsBackToDefaults() {
        XCTAssertEqual(SettingsCoder.decode(Data("nope".utf8)), AppSettings())
        XCTAssertEqual(SettingsCoder.decode(nil), AppSettings())
    }

    func testTranslationTargets() {
        var settings = AppSettings()
        XCTAssertEqual(settings.translationTargets, ["zh-Hans"])
        settings.additionalTargetLanguages = ["ja", "zh-Hans", "", "fr", "de"]
        // 去掉与主目标语言重复的和空的，最多 1 + 2 种
        XCTAssertEqual(settings.translationTargets, ["zh-Hans", "ja", "fr"])
        let decoded = SettingsCoder.decode(SettingsCoder.encode(settings))
        XCTAssertEqual(decoded.additionalTargetLanguages, settings.additionalTargetLanguages)
        let old = SettingsCoder.decode(Data(#"{"targetLanguage":"ja"}"#.utf8))
        XCTAssertEqual(old.translationTargets, ["ja"])
    }

    func testLanguages() {
        XCTAssertEqual(Languages.isoLanguageCode("en-US"), "en")
        XCTAssertEqual(Languages.isoLanguageCode("zh_Hans"), "zh")
        XCTAssertNil(Languages.isoLanguageCode("auto"))
        XCTAssertEqual(Languages.englishName(for: "zh-Hans"), "Simplified Chinese")
        XCTAssertEqual(Languages.displayName(for: "ja-JP"), "日语")
    }
}
