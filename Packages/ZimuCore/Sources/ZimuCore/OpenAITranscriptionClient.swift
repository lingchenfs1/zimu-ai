import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// 通过 OpenAI 兼容的 /audio/transcriptions 接口识别一段音频
public struct OpenAITranscriptionClient: Sendable {
    public var config: OpenAIServiceConfig
    public var apiKey: String
    /// ISO-639-1 语言代码；nil 表示自动检测
    public var language: String?
    public var timeout: TimeInterval
    private let client: any HTTPClient

    public init(config: OpenAIServiceConfig, apiKey: String, language: String?, timeout: TimeInterval = 30, client: any HTTPClient) {
        self.config = config
        self.apiKey = apiKey
        self.language = language
        self.timeout = timeout
        self.client = client
    }

    public func makeRequest(wav: Data, prompt: String?) throws -> URLRequest {
        let model = config.model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else { throw ServiceError.missingModel }
        let url = try OpenAIEndpoint.url(base: config.baseURL, path: OpenAIEndpoint.transcriptionsPath)
        var form = MultipartFormData()
        form.addField(name: "model", value: model)
        form.addField(name: "response_format", value: "json")
        form.addField(name: "temperature", value: "0")
        if let language, !language.isEmpty {
            form.addField(name: "language", value: language)
        }
        if let prompt = prompt?.trimmingCharacters(in: .whitespacesAndNewlines), !prompt.isEmpty {
            form.addField(name: "prompt", value: String(prompt.suffix(200)))
        }
        form.addFile(name: "file", filename: "audio.wav", mimeType: "audio/wav", data: wav)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue(form.contentType, forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        OpenAIEndpoint.authorize(&request, apiKey: apiKey)
        request.httpBody = form.finalized()
        return request
    }

    public func transcribe(wav: Data, prompt: String?) async throws -> String {
        let request = try makeRequest(wav: wav, prompt: prompt)
        let (data, info) = try await client.send(request)
        guard info.isSuccess else {
            throw ServiceError.http(status: info.statusCode, message: OpenAIEndpoint.errorMessage(from: data))
        }
        return try Self.parseText(data)
    }

    public static func parseText(_ data: Data) throws -> String {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let text = json["text"] as? String {
                return text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            throw ServiceError.invalidResponse(String(decoding: data, as: UTF8.self))
        }
        // response_format 被忽略、直接返回纯文本的服务
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
