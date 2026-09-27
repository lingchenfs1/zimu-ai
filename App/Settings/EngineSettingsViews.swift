import SwiftUI
import ZimuCore

/// 语音识别设置
struct TranscriptionSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var testResult: TestResult?
    @State private var isTesting = false
    @State private var modelStatus: String?
    @State private var isDownloading = false

    var body: some View {
        @Bindable var store = model.settingsStore
        @Bindable var keys = model.apiKeys

        Form {
            Section("识别引擎") {
                Picker("引擎", selection: $store.settings.transcriptionEngine) {
                    ForEach(TranscriptionEngineKind.allCases) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }
                .pickerStyle(.radioGroup)
            }

            switch store.settings.transcriptionEngine {
            case .apple:
                Section("Apple 本地识别") {
                    Text("在本机离线识别，免费、延迟低、不上传音频。首次使用某种语言时需要下载模型。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    LabeledContent("原声语言") {
                        Text(Locale.current.localizedString(forIdentifier: store.settings.sourceLanguage) ?? store.settings.sourceLanguage)
                    }
                    HStack {
                        Button(isDownloading ? "正在下载…" : "检查 / 下载语言模型") {
                            downloadModel(for: store.settings.sourceLanguage)
                        }
                        .disabled(isDownloading)
                        if let modelStatus {
                            Text(modelStatus).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            case .openAICompatible:
                Section("OpenAI 兼容云端识别") {
                    PresetMenu(presets: ServicePresets.transcription) { preset in
                        store.settings.cloudTranscription = OpenAIServiceConfig(baseURL: preset.baseURL, model: preset.model)
                    }
                    TextField("服务地址", text: $store.settings.cloudTranscription.baseURL, prompt: Text("https://api.openai.com/v1"))
                    SecureField("API Key", text: $keys.transcriptionKey, prompt: Text("sk-…（本地服务可留空）"))
                    TextField("模型", text: $store.settings.cloudTranscription.model, prompt: Text("gpt-4o-mini-transcribe"))
                    LabeledSlider(title: "语音检测灵敏度", value: $store.settings.vadSensitivity, range: 0...1, step: 0.05, format: { "\(Int($0 * 100))%" })
                    Text("音频按句子切段后上传，字幕会比本地识别慢 1～3 秒。API Key 保存在钥匙串中。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TestButton(title: "测试连接", isTesting: isTesting, result: testResult) {
                        testCloudTranscription()
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func downloadModel(for language: String) {
        isDownloading = true
        modelStatus = nil
        Task { @MainActor in
            do {
                let engine = AppleSpeechEngine(localeIdentifier: language)
                _ = try await engine.prepare { message in modelStatus = message }
                modelStatus = "✅ 模型已就绪"
            } catch {
                modelStatus = "❌ \(error.localizedDescription)"
            }
            isDownloading = false
        }
    }

    private func testCloudTranscription() {
        let settings = model.settingsStore.settings
        let client = OpenAITranscriptionClient(
            config: settings.cloudTranscription,
            apiKey: model.apiKeys.transcriptionKey,
            language: Languages.isoLanguageCode(settings.sourceLanguage),
            client: URLSessionHTTPClient()
        )
        isTesting = true
        testResult = nil
        Task { @MainActor in
            do {
                // 0.5 秒静音，只验证地址、Key 和模型是否可用
                let wav = WAVEncoder.encode(samples: [Float](repeating: 0, count: 8_000), sampleRate: 16_000)
                _ = try await client.transcribe(wav: wav, prompt: nil)
                testResult = .success("连接成功")
            } catch {
                testResult = .failure(error.localizedDescription)
            }
            isTesting = false
        }
    }
}

/// 翻译设置
struct TranslationSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var testResult: TestResult?
    @State private var isTesting = false

    var body: some View {
        @Bindable var store = model.settingsStore
        @Bindable var keys = model.apiKeys

        Form {
            Section("翻译引擎") {
                Picker("引擎", selection: $store.settings.translationEngine) {
                    ForEach(TranslationEngineKind.allCases) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }
                .pickerStyle(.radioGroup)
                Picker("翻译成", selection: $store.settings.targetLanguage) {
                    ForEach(Languages.targets) { language in
                        Text(language.name).tag(language.code)
                    }
                }
            }

            switch store.settings.translationEngine {
            case .none:
                Section {
                    Text("只显示识别出的原文。")
                        .foregroundStyle(.secondary)
                }
            case .apple:
                Section("Apple 本地翻译") {
                    Text("使用系统自带的离线翻译，免费且不联网。需要先下载对应的语言包。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    AppleTranslationStatusView(
                        source: store.settings.sourceLanguage,
                        target: store.settings.targetLanguage
                    )
                    TestButton(title: "测试翻译", isTesting: isTesting, result: testResult) {
                        testTranslation()
                    }
                }
            case .openAICompatible:
                Section("OpenAI 兼容服务") {
                    PresetMenu(presets: ServicePresets.translation) { preset in
                        store.settings.llmTranslation = OpenAIServiceConfig(baseURL: preset.baseURL, model: preset.model)
                    }
                    TextField("服务地址", text: $store.settings.llmTranslation.baseURL, prompt: Text("https://api.openai.com/v1"))
                    SecureField("API Key", text: $keys.translationKey, prompt: Text("sk-…（本地服务可留空）"))
                    TextField("模型", text: $store.settings.llmTranslation.model, prompt: Text("gpt-4o-mini"))
                    Stepper("参考前文 \(store.settings.translationContextLines) 句", value: $store.settings.translationContextLines, in: 0...8)
                    LabeledSlider(title: "温度", value: $store.settings.translationTemperature, range: 0...1, step: 0.05, format: { String(format: "%.2f", $0) })
                    VStack(alignment: .leading, spacing: 4) {
                        Text("额外要求（可选）")
                        TextEditor(text: $store.settings.customTranslationPrompt)
                            .font(.body)
                            .frame(minHeight: 60)
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
                        Text("例如：人名保留英文；语气口语化；专业术语参考……")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    TestButton(title: "测试翻译", isTesting: isTesting, result: testResult) {
                        testTranslation()
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func testTranslation() {
        let settings = model.settingsStore.settings
        isTesting = true
        testResult = nil
        let sample = "Hello! This is a quick test of the subtitle translator."
        Task { @MainActor in
            do {
                let engine: TranslationEngine
                switch settings.translationEngine {
                case .none:
                    isTesting = false
                    return
                case .apple:
                    let apple = AppleTranslationEngine(source: "en", target: settings.targetLanguage)
                    try await apple.prepare()
                    engine = apple
                case .openAICompatible:
                    engine = OpenAICompatibleTranslator(
                        config: settings.llmTranslation,
                        apiKey: model.apiKeys.translationKey,
                        targetLanguage: settings.targetLanguage,
                        temperature: settings.translationTemperature,
                        customInstructions: settings.customTranslationPrompt,
                        client: URLSessionHTTPClient()
                    )
                }
                let result = try await engine.translate(sample, context: []) { _ in }
                testResult = .success(result)
            } catch {
                testResult = .failure(error.localizedDescription)
            }
            isTesting = false
        }
    }
}

/// 快捷键与关于
struct ShortcutsSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var store = model.settingsStore

        Form {
            Section("全局快捷键") {
                Toggle("启用全局快捷键", isOn: $store.settings.hotkeysEnabled)
                ForEach(HotKeyCenter.all) { hotKey in
                    LabeledContent(hotKey.title) {
                        Text(hotKey.display)
                            .font(.system(.body, design: .monospaced))
                    }
                }
                if !model.failedHotKeys.isEmpty {
                    Text("以下快捷键被其他应用占用，未能注册：\(model.failedHotKeys.joined(separator: "、"))")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Section("关于") {
                LabeledContent("版本", value: AppInfo.versionString)
                Link("项目主页", destination: URL(string: "https://github.com/lingchenfs1/zimu-ai")!)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - 小组件

enum TestResult: Equatable {
    case success(String)
    case failure(String)
}

struct TestButton: View {
    let title: String
    let isTesting: Bool
    let result: TestResult?
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button(title, action: action)
                    .disabled(isTesting)
                if isTesting {
                    ProgressView().controlSize(.small)
                }
            }
            switch result {
            case .success(let message):
                Text("✅ \(message)")
                    .font(.callout)
                    .textSelection(.enabled)
            case .failure(let message):
                Text("❌ \(message)")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            case nil:
                EmptyView()
            }
        }
    }
}

struct PresetMenu: View {
    let presets: [ServicePreset]
    let apply: (ServicePreset) -> Void

    var body: some View {
        LabeledContent("快速填写") {
            Menu("选择服务预设") {
                ForEach(presets) { preset in
                    Button(preset.name) { apply(preset) }
                }
            }
            .fixedSize()
        }
    }
}

enum AppInfo {
    static var versionString: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }
}
