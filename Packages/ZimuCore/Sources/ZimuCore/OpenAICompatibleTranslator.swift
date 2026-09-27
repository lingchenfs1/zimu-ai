import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// 通过 OpenAI 兼容的 /chat/completions 接口翻译（OpenAI、DeepSeek、通义、Ollama 等）
public struct OpenAICompatibleTranslator: TranslationEngine {
    public var config: OpenAIServiceConfig
    public var apiKey: String
    public var targetLanguage: String
    public var temperature: Double
    public var customInstructions: String
    public var stream: Bool
    public var timeout: TimeInterval
    /// 额外的请求参数（JSON 对象字符串），会合并到请求体中，例如 {"enable_thinking": false}
    public var extraBodyJSON: String
    private let client: any HTTPClient

    public init(
        config: OpenAIServiceConfig,
        apiKey: String,
        targetLanguage: String,
        temperature: Double = 0.3,
        customInstructions: String = "",
        stream: Bool = true,
        timeout: TimeInterval = 30,
        extraBodyJSON: String = "",
        client: any HTTPClient
    ) {
        self.config = config
        self.apiKey = apiKey
        self.targetLanguage = targetLanguage
        self.temperature = temperature
        self.customInstructions = customInstructions
        self.stream = stream
        self.timeout = timeout
        self.extraBodyJSON = extraBodyJSON
        self.client = client
    }

    /// 解析额外请求参数；为空返回空字典，格式错误时抛出
    public static func parseExtraBody(_ json: String) throws -> [String: Any] {
        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [:] }
        guard let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw ServiceError.invalidExtraParameters }
        return object
    }

    public func makeRequest(text: String, context: [String], sourceLanguage: String? = nil) throws -> URLRequest {
        let model = config.model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else { throw ServiceError.missingModel }
        let url = try OpenAIEndpoint.url(base: config.baseURL, path: OpenAIEndpoint.chatCompletionsPath)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(stream ? "text/event-stream" : "application/json", forHTTPHeaderField: "Accept")
        OpenAIEndpoint.authorize(&request, apiKey: apiKey)
        var body: [String: Any] = [
            "model": model,
            "stream": stream,
            "temperature": temperature,
            "messages": [
                ["role": "system", "content": TranslationPrompt.systemPrompt(targetLanguage: targetLanguage, customInstructions: customInstructions)],
                ["role": "user", "content": TranslationPrompt.userMessage(text: text, context: context, sourceLanguage: sourceLanguage)],
            ],
        ]
        for (key, value) in try Self.parseExtraBody(extraBodyJSON) where key != "messages" {
            body[key] = value
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    public func translate(
        _ text: String,
        sourceLanguage: String?,
        context: [String],
        onPartial: @escaping @MainActor @Sendable (String) -> Void
    ) async throws -> String {
        let request = try makeRequest(text: text, context: context, sourceLanguage: sourceLanguage)
        var response: HTTPResponseInfo?
        var accumulated = ""
        var otherLines: [String] = []
        var lastReported = ""

        try await client.streamLines(request) { event in
            switch event {
            case .response(let info):
                response = info
            case .line(let line):
                guard response?.isSuccess ?? false else {
                    otherLines.append(line)
                    return
                }
                switch ChatCompletionStreamParser.parse(line: line) {
                case .delta(let piece):
                    accumulated += piece
                    let cleaned = TranslationPrompt.cleanOutput(accumulated)
                    if !cleaned.isEmpty, cleaned != lastReported {
                        lastReported = cleaned
                        await onPartial(cleaned)
                    }
                case .done:
                    break
                case .ignore:
                    otherLines.append(line)
                }
            }
        }

        guard let info = response else { throw ServiceError.emptyResponse }
        let otherBody = otherLines.joined(separator: "\n")
        guard info.isSuccess else {
            throw ServiceError.http(status: info.statusCode, message: OpenAIEndpoint.errorMessage(from: Data(otherBody.utf8)))
        }
        if accumulated.isEmpty, let full = ChatCompletionStreamParser.parseCompletion(otherBody) {
            accumulated = full
        }
        let result = TranslationPrompt.cleanOutput(accumulated)
        guard !result.isEmpty else {
            if !otherBody.isEmpty { throw ServiceError.invalidResponse(otherBody) }
            throw ServiceError.emptyResponse
        }
        return result
    }
}
