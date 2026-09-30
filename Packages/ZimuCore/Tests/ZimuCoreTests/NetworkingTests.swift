import XCTest
@testable import ZimuCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// 假的 HTTP 客户端：返回预设的状态码和响应行，并记录请求
final class MockHTTPClient: HTTPClient, @unchecked Sendable {
    let status: Int
    let lines: [String]
    let body: Data
    private let lock = NSLock()
    private var _requests: [URLRequest] = []

    init(status: Int = 200, lines: [String] = [], body: Data = Data()) {
        self.status = status
        self.lines = lines
        self.body = body
    }

    var requests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return _requests
    }

    private func record(_ request: URLRequest) {
        lock.lock()
        _requests.append(request)
        lock.unlock()
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPResponseInfo) {
        record(request)
        return (body, HTTPResponseInfo(statusCode: status, contentType: "application/json"))
    }

    func streamLines(_ request: URLRequest, handler: (HTTPStreamEvent) async throws -> Void) async throws {
        record(request)
        try await handler(.response(HTTPResponseInfo(statusCode: status, contentType: "text/event-stream")))
        for line in lines {
            try await handler(.line(line))
        }
    }
}

@MainActor
final class PartialCollector {
    var values: [String] = []
}

final class OpenAICompatibleTranslatorTests: XCTestCase {
    func makeTranslator(_ client: MockHTTPClient) -> OpenAICompatibleTranslator {
        OpenAICompatibleTranslator(
            config: OpenAIServiceConfig(baseURL: "https://api.example.com/v1/", model: "test-model"),
            apiKey: "sk-test",
            targetLanguage: "zh-Hans",
            client: client
        )
    }

    func testStreamingTranslation() async throws {
        let client = MockHTTPClient(lines: [
            #"data: {"choices":[{"delta":{"role":"assistant"}}]}"#,
            "",
            #"data: {"choices":[{"delta":{"content":"你"}}]}"#,
            #"data: {"choices":[{"delta":{"content":"好。"}}]}"#,
            "data: [DONE]",
        ])
        let collector = await PartialCollector()
        let result = try await makeTranslator(client).translate("Hello.", context: ["Previous."]) { partial in
            collector.values.append(partial)
        }
        XCTAssertEqual(result, "你好。")
        let partials = await collector.values
        XCTAssertEqual(partials, ["你", "你好。"])

        let request = try XCTUnwrap(client.requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://api.example.com/v1/chat/completions")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test")
        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["model"] as? String, "test-model")
        XCTAssertEqual(json["stream"] as? Bool, true)
        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 2)
        XCTAssertTrue((messages[1]["content"] as? String)?.contains("Previous.") ?? false)
    }

    func testNonStreamingFallback() async throws {
        let client = MockHTTPClient(lines: [
            #"{"choices":[{"message":{"role":"assistant","content":"  \"Bonjour\"  "}}]}"#,
        ])
        let result = try await makeTranslator(client).translate("Hello", context: []) { _ in }
        XCTAssertEqual(result, "Bonjour")
    }

    func testHTTPErrorMessage() async {
        let client = MockHTTPClient(status: 401, lines: [#"{"error":{"message":"Invalid API key"}}"#])
        do {
            _ = try await makeTranslator(client).translate("Hello", context: []) { _ in }
            XCTFail("should throw")
        } catch let error as ServiceError {
            XCTAssertEqual(error, .http(status: 401, message: "Invalid API key"))
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testThinkBlockRemoved() async throws {
        let client = MockHTTPClient(lines: [
            #"data: {"choices":[{"delta":{"content":"<think>hmm"}}]}"#,
            #"data: {"choices":[{"delta":{"content":"</think>"}}]}"#,
            #"data: {"choices":[{"delta":{"content":"你好"}}]}"#,
            "data: [DONE]",
        ])
        let collector = await PartialCollector()
        let result = try await makeTranslator(client).translate("Hi", context: []) { partial in
            collector.values.append(partial)
        }
        XCTAssertEqual(result, "你好")
        let partials = await collector.values
        XCTAssertEqual(partials, ["你好"])
    }

    func testEmptyAPIKeyOmitsAuthorization() throws {
        let translator = OpenAICompatibleTranslator(
            config: OpenAIServiceConfig(baseURL: "http://localhost:11434/v1", model: "qwen3"),
            apiKey: "  ",
            targetLanguage: "en",
            client: MockHTTPClient()
        )
        let request = try translator.makeRequest(text: "你好", context: [])
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(request.url?.absoluteString, "http://localhost:11434/v1/chat/completions")
    }

    func testInvalidBaseURL() {
        XCTAssertThrowsError(try OpenAIEndpoint.url(base: "not a url", path: OpenAIEndpoint.chatCompletionsPath))
        XCTAssertEqual(
            try OpenAIEndpoint.url(base: "https://x.com/v1/chat/completions", path: OpenAIEndpoint.chatCompletionsPath).absoluteString,
            "https://x.com/v1/chat/completions"
        )
    }
}

final class PromptTests: XCTestCase {
    func testCleanOutput() {
        XCTAssertEqual(TranslationPrompt.cleanOutput("  “你好” "), "你好")
        XCTAssertEqual(TranslationPrompt.cleanOutput("<think>abc</think>\n答案"), "答案")
        XCTAssertEqual(TranslationPrompt.cleanOutput("<think>still thinking"), "")
        XCTAssertEqual(TranslationPrompt.cleanOutput("\"a\" and \"b\""), "\"a\" and \"b\"")
    }

    func testSystemPromptMentionsLanguage() {
        let prompt = TranslationPrompt.systemPrompt(targetLanguage: "ja", customInstructions: "Use polite form.")
        XCTAssertTrue(prompt.contains("Japanese"))
        XCTAssertTrue(prompt.contains("Use polite form."))
    }

    func testUserMessageWithoutContext() {
        XCTAssertEqual(TranslationPrompt.userMessage(text: "Hi", context: ["  "]), "<subtitle>Hi</subtitle>")
    }

    func testStreamParser() {
        XCTAssertEqual(ChatCompletionStreamParser.parse(line: "data: [DONE]"), .done)
        XCTAssertEqual(ChatCompletionStreamParser.parse(line: ": keep-alive"), .ignore)
        XCTAssertEqual(ChatCompletionStreamParser.parse(line: #"data:{"choices":[{"delta":{"content":"x"}}]}"#), .delta("x"))
    }
}

final class TranscriptionClientTests: XCTestCase {
    func testTranscribeBuildsMultipartRequest() async throws {
        let client = MockHTTPClient(body: Data(#"{"text":" Hello world. "}"#.utf8))
        let transcriber = OpenAITranscriptionClient(
            config: OpenAIServiceConfig(baseURL: "https://api.example.com/v1", model: "whisper-1"),
            apiKey: "k",
            language: "en",
            client: client
        )
        let text = try await transcriber.transcribe(wav: WAVEncoder.encode(samples: [0, 0.5, -0.5], sampleRate: 16_000), prompt: "earlier")
        XCTAssertEqual(text, "Hello world.")
        let request = try XCTUnwrap(client.requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://api.example.com/v1/audio/transcriptions")
        XCTAssertTrue(request.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart/form-data; boundary=") ?? false)
        let body = String(decoding: try XCTUnwrap(request.httpBody), as: UTF8.self)
        XCTAssertTrue(body.contains("name=\"model\"\r\n\r\nwhisper-1"))
        XCTAssertTrue(body.contains("name=\"language\"\r\n\r\nen"))
        XCTAssertTrue(body.contains("filename=\"audio.wav\""))
    }

    func testPlainTextResponse() throws {
        XCTAssertEqual(try OpenAITranscriptionClient.parseText(Data("hello\n".utf8)), "hello")
    }
}

final class AudioTests: XCTestCase {
    func testWAVHeader() {
        let data = WAVEncoder.encode(samples: [0, 1, -1], sampleRate: 16_000)
        XCTAssertEqual(data.count, 44 + 6)
        XCTAssertEqual(String(decoding: data.prefix(4), as: UTF8.self), "RIFF")
        XCTAssertEqual(String(decoding: data[8..<12], as: UTF8.self), "WAVE")
        XCTAssertEqual(data[44], 0)
        XCTAssertEqual(data[46], 0xFF)
        XCTAssertEqual(data[47], 0x7F)
    }

    func sine(seconds: Double, amplitude: Float, rate: Double = 16_000) -> [Float] {
        (0..<Int(seconds * rate)).map { i in amplitude * Float(sin(2 * Double.pi * 440 * Double(i) / rate)) }
    }

    func testVADDetectsOneSegment() {
        var vad = EnergyVAD()
        var segments: [[Float]] = []
        segments += vad.process([Float](repeating: 0.0005, count: 8_000))
        segments += vad.process(sine(seconds: 1.0, amplitude: 0.3))
        segments += vad.process([Float](repeating: 0.0005, count: 16_000))
        XCTAssertEqual(segments.count, 1)
        let duration = Double(segments[0].count) / 16_000
        XCTAssertGreaterThan(duration, 1.0)
        XCTAssertLessThan(duration, 2.0)
        XCTAssertFalse(vad.isSpeaking)
    }

    func testVADSplitsLongSpeech() {
        var config = EnergyVAD.Configuration()
        config.maxSegmentDuration = 2
        var vad = EnergyVAD(configuration: config)
        let segments = vad.process(sine(seconds: 5, amplitude: 0.3))
        XCTAssertEqual(segments.count, 2)
        XCTAssertNotNil(vad.flush())
    }

    func testVADIgnoresSilence() {
        var vad = EnergyVAD()
        XCTAssertTrue(vad.process([Float](repeating: 0, count: 48_000)).isEmpty)
        XCTAssertNil(vad.flush())
    }
}
