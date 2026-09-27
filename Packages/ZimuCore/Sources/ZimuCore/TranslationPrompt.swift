import Foundation

/// 构建字幕翻译的 prompt，以及清理模型输出
public enum TranslationPrompt {
    public static func systemPrompt(targetLanguage: String, customInstructions: String = "") -> String {
        let name = Languages.englishName(for: targetLanguage)
        var prompt = """
        You are a professional real-time subtitle translator. Translate the subtitle line given by the user into \(name) (\(targetLanguage)).
        Rules:
        - Output ONLY the translation of the current line. No explanations, notes, quotes, labels or the original text.
        - Keep it natural, fluent and concise, suitable for on-screen subtitles.
        - Previous lines, if provided, are context only. Do not translate or repeat them.
        - Keep names, numbers and terminology consistent with the context.
        - If the line is already in \(name), output it unchanged.
        """
        let custom = customInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
        if !custom.isEmpty {
            prompt += "\nAdditional instructions:\n\(custom)"
        }
        return prompt
    }

    public static func userMessage(text: String, context: [String]) -> String {
        let lines = context
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return text }
        let contextBlock = lines.map { "- \($0)" }.joined(separator: "\n")
        return """
        Previous lines (context only, do not translate):
        \(contextBlock)

        Translate this line:
        \(text)
        """
    }

    /// 清理模型输出：去掉 <think> 推理块、首尾空白和包裹的引号
    public static func cleanOutput(_ raw: String) -> String {
        var text = raw
        while let open = text.range(of: "<think>") {
            if let close = text.range(of: "</think>", range: open.upperBound..<text.endIndex) {
                text.removeSubrange(open.lowerBound..<close.upperBound)
            } else {
                // 推理块还没结束（流式输出中）
                text.removeSubrange(open.lowerBound..<text.endIndex)
            }
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let quotePairs: [(Character, Character)] = [("\"", "\""), ("“", "”"), ("「", "」"), ("'", "'")]
        for (open, close) in quotePairs {
            if text.count >= 2, text.first == open, text.last == close {
                let inner = text.dropFirst().dropLast()
                if !inner.contains(open) && !inner.contains(close) {
                    text = String(inner).trimmingCharacters(in: .whitespacesAndNewlines)
                }
                break
            }
        }
        return text
    }
}

/// 解析 OpenAI 兼容 /chat/completions 的 SSE 流
public enum ChatCompletionStreamParser {
    public enum LineResult: Equatable, Sendable {
        case delta(String)
        case done
        case ignore
    }

    public static func parse(line: String) -> LineResult {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("data:") else { return .ignore }
        let payload = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)
        if payload == "[DONE]" { return .done }
        guard let data = payload.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let first = choices.first
        else { return .ignore }
        if let delta = first["delta"] as? [String: Any], let content = delta["content"] as? String {
            return content.isEmpty ? .ignore : .delta(content)
        }
        if let message = first["message"] as? [String: Any], let content = message["content"] as? String {
            return content.isEmpty ? .ignore : .delta(content)
        }
        return .ignore
    }

    /// 非流式响应（服务忽略了 stream 参数时）
    public static func parseCompletion(_ body: String) -> String? {
        guard let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String
        else { return nil }
        return content
    }
}
