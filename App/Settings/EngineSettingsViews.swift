import SwiftUI
import ZimuCore

/// 语音识别设置
struct TranscriptionSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var testResult: TestResult?
    @State private var isTesting = false
    @State private var modelStatus: String?
    @State private var isDownloading = false
    @State private var preparation: PreparationStatus?
    @State private var supportedLocales: [Locale] = []

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
                .onChange(of: store.settings.transcriptionEngine) { _, _ in
                    modelStatus = nil
                    testResult = nil
                }
            }

            switch store.settings.transcriptionEngine {
            case .apple:
                Section("Apple 本地识别（单一语言）") {
                    Text("在本机离线识别，免费、延迟最低、不上传音频。需要在 设置 › 通用 中选择原声语言，首次使用某种语言时会下载模型。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    LabeledContent("原声语言") {
                        Text(Locale.current.localizedString(forIdentifier: store.settings.sourceLanguage) ?? store.settings.sourceLanguage)
                    }
                    modelDownloadRow {
                        let engine = AppleSpeechEngine(localeIdentifier: store.settings.sourceLanguage)
                        _ = try await engine.prepare { status in preparation = status }
                    }
                }
            case .appleMultilingual:
                Section("Apple 本地识别（多语言自动切换）") {
                    Text("同时运行多种语言的本地识别器，按识别置信度自动切换到正在说的语言。请勾选 2～4 种可能出现的语言；勾选越多越耗电。同一句话里混说多种语言时效果一般。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    CandidateLanguagePicker(
                        selection: $store.settings.appleCandidateLanguages,
                        locales: supportedLocales,
                        maximum: AppleMultilingualSpeechEngine.maximumLanguages
                    )
                    modelDownloadRow {
                        let engine = AppleMultilingualSpeechEngine(localeIdentifiers: store.settings.appleCandidateLanguages)
                        _ = try await engine.prepare { status in preparation = status }
                    }
                }
            case .whisperKit:
                Section("WhisperKit 本地识别（自动检测语言）") {
                    Text("使用开源 Whisper 模型在本机识别，可自动识别近百种语言，不上传音频。需要先下载模型；比 Apple 识别更耗 CPU / GPU，延迟约 1～2 秒。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Picker("模型", selection: $store.settings.whisperModel) {
                        ForEach(WhisperModelOption.all) { option in
                            Text("\(option.name) · \(option.sizeDescription)").tag(option.id)
                        }
                    }
                    TextField("下载地址（镜像）", text: $store.settings.whisperEndpoint, prompt: Text("留空使用 huggingface.co"))
                    HStack {
                        Text("国内网络可以填写 HuggingFace 镜像地址。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("使用 hf-mirror.com") { store.settings.whisperEndpoint = "https://hf-mirror.com" }
                            .controlSize(.small)
                    }
                    LabeledSlider(title: "语音检测灵敏度", value: $store.settings.vadSensitivity, range: 0...1, step: 0.05, format: { "\(Int($0 * 100))%" })
                    if WhisperKitTranscriber.isModelDownloaded(store.settings.whisperModel) {
                        Text("✅ 模型已下载").font(.caption)
                    }
                    modelDownloadRow(title: "下载 / 加载模型") {
                        let transcriber = WhisperKitTranscriber(
                            model: store.settings.whisperModel,
                            endpoint: store.settings.whisperEndpoint,
                            language: store.settings.sourceLanguage
                        )
                        try await transcriber.prepare { status in preparation = status }
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
                    Text("原声语言选「自动检测」时，每段音频都会自动判断语言（设置 › 通用）。音频按句子切段后上传，字幕会比本地识别慢 1～3 秒。API Key 保存在钥匙串中。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TestButton(title: "测试连接", isTesting: isTesting, result: testResult) {
                        testCloudTranscription()
                    }
                }
            }
        }
        .formStyle(.grouped)
        .task {
            supportedLocales = await SpeechLocaleCatalog.supportedLocales()
        }
    }

    /// 「检查 / 下载模型」按钮、进度条和结果
    @ViewBuilder
    private func modelDownloadRow(title: String = "检查 / 下载语言模型", action: @escaping @MainActor () async throws -> Void) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button(isDownloading ? "正在准备…" : title) {
                    isDownloading = true
                    modelStatus = nil
                    preparation = PreparationStatus("正在检查模型…")
                    Task { @MainActor in
                        do {
                            try await action()
                            modelStatus = "✅ 模型已就绪"
                        } catch {
                            modelStatus = "❌ \(error.localizedDescription)"
                        }
                        isDownloading = false
                        preparation = nil
                    }
                }
                .disabled(isDownloading)
                if let modelStatus {
                    Text(modelStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if isDownloading {
                PreparationProgressView(status: preparation)
            }
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

/// 多语言识别的候选语言选择
struct CandidateLanguagePicker: View {
    @Binding var selection: [String]
    let locales: [Locale]
    let maximum: Int

    private static let common = ["en-US", "zh-CN", "ja-JP", "ko-KR", "fr-FR", "de-DE", "es-ES", "yue-CN", "zh-TW"]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("候选语言（已选 \(selection.count) / 最多 \(maximum)）")
                Spacer()
                if selection.count < 2 {
                    Text("至少选择 2 种").font(.caption).foregroundStyle(.orange)
                }
            }
            let options = orderedOptions()
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), alignment: .leading)], alignment: .leading, spacing: 4) {
                ForEach(options, id: \.self) { identifier in
                    Toggle(isOn: binding(for: identifier)) {
                        Text(Locale.current.localizedString(forIdentifier: identifier) ?? identifier)
                            .lineLimit(1)
                    }
                    .toggleStyle(.checkbox)
                    .disabled(!selection.contains(identifier) && selection.count >= maximum)
                }
            }
        }
    }

    /// 常用语言排前面，其余按系统支持列表
    private func orderedOptions() -> [String] {
        let supported = locales.map { $0.identifier(.bcp47) }
        var result: [String] = []
        for id in Self.common + selection where !result.contains(id) && (supported.isEmpty || supported.contains(id) || selection.contains(id)) {
            result.append(id)
        }
        for id in supported where !result.contains(id) {
            result.append(id)
        }
        return result
    }

    private func binding(for identifier: String) -> Binding<Bool> {
        Binding(
            get: { selection.contains(identifier) },
            set: { isOn in
                if isOn {
                    if !selection.contains(identifier), selection.count < maximum {
                        selection.append(identifier)
                    }
                } else {
                    selection.removeAll { $0 == identifier }
                }
            }
        )
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
                .onChange(of: store.settings.targetLanguage) { _, primary in
                    // 主目标语言不再出现在「同时翻译成」里
                    store.settings.additionalTargetLanguages.removeAll { $0 == primary }
                }
                if store.settings.translationEngine != .none {
                    AdditionalTargetsPicker(
                        primary: store.settings.targetLanguage,
                        selection: $store.settings.additionalTargetLanguages,
                        maximum: AppSettings.maximumAdditionalTargets
                    )
                    Toggle("实时翻译识别中的文字", isOn: $store.settings.liveTranslation)
                    Text(store.settings.translationEngine == .apple
                         ? "一句话还没说完就开始翻译，译文基本与原文同步（Apple 本地翻译免费，建议开启）。"
                         : "一句话还没说完就开始翻译，译文更及时，但会明显增加 API 调用次数和费用（同时翻译成多种语言时按语言数倍增）。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
                    Text("使用系统自带的离线翻译，免费且不联网。需要先下载对应的语言包；同时翻译成多种语言时，每种语言都需要语言包。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    let targets = store.settings.translationTargets
                    ForEach(targets, id: \.self) { target in
                        AppleTranslationStatusView(
                            source: store.settings.sourceLanguage,
                            target: target,
                            showsTarget: targets.count > 1
                        )
                    }
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
                    Stepper("同时翻译 \(store.settings.translationConcurrency) 句", value: $store.settings.translationConcurrency, in: 1...6)
                    TextField("额外请求参数（JSON）", text: $store.settings.llmExtraBody, prompt: Text(#"例如 {"enable_thinking": false}"#))
                    Text("使用 Qwen3、DeepSeek-R1 等「思考」模型时，关闭思考能大幅降低延迟：通义千问填 {\"enable_thinking\": false}。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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

    /// 把一句英文翻译成每种目标语言
    private func testTranslation() {
        let settings = model.settingsStore.settings
        guard settings.translationEngine != .none else { return }
        isTesting = true
        testResult = nil
        let sample = "Hello! This is a quick test of the subtitle translator."
        let targets = settings.translationTargets
        Task { @MainActor in
            var lines: [String] = []
            do {
                for target in targets {
                    let engine: TranslationEngine
                    switch settings.translationEngine {
                    case .none:
                        continue
                    case .apple:
                        let apple = AppleTranslationEngine(source: "en", target: target)
                        try await apple.prepare()
                        engine = apple
                    case .openAICompatible:
                        engine = OpenAICompatibleTranslator(
                            config: settings.llmTranslation,
                            apiKey: model.apiKeys.translationKey,
                            targetLanguage: target,
                            temperature: settings.translationTemperature,
                            customInstructions: settings.customTranslationPrompt,
                            extraBodyJSON: settings.llmExtraBody,
                            client: URLSessionHTTPClient()
                        )
                    }
                    let result = try await engine.translate(sample, context: []) { _ in }
                    lines.append(targets.count > 1 ? "\(Languages.displayName(for: target))：\(result)" : result)
                }
                testResult = .success(lines.joined(separator: "\n"))
            } catch {
                let done = lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
                testResult = .failure(done + error.localizedDescription)
            }
            isTesting = false
        }
    }
}

/// 「同时翻译成」：主目标语言之外再选几种语言（决策 D17）
struct AdditionalTargetsPicker: View {
    let primary: String
    @Binding var selection: [String]
    let maximum: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("同时翻译成（可选，最多 \(maximum) 种）")
                Spacer()
                if !selection.isEmpty {
                    Button("清除") { selection.removeAll() }
                        .controlSize(.small)
                }
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), alignment: .leading)], alignment: .leading, spacing: 4) {
                ForEach(Languages.targets.filter { $0.code != primary }) { language in
                    Toggle(isOn: binding(for: language.code)) {
                        Text(language.name).lineLimit(1)
                    }
                    .toggleStyle(.checkbox)
                    .disabled(!selection.contains(language.code) && selection.count >= maximum)
                }
            }
            Text("每句字幕会分别翻译成这些语言，显示在主译文下方；导出的 SRT 也会包含全部译文。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func binding(for code: String) -> Binding<Bool> {
        Binding(
            get: { selection.contains(code) },
            set: { isOn in
                if isOn {
                    if !selection.contains(code), selection.count < maximum {
                        selection.append(code)
                    }
                } else {
                    selection.removeAll { $0 == code }
                }
            }
        )
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

/// 下载 / 准备进度条：已知进度时显示百分比，未知时显示不确定进度条
struct PreparationProgressView: View {
    let status: PreparationStatus?

    var body: some View {
        let message = status?.message ?? "正在准备…"
        if let fraction = status?.fraction {
            ProgressView(value: fraction) {
                Text(message).font(.caption)
            } currentValueLabel: {
                Text("\(Int((fraction * 100).rounded()))%")
                    .font(.caption)
                    .monospacedDigit()
            }
        } else {
            ProgressView {
                Text(message)
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .progressViewStyle(.linear)
        }
    }
}

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
