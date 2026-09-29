import Foundation

/// 按服务自动关闭大模型的「思考」（决策 D18）。
///
/// 字幕翻译不需要推理：思考模式又慢，还可能把思维链混进译文。不同服务关闭思考的参数不同，
/// 这里按服务地址（和模型名）给出要附加的请求参数；不认识的服务不附加。
public enum ThinkingControl {
    /// 关闭思考需要附加到请求体的参数；不需要或无法判断时返回空字典
    public static func parameters(baseURL: String, model: String) -> [String: Any] {
        let url = URL(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines))
        let host = url?.host?.lowercased() ?? ""
        let port = url?.port
        let model = model.lowercased()

        // 本机：Ollama、LM Studio 的 OpenAI 兼容接口只认 reasoning_effort（Ollama 不认 think）
        if port == 11434 || host.contains("ollama") || port == 1234 || host.contains("lmstudio") || host.contains("lm-studio") {
            return ["reasoning_effort": "none"]
        }
        // 阿里云百炼（通义千问）、硅基流动
        if host.hasSuffix("dashscope.aliyuncs.com") || host.hasSuffix("dashscope-intl.aliyuncs.com") || host.contains("siliconflow") {
            return ["enable_thinking": false]
        }
        // 智谱、火山方舟（豆包）
        if host.hasSuffix("bigmodel.cn") || host == "api.z.ai" || host.hasSuffix("volces.com") {
            return ["thinking": ["type": "disabled"]]
        }
        // OpenAI gpt-5 系列：gpt-5 / mini / nano 最低是 minimal，gpt-5.1 起支持 none
        if host == "api.openai.com", model.hasPrefix("gpt-5") {
            return ["reasoning_effort": model.hasPrefix("gpt-5.") ? "none" : "minimal"]
        }
        return [:]
    }

    /// 追加在系统提示词末尾的软开关：Qwen3 混合思考模型认 `/no_think`
    public static func promptSuffix(model: String) -> String? {
        let model = model.lowercased()
        guard model.contains("qwen3"), !model.contains("qwen3."), !model.contains("instruct"), !model.contains("thinking") else {
            return nil
        }
        return "/no_think"
    }

    /// 模型名看起来是推理（思考）模型：翻译延迟高，可能输出思考过程
    public static func looksLikeReasoningModel(_ model: String) -> Bool {
        let name = model.lowercased()
        let markers = ["-r1", "r1-", "/r1", "reasoner", "thinking", "qwq", "gpt-oss", "magistral"]
        if markers.contains(where: { name.contains($0) }) || name == "r1" {
            return true
        }
        // OpenAI o 系列：o1、o3-mini、o4-mini……
        let base = name.split(separator: "/").last.map(String.init) ?? name
        return base.range(of: #"^o[134](-|$)"#, options: .regularExpression) != nil
    }

    /// 把参数转成 JSON 文本，用于界面显示
    public static func describe(_ parameters: [String: Any]) -> String {
        guard !parameters.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: parameters, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8)
        else { return "" }
        return text
    }
}

/// 一次运行中同一个翻译器共享的状态（翻译器本身是值类型，状态放在这里）
public final class TranslatorSessionState: @unchecked Sendable {
    private let lock = NSLock()
    private var _sawReasoning = false
    private var _autoParametersRejected = false

    public init() {}

    /// 模型输出过推理内容：之后的流式输出在推理结束前都不显示
    public var sawReasoning: Bool {
        get { lock.withLock { _sawReasoning } }
        set { lock.withLock { _sawReasoning = newValue } }
    }

    /// 服务拒绝了自动附加的关闭思考参数（HTTP 400）：之后不再附加
    public var autoParametersRejected: Bool {
        get { lock.withLock { _autoParametersRejected } }
        set { lock.withLock { _autoParametersRejected = newValue } }
    }
}
