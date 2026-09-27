import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct HTTPResponseInfo: Sendable, Equatable {
    public var statusCode: Int
    public var contentType: String?

    public init(statusCode: Int, contentType: String?) {
        self.statusCode = statusCode
        self.contentType = contentType
    }

    public var isSuccess: Bool { (200..<300).contains(statusCode) }
}

/// 流式响应中的事件：先收到响应头，然后逐行收到响应体
public enum HTTPStreamEvent: Sendable, Equatable {
    case response(HTTPResponseInfo)
    case line(String)
}

/// 网络访问抽象，便于单元测试注入假实现
public protocol HTTPClient: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPResponseInfo)
    func streamLines(_ request: URLRequest, handler: (HTTPStreamEvent) async throws -> Void) async throws
}

#if canImport(Darwin)
/// 基于 URLSession 的实现
public struct URLSessionHTTPClient: HTTPClient {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPResponseInfo) {
        let (data, response) = try await session.data(for: request)
        return (data, Self.info(from: response))
    }

    public func streamLines(_ request: URLRequest, handler: (HTTPStreamEvent) async throws -> Void) async throws {
        let (bytes, response) = try await session.bytes(for: request)
        try await handler(.response(Self.info(from: response)))
        for try await line in bytes.lines {
            try Task.checkCancellation()
            try await handler(.line(line))
        }
    }

    static func info(from response: URLResponse) -> HTTPResponseInfo {
        let http = response as? HTTPURLResponse
        return HTTPResponseInfo(
            statusCode: http?.statusCode ?? 0,
            contentType: http?.value(forHTTPHeaderField: "Content-Type")
        )
    }
}
#endif

/// 网络服务错误
public enum ServiceError: Error, LocalizedError, Equatable {
    case invalidBaseURL(String)
    case missingModel
    case http(status: Int, message: String)
    case emptyResponse
    case invalidResponse(String)

    public var errorDescription: String? {
        switch self {
        case .invalidBaseURL(let url):
            return "服务地址无效：\(url)"
        case .missingModel:
            return "没有填写模型名称"
        case .http(let status, let message):
            let detail = message.isEmpty ? "" : "：\(message)"
            switch status {
            case 401, 403: return "认证失败（HTTP \(status)），请检查 API Key\(detail)"
            case 404: return "接口不存在（HTTP 404），请检查服务地址和模型名称\(detail)"
            case 429: return "请求过于频繁或额度不足（HTTP 429）\(detail)"
            default: return "服务返回错误（HTTP \(status)）\(detail)"
            }
        case .emptyResponse:
            return "服务返回了空结果"
        case .invalidResponse(let body):
            return "无法解析服务返回的数据：\(body.prefix(200))"
        }
    }
}

/// OpenAI 兼容接口的地址拼接与错误解析
public enum OpenAIEndpoint {
    public static let chatCompletionsPath = "/chat/completions"
    public static let transcriptionsPath = "/audio/transcriptions"

    /// baseURL 形如 "https://api.openai.com/v1"；如果用户直接填了完整接口地址也能识别
    public static func url(base: String, path: String) throws -> URL {
        var trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        let full = trimmed.hasSuffix(path) ? trimmed : trimmed + path
        guard let url = URL(string: full),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty
        else { throw ServiceError.invalidBaseURL(base) }
        return url
    }

    /// 从错误响应体里提取 message（兼容 {"error":{"message":...}} / {"error":"..."} / {"message":...}）
    public static func errorMessage(from body: Data) -> String {
        if let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
            if let error = json["error"] as? [String: Any], let message = error["message"] as? String {
                return message
            }
            if let error = json["error"] as? String { return error }
            if let message = json["message"] as? String { return message }
            if let detail = json["detail"] as? String { return detail }
        }
        let text = String(decoding: body, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return String(text.prefix(300))
    }

    public static func authorize(_ request: inout URLRequest, apiKey: String) {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
    }
}
