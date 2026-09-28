import XCTest
@testable import ZimuCore

final class TranslationSchedulerTests: XCTestCase {
    func job(_ id: Int, _ language: String? = "en", target: String = "zh-Hans") -> TranslationJob {
        TranslationJob(id: id, text: "line \(id)", language: language, target: target)
    }

    func testConcurrencyLimit() {
        var scheduler = TranslationScheduler(maxConcurrent: 2, maxQueued: 10, maxBatchSize: 1)
        for i in 1...4 { scheduler.enqueue(job(i)) }
        let first = scheduler.nextBatches()
        XCTAssertEqual(first.map { $0.map(\.id) }, [[1], [2]])
        XCTAssertEqual(scheduler.nextBatches().count, 0)
        scheduler.finishBatch(target: "zh-Hans")
        XCTAssertEqual(scheduler.nextBatches().map { $0.map(\.id) }, [[3]])
    }

    func testBatchingGroupsSameLanguage() {
        var scheduler = TranslationScheduler(maxConcurrent: 1, maxQueued: 10, maxBatchSize: 4)
        scheduler.enqueue(job(1, "en"))
        scheduler.enqueue(job(2, "en"))
        scheduler.enqueue(job(3, "ja"))
        scheduler.enqueue(job(4, "en"))
        XCTAssertEqual(scheduler.nextBatches().map { $0.map(\.id) }, [[1, 2]])
        scheduler.finishBatch(target: "zh-Hans")
        XCTAssertEqual(scheduler.nextBatches().map { $0.map(\.id) }, [[3]])
        scheduler.finishBatch(target: "zh-Hans")
        XCTAssertEqual(scheduler.nextBatches().map { $0.map(\.id) }, [[4]])
    }

    func testJobsWithoutLanguageAreNotBatched() {
        var scheduler = TranslationScheduler(maxConcurrent: 1, maxQueued: 10, maxBatchSize: 4)
        scheduler.enqueue(job(1, nil))
        scheduler.enqueue(job(2, nil))
        XCTAssertEqual(scheduler.nextBatches().map { $0.map(\.id) }, [[1]])
    }

    func testDropsOldestWhenBacklogTooLong() {
        var scheduler = TranslationScheduler(maxConcurrent: 1, maxQueued: 2, maxBatchSize: 1)
        XCTAssertEqual(scheduler.enqueue(job(1)), [])
        XCTAssertEqual(scheduler.enqueue(job(2)), [])
        XCTAssertEqual(scheduler.enqueue(job(3)).map(\.id), [1])
        XCTAssertEqual(scheduler.queued.map(\.id), [2, 3])
    }

    func testBatchesPerTargetWithPerTargetConcurrency() {
        // 批量引擎：每种目标语言一次一个请求，不同目标语言可以同时进行
        var scheduler = TranslationScheduler(maxConcurrent: 2, maxConcurrentPerTarget: 1, maxQueued: 20, maxBatchSize: 4)
        for i in 1...3 {
            scheduler.enqueue(job(i, target: "zh-Hans"))
            scheduler.enqueue(job(i, target: "ja"))
        }
        let batches = scheduler.nextBatches()
        XCTAssertEqual(batches.map { $0.map(\.id) }, [[1, 2, 3], [1, 2, 3]])
        XCTAssertEqual(batches.map { $0.first?.target }, ["zh-Hans", "ja"])
        XCTAssertTrue(batches.allSatisfy { batch in batch.allSatisfy { $0.target == batch.first?.target } })

        scheduler.enqueue(job(4, target: "zh-Hans"))
        scheduler.enqueue(job(4, target: "ja"))
        XCTAssertTrue(scheduler.nextBatches().isEmpty)
        scheduler.finishBatch(target: "ja")
        let next = scheduler.nextBatches()
        XCTAssertEqual(next.map { $0.map(\.id) }, [[4]])
        XCTAssertEqual(next.first?.first?.target, "ja")
        XCTAssertEqual(scheduler.queued.map(\.target), ["zh-Hans"])
    }

    func testBatchKeepsOrderWithinTarget() {
        var scheduler = TranslationScheduler(maxConcurrent: 1, maxQueued: 20, maxBatchSize: 4)
        scheduler.enqueue(job(1, "en", target: "zh-Hans"))
        scheduler.enqueue(job(1, "en", target: "ja"))
        scheduler.enqueue(job(2, "fr", target: "zh-Hans"))
        scheduler.enqueue(job(3, "en", target: "zh-Hans"))
        // 同一目标语言遇到不同原文语言就停止，不能跳过 2 把 3 合并进来
        XCTAssertEqual(scheduler.nextBatches().map { $0.map(\.id) }, [[1]])
    }
}

final class LanguageSelectorTests: XCTestCase {
    func testSwitchesToMoreConfidentLanguage() {
        var selector = LanguageSelector(candidates: ["en-US", "ja-JP"])
        XCTAssertEqual(selector.active, "en-US")
        XCTAssertFalse(selector.record(language: "en-US", confidence: 0.3, characters: 30))
        XCTAssertFalse(selector.record(language: "ja-JP", confidence: 0.9, characters: 20))
        XCTAssertTrue(selector.record(language: "ja-JP", confidence: 0.9, characters: 20))
        XCTAssertEqual(selector.active, "ja-JP")
    }

    func testDoesNotSwitchOnSmallDifference() {
        var selector = LanguageSelector(candidates: ["en-US", "zh-CN"])
        selector.record(language: "en-US", confidence: 0.8, characters: 30)
        selector.record(language: "zh-CN", confidence: 0.82, characters: 20)
        selector.record(language: "zh-CN", confidence: 0.83, characters: 20)
        XCTAssertEqual(selector.active, "en-US")
    }

    func testSwitchesWhenActiveLanguageGoesQuiet() {
        var selector = LanguageSelector(candidates: ["en-US", "ja-JP"])
        selector.record(language: "en-US", confidence: 0.9, characters: 30)
        var switched = false
        for _ in 0..<6 where !switched {
            switched = selector.record(language: "ja-JP", confidence: 0.7, characters: 20)
        }
        XCTAssertTrue(switched)
        XCTAssertEqual(selector.active, "ja-JP")
    }

    func testIgnoresUnknownLanguage() {
        var selector = LanguageSelector(candidates: ["en-US"])
        XCTAssertFalse(selector.record(language: "fr-FR", confidence: 1, characters: 50))
        XCTAssertEqual(selector.active, "en-US")
    }
}

final class LanguageAwareSegmenterTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 2_000)

    func testLanguageChangeFlushesPendingText() {
        var segmenter = SubtitleSegmenter()
        XCTAssertEqual(segmenter.appendFinal("hello there", language: "en-US", at: t0), [])
        let result = segmenter.appendFinal("こんにちは。", language: "ja-JP", at: t0)
        XCTAssertEqual(result.map(\.text), ["hello there", "こんにちは。"])
        XCTAssertEqual(result.map(\.language), ["en-US", "ja-JP"])
    }

    func testSegmentKeepsLanguage() {
        var segmenter = SubtitleSegmenter()
        let result = segmenter.appendFinal("Bonjour tout le monde. Encore", language: "fr-FR", at: t0)
        XCTAssertEqual(result.first?.language, "fr-FR")
        XCTAssertEqual(segmenter.pendingLanguage, "fr-FR")
    }
}

final class LiveTranslationTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 3_000)

    func testLiveTranslationMatchesGrowingText() {
        var timeline = SubtitleTimeline()
        timeline.setLiveText("Hello my name", at: t0)
        timeline.setLiveTranslation("你好，我的名字", source: "Hello my name", target: "zh-Hans")
        timeline.setLiveText("Hello, my name is John", at: t0)
        XCTAssertEqual(timeline.liveTranslation(for: "zh-Hans"), "你好，我的名字")
        XCTAssertNil(timeline.liveTranslation(for: "ja"))
        timeline.setLiveText("and then", at: t0)
        XCTAssertNil(timeline.liveTranslation(for: "zh-Hans"))
    }

    func testReuseForCommittedSentence() {
        var timeline = SubtitleTimeline()
        timeline.setLiveTranslation("你好。", source: "Hello", target: "zh-Hans")
        XCTAssertEqual(timeline.reusableLiveTranslation(for: "Hello.", target: "zh-Hans"), "你好。")
        XCTAssertNil(timeline.reusableLiveTranslation(for: "Hello there.", target: "zh-Hans"))
        XCTAssertNil(timeline.reusableLiveTranslation(for: "Hello.", target: "ja"))
    }

    func testStreamingLiveTranslationIsNotReused() {
        var timeline = SubtitleTimeline()
        timeline.setLiveTranslation("你", source: "Hello", target: "zh-Hans", isComplete: false)
        XCTAssertNil(timeline.reusableLiveTranslation(for: "Hello", target: "zh-Hans"))
        timeline.setLiveTranslation("你好", source: "Hello", target: "zh-Hans", isComplete: true)
        XCTAssertEqual(timeline.reusableLiveTranslation(for: "Hello", target: "zh-Hans"), "你好")
    }

    func testLiveTranslationsPerTarget() {
        var timeline = SubtitleTimeline()
        timeline.setLiveText("Hello my", at: t0)
        timeline.setLiveTranslation("你好我的", source: "Hello my", target: "zh-Hans")
        timeline.setLiveTranslation("こんにちは", source: "Hello", target: "ja")
        XCTAssertEqual(timeline.liveTranslation(for: "zh-Hans"), "你好我的")
        XCTAssertEqual(timeline.liveTranslation(for: "ja"), "こんにちは")
        XCTAssertEqual(timeline.liveTranslationSource(for: "ja"), "Hello")
        timeline.clearLiveText()
        XCTAssertTrue(timeline.liveTranslations.isEmpty)
    }

    func testCommitKeepsLanguage() {
        var timeline = SubtitleTimeline()
        let id = timeline.commit(SubtitleSegment(text: "Hola.", start: t0, end: t0, language: "es-ES"), targets: ["zh-Hans"], at: t0)
        XCTAssertEqual(timeline.entry(id: id)?.language, "es-ES")
        XCTAssertEqual(timeline.latestID, id)
    }
}

final class TranslatorOptionsTests: XCTestCase {
    func testExtraBodyMergedIntoRequest() throws {
        let translator = OpenAICompatibleTranslator(
            config: OpenAIServiceConfig(baseURL: "https://api.example.com/v1", model: "qwen3"),
            apiKey: "",
            targetLanguage: "zh-Hans",
            extraBodyJSON: #"{"enable_thinking": false, "messages": "ignored"}"#,
            client: MockHTTPClient()
        )
        let request = try translator.makeRequest(text: "Hi", context: [], sourceLanguage: "en-US")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(json["enable_thinking"] as? Bool, false)
        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        XCTAssertTrue((messages[1]["content"] as? String)?.contains("English") ?? false)
    }

    func testInvalidExtraBodyThrows() {
        XCTAssertThrowsError(try OpenAICompatibleTranslator.parseExtraBody("not json"))
        XCTAssertEqual(try OpenAICompatibleTranslator.parseExtraBody("  ").count, 0)
    }

    func testNormalizedComparison() {
        XCTAssertEqual(TextUtilities.normalizedForComparison("Hello, World!"), "helloworld")
        XCTAssertEqual(TextUtilities.normalizedForComparison("你好，世界。"), "你好世界")
    }

    func testOldSettingsStillDecode() {
        let json = #"{"transcriptionEngine":"openAICompatible","targetLanguage":"ja"}"#
        let decoded = SettingsCoder.decode(Data(json.utf8))
        XCTAssertEqual(decoded.transcriptionEngine, .openAICompatible)
        XCTAssertEqual(decoded.appleCandidateLanguages, AppSettings().appleCandidateLanguages)
        XCTAssertTrue(decoded.liveTranslation)
    }
}
