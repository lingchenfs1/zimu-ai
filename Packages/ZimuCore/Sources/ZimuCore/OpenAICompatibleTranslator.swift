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
    /// 按服务自动附加关闭思考的参数（决策 D18）
    public var disableThinking: Bool
    public var scenario: TranslationScenario
    /// 专有名词（人名、术语）
    public var glossary: [String]
    /// 本次运行共享的状态：是否见过推理输出、自动参数是否被拒绝
    public let session: TranslatorSessionState
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
        disableThinking: Bool = true,
        scenario: TranslationScenario = .general,
        glossary: [String] = [],
        session: TranslatorSessionState = TranslatorSessionState(),
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
        self.disableThinking = disableThinking
        self.scenario = scenario
        self.glossary = glossary
        self.session = session
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

    /// 自动附加的关闭思考参数（已关闭该功能或被服务拒绝过时为空）
    public var automaticThinkingParameters: [String: Any] {
        guard disableThinking, !session.autoParametersRejected else { return [:] }
        return ThinkingControl.parameters(baseURL: config.baseURL, model: config.model)
    }

    /// 实际发送的系统提示词（设置界面的「提示词预览」也用它）
    public func systemPrompt(correctSource: Bool = false) -> String {
        TranslationPrompt.systemPrompt(
            targetLanguage: targetLanguage,
            options: TranslationPrompt.Options(
                customInstructions: customInstructions,
                scenario: scenario,
                glossary: glossary,
                correctSource: correctSource,
                suffix: disableThinking ? ThinkingControl.promptSuffix(model: config.model) : nil
            )
        )
    }

    public func makeRequest(
        text: String,
        context: [String],
        sourceLanguage: String? = nil,
        correctSource: Bool = false,
        includeAutomaticParameters: Bool = true
    ) throws -> URLRequest {
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
                ["role": "system", "content": systemPrompt(correctSource: correctSource)],
                ["role": "user", "content": TranslationPrompt.userMessage(text: text, context: context, sourceLanguage: sourceLanguage)],
            ],
        ]
        if includeAutomaticParameters {
            for (key, value) in automaticThinkingParameters {
                body[key] = value
            }
        }
        // 用户填写的额外参数优先于自动参数
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
        try await run(text: text, sourceLanguage: sourceLanguage, context: context, correctSource: false, onPartial: onPartial).translation
    }

    /// 翻译并校正识别文字（决策 D20）。返回的 source 是模型给出的校正后原文，是否采用由调用方用
    /// `SourceCorrection.accepted(original:corrected:)` 判断。
    public func translateCorrectingSource(
        _ text: String,
        sourceLanguage: String?,
        context: [String],
        onPartial: @escaping @MainActor @Sendable (String) -> Void
    ) async throws -> SourceCorrection.Result {
        try await run(text: text, sourceLanguage: sourceLanguage, context: context, correctSource: true, onPartial: onPartial)
    }

    private func run(
        text: String,
        sourceLanguage: String?,
        context: [String],
        correctSource: Bool,
        onPartial: @escaping @MainActor @Sendable (String) -> Void
    ) async throws -> SourceCorrection.Result {
        let usesAutomatic = !automaticThinkingParameters.isEmpty
        do {
            let request = try makeRequest(text: text, context: context, sourceLanguage: sourceLanguage, correctSource: correctSource)
            return try await perform(request, correctSource: correctSource, onPartial: onPartial)
        } catch let ServiceError.http(status, _) where status == 400 && usesAutomatic {
            // 有些「始终思考」的模型会拒绝关闭思考的参数：去掉自动参数重试一次，本次运行不再附加
            session.autoParametersRejected = true
            let request = try makeRequest(
                text: text,
                context: context,
                sourceLanguage: sourceLanguage,
                correctSource: correctSource,
                includeAutomaticParameters: false
            )
            return try await perform(request, correctSource: correctSource, onPartial: onPartial)
        }
    }

    private func perform(
        _ request: URLRequest,
        correctSource: Bool,
        onPartial: @escaping @MainActor @Sendable (String) -> Void
    ) async throws -> SourceCorrection.Result {
        var response: HTTPResponseInfo?
        var filter = StreamingTranslationFilter(expectsReasoning: session.sawReasoning, correctsSource: correctSource)
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
                    if let visible = filter.append(piece), visible != lastReported {
                        lastReported = visible
                        await onPartial(visible)
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
        if filter.raw.isEmpty, let full = ChatCompletionStreamParser.parseCompletion(otherBody) {
            _ = filter.append(full)
        }
        if filter.sawReasoning {
            session.sawReasoning = true
        }
        let result = correctSource ? filter.correction : SourceCorrection.Result(source: nil, translation: filter.finalText)
        guard !result.translation.isEmpty else {
            if filter.sawReasoning { throw ServiceError.onlyReasoning }
            if !otherBody.isEmpty { throw ServiceError.invalidResponse(otherBody) }
            throw ServiceError.emptyResponse
        }
        return result
    }
}

extension OpenAICompatibleTranslator {
    /// 按设置创建（流水线、「测试翻译」和提示词预览共用，保证三处发送的内容一致）
    public static func configured(
        from settings: AppSettings,
        apiKey: String,
        targetLanguage: String,
        session: TranslatorSessionState = TranslatorSessionState(),
        client: any HTTPClient
    ) -> OpenAICompatibleTranslator {
        OpenAICompatibleTranslator(
            config: settings.llmTranslation,
            apiKey: apiKey,
            targetLanguage: targetLanguage,
            temperature: settings.translationTemperature,
            customInstructions: settings.customTranslationPrompt,
            extraBodyJSON: settings.llmExtraBody,
            disableThinking: settings.disableThinking,
            scenario: settings.translationScenario,
            glossary: Glossary.terms(from: settings.glossary),
            session: session,
            client: client
        )
    }
}
