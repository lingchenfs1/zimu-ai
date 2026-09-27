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

    init(source: String, target: String) {
        self.sourceCode = source
        self.target = Locale.Language(identifier: target)
    }

    /// 检查语言包；原声语言为「自动检测」时跳过
    func prepare() async throws {
        guard sourceCode != "auto" else { return }
        _ = try await session(for: Locale.Language(identifier: sourceCode))
    }

    func translate(
        _ text: String,
        context: [String],
        onPartial: @escaping @MainActor @Sendable (String) -> Void
    ) async throws -> String {
        let source: Locale.Language
        if sourceCode == "auto" {
            guard let detected = NLLanguageRecognizer.dominantLanguage(for: text) else { return text }
            source = Locale.Language(identifier: detected.rawValue)
        } else {
            source = Locale.Language(identifier: sourceCode)
        }
        if source.languageCode == target.languageCode && source.script == target.script {
            return text
        }
        let session = try await session(for: source)
        let response = try await session.translate(text)
        return response.targetText
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
