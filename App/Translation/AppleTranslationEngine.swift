import Foundation
import NaturalLanguage
import SwiftUI
import Translation
import ZimuCore

enum AppleTranslationError: LocalizedError {
    case notInstalled(String)
    case unsupported(String)

    var errorDescription: String? {
        switch self {
        case .notInstalled(let pair):
            return "Apple 翻译语言包未下载（\(pair)）。请在 设置 › 翻译 中点击「下载语言包」。"
        case .unsupported(let pair):
            return "Apple 本地翻译不支持该语言组合（\(pair)）"
        }
    }
}

/// Apple 本地翻译（macOS 26：TranslationSession 可以脱离 SwiftUI 使用，但只能用于已安装的语言包）
actor AppleTranslationEngine: TranslationEngine {
    private let sourceCode: String
    private let target: Locale.Language
    private var sessions: [String: TranslationSession] = [:]
    /// 串行化翻译请求：实时翻译与整句批量翻译不在同一个会话上并发执行
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    private func acquire() async {
        if !busy {
            busy = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty {
            busy = false
        } else {
            waiters.removeFirst().resume()
        }
    }

    init(source: String, target: String) {
        self.sourceCode = source
        self.target = Locale.Language(identifier: target)
    }

    /// 检查语言包；原声语言为「自动检测」或与目标语言相同时跳过
    func prepare() async throws {
        guard sourceCode != "auto" else { return }
        let source = Locale.Language(identifier: sourceCode)
        guard !Self.isSameLanguage(source, target) else { return }
        _ = try await session(for: source)
    }

    /// 检查多个源语言的语言包，返回缺少语言包或不支持的语言组合
    func missingPairs(for sources: [String]) async -> [String] {
        var missing: [String] = []
        for code in sources where code != "auto" {
            let source = Locale.Language(identifier: code)
            if Self.isSameLanguage(source, target) { continue }
            do {
                _ = try await session(for: source)
            } catch {
                missing.append("\(source.minimalIdentifier) → \(target.minimalIdentifier)")
            }
        }
        return missing
    }

    /// 比较语言和文字（zh-CN 与 zh-Hans 视为相同，zh-Hans 与 zh-Hant 不同）
    static func isSameLanguage(_ lhs: Locale.Language, _ rhs: Locale.Language) -> Bool {
        let a = Locale.Language(identifier: lhs.maximalIdentifier)
        let b = Locale.Language(identifier: rhs.maximalIdentifier)
        return a.languageCode == b.languageCode && a.script == b.script
    }

    nonisolated var maxBatchSize: Int { 8 }

    func translate(
        _ text: String,
        sourceLanguage: String?,
        context: [String],
        onPartial: @escaping @MainActor @Sendable (String) -> Void
    ) async throws -> String {
        guard let source = resolveSource(for: text, hint: sourceLanguage) else { return text }
        if Self.isSameLanguage(source, target) {
            return text
        }
        let session = try await session(for: source)
        await acquire()
        defer { release() }
        let response = try await session.translate(text)
        return response.targetText
    }

    /// 一次翻译多句（Apple 翻译的批量接口比逐句调用快）。
    /// 没有指定源语言时逐句判断语言，按语言分组后分别批量翻译。
    func translateBatch(_ texts: [String], sourceLanguage: String?) async throws -> [String] {
        var results = texts
        var groups: [String: (language: Locale.Language, indices: [Int])] = [:]
        var order: [String] = []
        for (index, text) in texts.enumerated() {
            guard let source = resolveSource(for: text, hint: sourceLanguage),
                  !Self.isSameLanguage(source, target)
            else { continue }
            let key = source.maximalIdentifier
            if groups[key] == nil {
                groups[key] = (source, [])
                order.append(key)
            }
            groups[key]?.indices.append(index)
        }
        for key in order {
            guard let group = groups[key] else { continue }
            let session = try await session(for: group.language)
            let requests = group.indices.map { index in
                TranslationSession.Request(sourceText: texts[index], clientIdentifier: String(index))
            }
            await acquire()
            let responses: [TranslationSession.Response]
            do {
                responses = try await session.translations(from: requests)
                release()
            } catch {
                release()
                throw error
            }
            for response in responses {
                if let identifier = response.clientIdentifier, let index = Int(identifier), results.indices.contains(index) {
                    results[index] = response.targetText
                }
            }
        }
        return results
    }

    /// 源语言：优先用识别结果带的语言，其次用设置中的语言，自动检测时用 NaturalLanguage 判断
    private func resolveSource(for text: String, hint: String?) -> Locale.Language? {
        if let hint, hint != "auto" {
            return Locale.Language(identifier: hint)
        }
        if sourceCode != "auto" {
            return Locale.Language(identifier: sourceCode)
        }
        guard let detected = NLLanguageRecognizer.dominantLanguage(for: text) else { return nil }
        return Locale.Language(identifier: detected.rawValue)
    }

    private func session(for source: Locale.Language) async throws -> TranslationSession {
        let key = source.maximalIdentifier
        if let existing = sessions[key] { return existing }
        let pair = "\(source.minimalIdentifier) → \(target.minimalIdentifier)"
        let status = await LanguageAvailability().status(from: source, to: target)
        switch status {
        case .installed:
            break
        case .supported:
            throw AppleTranslationError.notInstalled(pair)
        case .unsupported:
            throw AppleTranslationError.unsupported(pair)
        @unknown default:
            break
        }
        // 等待期间可能已被其他调用创建
        if let existing = sessions[key] { return existing }
        let session = TranslationSession(installedSource: source, target: target)
        sessions[key] = session
        return session
    }
}

/// 设置界面中显示语言包状态，并通过系统界面下载语言包
struct AppleTranslationStatusView: View {
    let source: String
    let target: String

    @State private var statusText = "正在检查…"
    @State private var canDownload = false
    @State private var configuration: TranslationSession.Configuration?

    var body: some View {
        HStack {
            Text(statusText)
                .font(.callout)
            Spacer()
            Button("下载语言包") {
                if configuration == nil {
                    configuration = TranslationSession.Configuration(
                        source: source == "auto" ? nil : Locale.Language(identifier: source),
                        target: Locale.Language(identifier: target)
                    )
                } else {
                    configuration?.invalidate()
                }
            }
            .disabled(!canDownload)
        }
        .translationTask(configuration) { session in
            do {
                try await session.prepareTranslation()
            } catch {
                statusText = "❌ \(error.localizedDescription)"
            }
            await refresh()
        }
        .task(id: "\(source)->\(target)") {
            configuration = nil
            await refresh()
        }
    }

    private func refresh() async {
        let targetLanguage = Locale.Language(identifier: target)
        guard source != "auto" else {
            statusText = "原声语言为「自动检测」，将按识别出的语言使用已安装的语言包"
            canDownload = true
            return
        }
        let status = await LanguageAvailability().status(from: Locale.Language(identifier: source), to: targetLanguage)
        switch status {
        case .installed:
            statusText = "✅ 语言包已安装"
            canDownload = false
        case .supported:
            statusText = "⚠️ 语言包未下载"
            canDownload = true
        case .unsupported:
            statusText = "❌ 不支持该语言组合"
            canDownload = false
        @unknown default:
            statusText = "未知状态"
            canDownload = true
        }
    }
}
