import XCTest
@testable import ZimuCore

final class SubtitleTimelineTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 5_000)

    func testCommitAndTranslate() {
        var timeline = SubtitleTimeline()
        let id = timeline.commit(SubtitleSegment(text: "Hello.", start: t0, end: t0.addingTimeInterval(1)), needsTranslation: true, at: t0)
        XCTAssertEqual(timeline.entry(id: id)?.state, .pending)
        timeline.updateTranslation(id: id, text: "你", isFinal: false, at: t0)
        XCTAssertEqual(timeline.entry(id: id)?.state, .streaming)
        timeline.updateTranslation(id: id, text: "你好。", isFinal: true, at: t0)
        XCTAssertEqual(timeline.entry(id: id)?.translation, "你好。")
        XCTAssertEqual(timeline.entry(id: id)?.state, .done)
        // 迟到的流式片段不能覆盖最终译文
        timeline.updateTranslation(id: id, text: "你", isFinal: false, at: t0)
        XCTAssertEqual(timeline.entry(id: id)?.translation, "你好。")
    }

    func testVisibleEntriesRespectCountAndExpiry() {
        var timeline = SubtitleTimeline()
        for i in 0..<4 {
            let time = t0.addingTimeInterval(Double(i))
            timeline.commit(SubtitleSegment(text: "line \(i)", start: time, end: time), needsTranslation: false, at: time)
        }
        let visible = timeline.visibleEntries(now: t0.addingTimeInterval(3), maxCount: 2, clearAfter: 10)
        XCTAssertEqual(visible.map(\.original), ["line 2", "line 3"])
        let expired = timeline.visibleEntries(now: t0.addingTimeInterval(30), maxCount: 2, clearAfter: 10)
        XCTAssertTrue(expired.isEmpty)
    }

    func testIDsKeepIncreasingAfterReset() {
        var timeline = SubtitleTimeline()
        let first = timeline.commit(SubtitleSegment(text: "a", start: t0, end: t0), needsTranslation: true, at: t0)
        timeline.reset()
        let second = timeline.commit(SubtitleSegment(text: "b", start: t0, end: t0), needsTranslation: true, at: t0)
        XCTAssertNotEqual(first, second)
        timeline.updateTranslation(id: first, text: "late", isFinal: true, at: t0)
        XCTAssertEqual(timeline.entry(id: second)?.translation, "")
    }

    func testRecordsRelativeToSessionStart() {
        var timeline = SubtitleTimeline()
        timeline.startSession(at: t0)
        let id = timeline.commit(SubtitleSegment(text: "Hi", start: t0.addingTimeInterval(2), end: t0.addingTimeInterval(3)), needsTranslation: true, at: t0)
        timeline.updateTranslation(id: id, text: "嗨", isFinal: true, at: t0)
        XCTAssertEqual(timeline.records(), [SubtitleRecord(start: 2, end: 3, original: "Hi", translation: "嗨")])
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

    func testLanguages() {
        XCTAssertEqual(Languages.isoLanguageCode("en-US"), "en")
        XCTAssertEqual(Languages.isoLanguageCode("zh_Hans"), "zh")
        XCTAssertNil(Languages.isoLanguageCode("auto"))
        XCTAssertEqual(Languages.englishName(for: "zh-Hans"), "Simplified Chinese")
        XCTAssertEqual(Languages.displayName(for: "ja-JP"), "日语")
    }
}
