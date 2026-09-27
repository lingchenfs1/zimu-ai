import XCTest
@testable import ZimuCore

final class SentenceSplitterTests: XCTestCase {
    func boundaryText(_ text: String, max: Int = 100) -> String? {
        guard let index = SentenceSplitter.firstBoundary(in: text, maxLength: max) else { return nil }
        return String(text[..<index])
    }

    func testSplitsOnPeriodFollowedBySpace() {
        XCTAssertEqual(boundaryText("Hello there. How are you"), "Hello there.")
    }

    func testSentenceEndAtEndOfText() {
        XCTAssertEqual(boundaryText("Is it working?"), "Is it working?")
    }

    func testNoBoundaryWithoutTerminator() {
        XCTAssertNil(boundaryText("this sentence is not finished"))
    }

    func testDecimalNumberIsNotBoundary() {
        XCTAssertNil(boundaryText("it costs 3.5 dollars"))
    }

    func testAbbreviationIsNotBoundary() {
        XCTAssertEqual(boundaryText("Mr. Smith arrived. Then"), "Mr. Smith arrived.")
    }

    func testClosingQuoteIncluded() {
        XCTAssertEqual(boundaryText("He said \"stop.\" And left"), "He said \"stop.\"")
    }

    func testChinesePunctuationWithoutSpace() {
        XCTAssertEqual(boundaryText("你好。今天天气不错"), "你好。")
    }

    func testLongTextSplitsAtComma() {
        let text = "one two three four five, six seven eight nine ten eleven twelve"
        let result = boundaryText(text, max: 30)
        XCTAssertEqual(result, "one two three four five,")
    }

    func testLongTextHardCut() {
        let text = String(repeating: "字", count: 40)
        let result = boundaryText(text, max: 32)
        XCTAssertEqual(result?.count, 32)
    }
}

final class SubtitleSegmenterTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_000)

    func testJoinsChunksUntilSentenceEnds() {
        var segmenter = SubtitleSegmenter()
        XCTAssertEqual(segmenter.appendFinal("Hello", at: t0), [])
        let result = segmenter.appendFinal("world. Next", at: t0.addingTimeInterval(1))
        XCTAssertEqual(result.map(\.text), ["Hello world."])
        XCTAssertEqual(result.first?.start, t0)
        XCTAssertEqual(segmenter.pendingText, "Next")
    }

    func testChineseChunksJoinWithoutSpace() {
        var segmenter = SubtitleSegmenter()
        _ = segmenter.appendFinal("我们今天", at: t0)
        let result = segmenter.appendFinal("开始吧。", at: t0)
        XCTAssertEqual(result.map(\.text), ["我们今天开始吧。"])
    }

    func testMultipleSentencesInOneChunk() {
        var segmenter = SubtitleSegmenter()
        let result = segmenter.appendFinal("First one. Second one! Third", at: t0)
        XCTAssertEqual(result.map(\.text), ["First one.", "Second one!"])
        XCTAssertEqual(segmenter.pendingText, "Third")
    }

    func testIdleFlush() {
        var segmenter = SubtitleSegmenter(idleFlushInterval: 1.0)
        _ = segmenter.appendFinal("no punctuation here", at: t0)
        XCTAssertEqual(segmenter.flushIfNeeded(now: t0.addingTimeInterval(0.5)), [])
        let flushed = segmenter.flushIfNeeded(now: t0.addingTimeInterval(1.1))
        XCTAssertEqual(flushed.map(\.text), ["no punctuation here"])
        XCTAssertEqual(segmenter.pendingText, "")
    }

    func testPartialActivityDelaysIdleFlush() {
        var segmenter = SubtitleSegmenter(maxDuration: 100, idleFlushInterval: 1.0)
        _ = segmenter.appendFinal("still talking", at: t0)
        segmenter.notePartial(at: t0.addingTimeInterval(0.9))
        XCTAssertEqual(segmenter.flushIfNeeded(now: t0.addingTimeInterval(1.5)), [])
        XCTAssertEqual(segmenter.flushIfNeeded(now: t0.addingTimeInterval(2.0)).map(\.text), ["still talking"])
    }

    func testMaxDurationFlush() {
        var segmenter = SubtitleSegmenter(maxDuration: 5, idleFlushInterval: 100)
        _ = segmenter.appendFinal("a very long run on", at: t0)
        segmenter.notePartial(at: t0.addingTimeInterval(4.9))
        XCTAssertEqual(segmenter.flushIfNeeded(now: t0.addingTimeInterval(5.1)).map(\.text), ["a very long run on"])
    }

    func testPunctuationOnlyIsDropped() {
        var segmenter = SubtitleSegmenter()
        XCTAssertEqual(segmenter.appendFinal("...", at: t0), [])
        XCTAssertEqual(segmenter.flush(now: t0), [])
    }
}

final class TextUtilitiesTests: XCTestCase {
    func testJoin() {
        XCTAssertEqual(TextUtilities.join("Hello", "world"), "Hello world")
        XCTAssertEqual(TextUtilities.join("你好", "世界"), "你好世界")
        XCTAssertEqual(TextUtilities.join("", " x "), "x")
        XCTAssertEqual(TextUtilities.join("안녕", "하세요"), "안녕 하세요")
    }

    func testMostlyCJK() {
        XCTAssertTrue(TextUtilities.isMostlyNoSpaceScript("今天天气不错"))
        XCTAssertFalse(TextUtilities.isMostlyNoSpaceScript("hello world"))
    }
}
