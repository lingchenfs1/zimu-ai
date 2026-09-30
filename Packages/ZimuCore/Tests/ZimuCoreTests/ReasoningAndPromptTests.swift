import XCTest
@testable import ZimuCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// 按顺序返回不同状态码 / 内容的 HTTP 客户端（测试 400 兜底重试）
final class SequenceHTTPClient: HTTPClient, @unchecked Sendable {
    struct Reply {
        var status: Int
        var lines: [String]
    }

    private let lock = NSLock()
    private var replies: [Reply]
    private var _requests: [URLRequest] = []

    init(_ replies: [Reply]) {
        self.replies = replies
    }

    var requests: [URLRequest] { lock.withLock { _requests } }

    private func next(_ request: URLRequest) -> Reply {
        lock.withLock {
            _requests.append(request)
            return replies.count > 1 ? replies.removeFirst() : replies[0]
        }
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPResponseInfo) {
        let reply = next(request)
        return (Data(reply.lines.joined(separator: "\n").utf8), HTTPResponseInfo(statusCode: reply.status, contentType: "application/json"))
    }

    func streamLines(_ request: URLRequest, handler: (HTTPStreamEvent) async throws -> Void) async throws {
        let reply = next(request)
        try await handler(.response(HTTPResponseInfo(statusCode: reply.status, contentType: "text/event-stream")))
        for line in reply.lines {
            try await handler(.line(line))
        }
    }
}

private func sse(_ pieces: [String]) -> [String] {
    pieces.map { piece in
        let data = try! JSONSerialization.data(withJSONObject: ["choices": [["delta": ["content": piece]]]])
        return "data: " + String(decoding: data, as: UTF8.self)
    } + ["data: [DONE]"]
}

private func body(of request: URLRequest?) throws -> [String: Any] {
    let data = try XCTUnwrap(request?.httpBody)
    return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

final class ReasoningFilterTests: XCTestCase {
    func testPairedAndVariantTags() {
        XCTAssertEqual(TranslationPrompt.cleanOutput("<think>abc</think>\n你好"), "你好")
        XCTAssertEqual(TranslationPrompt.cleanOutput("<THINKING>abc</THINKING>你好"), "你好")
        XCTAssertEqual(TranslationPrompt.cleanOutput("<reasoning>x</reasoning> <thought>y</thought>你好"), "你好")
    }

    func testOnlyClosingTagDropsEverythingBefore() {
        // 聊天模板把 <think> 放进了提示里，模型只输出结束标签
        let raw = "Okay, the user wants a translation of \"Hello\". In Chinese that is 你好.\n</think>\n\n你好。"
        XCTAssertEqual(TranslationPrompt.cleanOutput(raw), "你好。")
    }

    func testUnfinishedReasoningIsHidden() {
        XCTAssertEqual(TranslationPrompt.cleanOutput("<think>still thinking"), "")
        XCTAssertEqual(TranslationPrompt.cleanOutput("  \n<think>"), "")
    }

    func testHarmonyFormat() {
        let raw = "<|channel|>analysis<|message|>We need to translate.<|end|><|start|>assistant<|channel|>final<|message|>你好。<|return|>"
        XCTAssertEqual(TranslationPrompt.cleanOutput(raw), "你好。")
        XCTAssertEqual(TranslationPrompt.cleanOutput("<|channel|>analysis<|message|>We need"), "")
    }

    func testLabelsAndEchoedTagsAreRemoved() {
        XCTAssertEqual(TranslationPrompt.cleanOutput("译文：你好"), "你好")
        XCTAssertEqual(TranslationPrompt.cleanOutput("Translation: Hola"), "Hola")
        XCTAssertEqual(TranslationPrompt.cleanOutput("<subtitle>你好</subtitle>"), "你好")
    }

    func testStreamingHidesReasoningUntilItEnds() {
        var filter = StreamingTranslationFilter()
        var shown: [String] = []
        for piece in ["<th", "ink>", "Let me think", "</th", "ink>", "你", "好"] {
            if let text = filter.append(piece) { shown.append(text) }
        }
        XCTAssertEqual(shown, ["你", "你好"])
        XCTAssertTrue(filter.sawReasoning)
        XCTAssertEqual(filter.finalText, "你好")
    }

    func testStreamingAfterReasoningWasSeenWaitsForClosingTag() {
        // 只有结束标签的模型：第二次起，结束标签出现前都不显示
        var filter = StreamingTranslationFilter(expectsReasoning: true)
        XCTAssertNil(filter.append("The user says hello, "))
        XCTAssertNil(filter.append("so I will answer.\n"))
        XCTAssertNil(filter.append("</think>"))
        XCTAssertEqual(filter.append("你好"), "你好")
    }

    func testStreamingWithoutReasoningShowsImmediately() {
        var filter = StreamingTranslationFilter()
        XCTAssertEqual(filter.append("你"), "你")
        XCTAssertEqual(filter.append("好"), "你好")
        XCTAssertFalse(filter.sawReasoning)
    }

    func testParserIgnoresReasoningFields() {
        XCTAssertEqual(ChatCompletionStreamParser.parse(line: #"data: {"choices":[{"delta":{"reasoning_content":"thinking…","content":null}}]}"#), .ignore)
        XCTAssertEqual(ChatCompletionStreamParser.parse(line: #"data: {"choices":[{"delta":{"reasoning":"thinking…"}}]}"#), .ignore)
        XCTAssertEqual(ChatCompletionStreamParser.parse(line: #"data: {"choices":[{"delta":{"reasoning_content":"","content":"你好"}}]}"#), .delta("你好"))
    }
}

final class ThinkingControlTests: XCTestCase {
    func testParametersByService() {
        XCTAssertEqual(ThinkingControl.describe(ThinkingControl.parameters(baseURL: "http://localhost:11434/v1", model: "qwen3:8b")), #"{"reasoning_effort":"none"}"#)
        XCTAssertEqual(ThinkingControl.describe(ThinkingControl.parameters(baseURL: "http://127.0.0.1:1234/v1", model: "qwen/qwen3-8b")), #"{"reasoning_effort":"none"}"#)
        XCTAssertEqual(ThinkingControl.describe(ThinkingControl.parameters(baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1", model: "qwen-plus")), #"{"enable_thinking":false}"#)
        XCTAssertEqual(ThinkingControl.describe(ThinkingControl.parameters(baseURL: "https://api.siliconflow.cn/v1", model: "Qwen/Qwen3-8B")), #"{"enable_thinking":false}"#)
        XCTAssertEqual(ThinkingControl.describe(ThinkingControl.parameters(baseURL: "https://open.bigmodel.cn/api/paas/v4", model: "glm-4.5")), #"{"thinking":{"type":"disabled"}}"#)
        XCTAssertEqual(ThinkingControl.describe(ThinkingControl.parameters(baseURL: "https://ark.cn-beijing.volces.com/api/v3", model: "doubao-seed")), #"{"thinking":{"type":"disabled"}}"#)
        XCTAssertEqual(ThinkingControl.describe(ThinkingControl.parameters(baseURL: "https://api.openai.com/v1", model: "gpt-5-mini")), #"{"reasoning_effort":"minimal"}"#)
        XCTAssertEqual(ThinkingControl.describe(ThinkingControl.parameters(baseURL: "https://api.openai.com/v1", model: "gpt-5.1")), #"{"reasoning_effort":"none"}"#)
        XCTAssertTrue(ThinkingControl.parameters(baseURL: "https://api.openai.com/v1", model: "gpt-4o-mini").isEmpty)
        XCTAssertTrue(ThinkingControl.parameters(baseURL: "https://api.deepseek.com/v1", model: "deepseek-chat").isEmpty)
    }

    func testQwen3SoftSwitchAndReasoningModelHint() {
        XCTAssertEqual(ThinkingControl.promptSuffix(model: "qwen3:8b"), "/no_think")
        XCTAssertNil(ThinkingControl.promptSuffix(model: "Qwen3-30B-A3B-Instruct-2507"))
        XCTAssertNil(ThinkingControl.promptSuffix(model: "qwen2.5:7b"))
        XCTAssertTrue(ThinkingControl.looksLikeReasoningModel("deepseek-r1:8b"))
        XCTAssertTrue(ThinkingControl.looksLikeReasoningModel("deepseek-reasoner"))
        XCTAssertTrue(ThinkingControl.looksLikeReasoningModel("o3-mini"))
        XCTAssertTrue(ThinkingControl.looksLikeReasoningModel("openai/gpt-oss-20b"))
        XCTAssertFalse(ThinkingControl.looksLikeReasoningModel("gpt-4o-mini"))
        XCTAssertFalse(ThinkingControl.looksLikeReasoningModel("qwen2.5:7b"))
    }

    func makeTranslator(_ client: any HTTPClient, baseURL: String = "http://localhost:11434/v1", extra: String = "", disable: Bool = true) -> OpenAICompatibleTranslator {
        OpenAICompatibleTranslator(
            config: OpenAIServiceConfig(baseURL: baseURL, model: "qwen3:8b"),
            apiKey: "",
            targetLanguage: "zh-Hans",
            extraBodyJSON: extra,
            disableThinking: disable,
            client: client
        )
    }

    func testAutomaticParametersAreSentAndUserParametersWin() throws {
        let translator = makeTranslator(MockHTTPClient(), extra: #"{"reasoning_effort": "low", "top_p": 0.9}"#)
        let request = try translator.makeRequest(text: "Hi", context: [])
        let json = try body(of: request)
        XCTAssertEqual(json["reasoning_effort"] as? String, "low")
        XCTAssertEqual(json["top_p"] as? Double, 0.9)
        let plain = try body(of: makeTranslator(MockHTTPClient()).makeRequest(text: "Hi", context: []))
        XCTAssertEqual(plain["reasoning_effort"] as? String, "none")
        let messages = try XCTUnwrap(plain["messages"] as? [[String: Any]])
        XCTAssertTrue((messages[0]["content"] as? String)?.hasSuffix("/no_think") ?? false)
        let off = try body(of: makeTranslator(MockHTTPClient(), disable: false).makeRequest(text: "Hi", context: []))
        XCTAssertNil(off["reasoning_effort"])
    }

    func testRetriesWithoutAutomaticParametersAfter400() async throws {
        let client = SequenceHTTPClient([
            .init(status: 400, lines: [#"{"error":{"message":"unknown parameter reasoning_effort"}}"#]),
            .init(status: 200, lines: sse(["你好"])),
        ])
        let translator = makeTranslator(client)
        let result = try await translator.translate("Hello", context: []) { _ in }
        XCTAssertEqual(result, "你好")
        XCTAssertEqual(client.requests.count, 2)
        XCTAssertEqual(try body(of: client.requests[0])["reasoning_effort"] as? String, "none")
        XCTAssertNil(try body(of: client.requests[1])["reasoning_effort"])
        XCTAssertTrue(translator.session.autoParametersRejected)
        // 本次运行记住：之后的请求不再附加
        _ = try await translator.translate("Again", context: []) { _ in }
        XCTAssertNil(try body(of: client.requests[2])["reasoning_effort"])
    }

    func test400WithoutAutomaticParametersIsNotRetried() async {
        let client = SequenceHTTPClient([.init(status: 400, lines: [#"{"error":{"message":"bad"}}"#])])
        let translator = makeTranslator(client, baseURL: "https://api.example.com/v1")
        do {
            _ = try await translator.translate("Hello", context: []) { _ in }
            XCTFail("should throw")
        } catch {
            XCTAssertEqual(client.requests.count, 1)
        }
    }

    func testReasoningOnlyStreamIsFilteredAndRemembered() async throws {
        let client = SequenceHTTPClient([.init(status: 200, lines: sse(["The user wants ", "Chinese.", "</think>", "\n你好。"]))])
        let translator = makeTranslator(client, baseURL: "https://api.example.com/v1")
        let collector = await PartialCollector()
        let result = try await translator.translate("Hello.", context: []) { partial in
            collector.values.append(partial)
        }
        XCTAssertEqual(result, "你好。")
        XCTAssertTrue(translator.session.sawReasoning)
        let partials = await collector.values
        XCTAssertFalse(partials.contains { $0.contains("</think>") })
        XCTAssertEqual(partials.last, "你好。")
    }

    func testOnlyReasoningThrowsHelpfulError() async {
        let client = SequenceHTTPClient([.init(status: 200, lines: sse(["<think>", "hmm, the user"]))])
        let translator = makeTranslator(client, baseURL: "https://api.example.com/v1")
        do {
            _ = try await translator.translate("Hello", context: []) { _ in }
            XCTFail("should throw")
        } catch {
            XCTAssertEqual(error as? ServiceError, .onlyReasoning)
        }
    }
}

final class TranslationPromptTests: XCTestCase {
    func testSystemPromptRules() {
        let prompt = TranslationPrompt.systemPrompt(
            targetLanguage: "zh-Hans",
            options: .init(customInstructions: "人名保留英文", scenario: .film, glossary: ["Claude", " Anthropic "])
        )
        XCTAssertTrue(prompt.contains("Simplified Chinese"))
        XCTAssertTrue(prompt.contains("speech recognition"))
        XCTAssertTrue(prompt.contains("do not answer it"))
        XCTAssertTrue(prompt.contains("Never show your reasoning"))
        XCTAssertTrue(prompt.contains("full-width punctuation"))
        XCTAssertTrue(prompt.contains(TranslationScenario.film.promptInstructions!))
        XCTAssertTrue(prompt.contains("Glossary (correct spellings of names and terms; keep them consistent): Claude, Anthropic"))
        XCTAssertTrue(prompt.contains("人名保留英文"))
        XCTAssertFalse(prompt.contains("<source>"))
    }

    func testCorrectionPromptAsksForBothParts() {
        let prompt = TranslationPrompt.systemPrompt(targetLanguage: "ja", options: .init(correctSource: true))
        XCTAssertTrue(prompt.contains("<source>the corrected original line</source>"))
        XCTAssertTrue(prompt.contains("<translation>the Japanese translation</translation>"))
        XCTAssertTrue(prompt.contains("Do not rephrase"))
    }

    func testUserMessageWrapsLineAndContext() {
        let message = TranslationPrompt.userMessage(text: "Hi there", context: ["Hello."], sourceLanguage: "en-US")
        XCTAssertEqual(message, "Previous lines (context only, do not translate):\n- Hello.\n\nThe line is in English.\n\n<subtitle>Hi there</subtitle>")
    }

    func testStyleHints() {
        XCTAssertTrue(Languages.subtitleStyleHint(for: "zh-Hant").contains("Traditional Chinese"))
        XCTAssertTrue(Languages.subtitleStyleHint(for: "ja").contains("Japanese"))
        XCTAssertTrue(Languages.subtitleStyleHint(for: "fr").contains("French"))
    }
}

final class SourceCorrectionTests: XCTestCase {
    func testParseTaggedOutput() {
        let result = SourceCorrection.parse("<think>x</think><source>I love Claude.</source>\n<translation>我爱 Claude。</translation>")
        XCTAssertEqual(result, SourceCorrection.Result(source: "I love Claude.", translation: "我爱 Claude。"))
    }

    func testParseFallsBackToWholeTextAsTranslation() {
        XCTAssertEqual(SourceCorrection.parse("我爱你。"), SourceCorrection.Result(source: nil, translation: "我爱你。"))
        XCTAssertEqual(SourceCorrection.parse("<source>I love you.</source>\n我爱你。").translation, "我爱你。")
    }

    func testPartialParsingOnlyShowsTranslation() {
        XCTAssertEqual(SourceCorrection.parse("<sou", isPartial: true).translation, "")
        XCTAssertEqual(SourceCorrection.parse("<source>I love", isPartial: true).translation, "")
        XCTAssertEqual(SourceCorrection.parse("<source>I love you.</source><translation>我爱", isPartial: true).translation, "我爱")
        XCTAssertEqual(SourceCorrection.parse("<source>A</source><translation>我爱你</trans", isPartial: true).translation, "我爱你")

        var filter = StreamingTranslationFilter(correctsSource: true)
        var shown: [String] = []
        for piece in ["<source>I lov", "e you.</source>", "<translation>我", "爱你", "</translation>"] {
            if let text = filter.append(piece) { shown.append(text) }
        }
        XCTAssertEqual(shown, ["我", "我爱你", "我爱你"])
        XCTAssertEqual(filter.correction.source, "I love you.")
    }

    func testAcceptanceThreshold() {
        XCTAssertEqual(SourceCorrection.accepted(original: "I love cloud code", corrected: "I love Claude Code"), "I love Claude Code")
        // 听错的人名换成正确写法：改动在阈值内，采用
        XCTAssertEqual(SourceCorrection.accepted(original: "他在用克劳德写代码", corrected: "他在用 Claude 写代码"), "他在用 Claude 写代码")
        // 模型改写了整句：改动超过一半，不采用
        XCTAssertNil(SourceCorrection.accepted(original: "我们明天去公园", corrected: "明日一起前往那座大型城市公园散步"))
        XCTAssertEqual(SourceCorrection.accepted(original: "今天天气很好我们去公园吧", corrected: "今天天气很好，我们去公园吧。"), "今天天气很好，我们去公园吧。")
        XCTAssertNil(SourceCorrection.accepted(original: "Hello there", corrected: "Hello there"))
        XCTAssertNil(SourceCorrection.accepted(original: "Hello there", corrected: "  "))
        XCTAssertNil(SourceCorrection.accepted(original: "Hello there", corrected: "Completely different sentence about cats"))
    }

    func testTranslatorCorrectionMode() async throws {
        let client = SequenceHTTPClient([.init(status: 200, lines: sse(["<source>I love Claude.</source>", "<translation>我爱 Claude。</translation>"]))])
        let translator = OpenAICompatibleTranslator(
            config: OpenAIServiceConfig(baseURL: "https://api.example.com/v1", model: "m"),
            apiKey: "",
            targetLanguage: "zh-Hans",
            client: client
        )
        let result = try await translator.translateCorrectingSource("I love cloud.", sourceLanguage: "en", context: []) { _ in }
        XCTAssertEqual(result.source, "I love Claude.")
        XCTAssertEqual(result.translation, "我爱 Claude。")
        let messages = try XCTUnwrap(try body(of: client.requests.first)["messages"] as? [[String: Any]])
        XCTAssertTrue((messages[0]["content"] as? String)?.contains("<source>") ?? false)
    }
}

final class TextCorrectionTests: XCTestCase {
    func testParsingRules() {
        let corrections = TextCorrections(parsing: "克劳德 → Claude\n# 注释\ncloud code -> Claude Code\n\nfoo=bar\n  →  ignored")
        XCTAssertEqual(corrections.rules, [
            .init(from: "克劳德", to: "Claude"),
            .init(from: "cloud code", to: "Claude Code"),
            .init(from: "foo", to: "bar"),
        ])
    }

    func testLatinRulesMatchWholeWordsCaseInsensitive() {
        let corrections = TextCorrections(parsing: "cloud code -> Claude Code\nai -> AI")
        XCTAssertEqual(corrections.apply(to: "I use Cloud Code daily"), "I use Claude Code daily")
        XCTAssertEqual(corrections.apply(to: "the ai said hi, but maintain"), "the AI said hi, but maintain")
    }

    func testCJKRulesMatchSubstrings() {
        let corrections = TextCorrections(parsing: "克劳德 → Claude")
        XCTAssertEqual(corrections.apply(to: "我在用克劳德写代码"), "我在用Claude写代码")
    }

    func testGlossaryParsing() {
        XCTAssertEqual(Glossary.terms(from: "Claude, Anthropic\n张三、李四；Claude"), ["Claude", "Anthropic", "张三", "李四"])
    }
}

final class SegmentationAndSettingsTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 9_000)

    func testDefaultsAreLessAggressive() {
        let segmenter = SubtitleSegmenter()
        XCTAssertEqual(segmenter.idleFlushInterval, 1.8)
        XCTAssertEqual(segmenter.maxDuration, 10)
    }

    func testMaxDurationCutsAtSoftBreak() {
        var segmenter = SubtitleSegmenter(maxDuration: 5, idleFlushInterval: 100)
        _ = segmenter.appendFinal("When we got to the station, the train had already", at: t0)
        segmenter.notePartial(at: t0.addingTimeInterval(4.9))
        let out = segmenter.flushIfNeeded(now: t0.addingTimeInterval(5.1))
        XCTAssertEqual(out.map(\.text), ["When we got to the station,"])
        XCTAssertEqual(segmenter.pendingText, "the train had already")
    }

    func testUpdateOriginal() {
        var timeline = SubtitleTimeline()
        let id = timeline.commit(SubtitleSegment(text: "I love cloud.", start: t0, end: t0), targets: ["zh-Hans"], at: t0)
        timeline.updateOriginal(id: id, text: " I love Claude. ")
        timeline.updateOriginal(id: id, text: "  ")
        XCTAssertEqual(timeline.entry(id: id)?.original, "I love Claude.")
    }

    func testNewSettingsDefaultsAndOldDataCompatibility() {
        let decoded = SettingsCoder.decode(Data(#"{"targetLanguage":"ja"}"#.utf8))
        XCTAssertEqual(decoded.recognitionMode, .accurate)
        XCTAssertTrue(decoded.disableThinking)
        XCTAssertEqual(decoded.translationScenario, .general)
        XCTAssertFalse(decoded.aiSourceCorrection)
        XCTAssertEqual(decoded.glossary, "")
        var settings = AppSettings()
        settings.recognitionMode = .fast
        settings.correctionRules = "a → b"
        settings.translationScenario = .lecture
        XCTAssertEqual(SettingsCoder.decode(SettingsCoder.encode(settings)), settings)
    }
}
