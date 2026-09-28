# 字幕AI（zimu-ai）开发计划

> 这是项目的**长期记忆**。每次开始任务前先读这里，完成后更新勾选状态和「进度日志」。
> 规则详见根目录 `CLAUDE.md`。

## 0. 项目目标

一个 macOS 菜单栏应用：自动捕获 Mac 本地正在播放的音频 → 语音识别 → AI 翻译成指定语言 →
以**可调透明度的悬浮窗**显示在屏幕上（类似影片的外挂字幕）。

- 最低系统：**macOS 26 (Tahoe)+**
- 语音识别：**本地优先**（Apple SpeechAnalyzer），可切换**云端**（OpenAI 兼容接口）
- 翻译：**Apple 本地 Translation 框架** + **任意 OpenAI 兼容服务**（OpenAI / DeepSeek / 通义 / Ollama 等）
- 性能目标：原文字幕延迟约 ≤1.5s；译文在一句话结束后约 ≤3s 出现

## 1. 技术选型

| 模块 | 方案 |
|---|---|
| 语言 / UI | Swift 6（严格并发）+ SwiftUI + AppKit（NSPanel），Xcode 26 |
| 工程 | XcodeGen `project.yml` 生成 `.xcodeproj`（不提交）+ 本地 Swift Package `Packages/ZimuCore`（纯逻辑 + 单元测试） |
| 应用形态 | `MenuBarExtra` 菜单栏应用 + `Settings` 设置窗口，`LSUIElement=YES`（无 Dock 图标） |
| 系统音频捕获 | Core Audio Process Tap：`CATapDescription`（全局并排除自身 / 指定 App）+ `AudioHardwareCreateProcessTap` + 聚合设备 + IOProc。Info.plist 需 `NSAudioCaptureUsageDescription`，只需"系统录音"权限，不需要屏幕录制权限 |
| 语音识别（本地，默认） | `SpeechAnalyzer` + `SpeechTranscriber`，`reportingOptions: [.volatileResults]` 出实时草稿，`attributeOptions: [.audioTimeRange]` 出时间戳；`AssetInventory` 下载语言模型 |
| 语音识别（云端） | OpenAI 兼容 `POST /v1/audio/transcriptions`（Base URL / Key / Model 可配），VAD 分段后上传 |
| 翻译（本地） | Apple Translation：macOS 26 的 `TranslationSession(installedSource:target:)` 可脱离 SwiftUI 使用；语言包未安装时通过 SwiftUI `.translationTask` 触发系统下载 |
| 翻译（云端） | OpenAI 兼容 `POST /v1/chat/completions`，SSE 流式输出，prompt 带前几句上下文 |
| 悬浮字幕窗 | `NSPanel`（borderless + `.nonactivatingPanel`），level `.screenSaver`（盖住全屏视频），`collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]`，内容用 `NSHostingView` 承载 SwiftUI |
| 存储 | 普通设置 → UserDefaults / `@AppStorage`；API Key → Keychain |
| CI | GitHub Actions `macos-26` runner：xcodegen → xcodebuild build → ZimuCore 测试 |

## 2. 架构（数据流）

```
SystemAudioTap              (Core Audio Process Tap，48kHz 立体声 Float32)
  → AudioFormatConverter    (AVAudioConverter → 识别引擎所需格式)
  → TranscriptionEngine     协议：AppleSpeechEngine | OpenAICompatibleSTT
                            输出：草稿(volatile) + 定稿(final) 片段，带时间戳
  → SubtitleSegmenter       (断句、最长时长 / 最多字数限制)
  → TranslationEngine       协议：AppleTranslationEngine | OpenAICompatibleTranslator
                            只翻译定稿句；按 segment id 对齐；超时 / 失败降级为只显示原文
  → SubtitleStore           (@Observable：当前行、上一行、原文 / 译文)
  → OverlayPanel            (SwiftUI 渲染字幕)

PipelineController 统一管理：启动 / 停止 / 引擎切换 / 错误状态
```

## 3. 目录结构（规划）

```
zimu-ai/
├── CLAUDE.md                   # 长期记忆入口：工作规则
├── README.md
├── project.yml                 # XcodeGen 工程定义
├── docs/DEVELOPMENT_PLAN.md    # 本文件
├── App/                        # macOS App target（依赖 Apple 平台框架的代码）
│   ├── ZimuAIApp.swift         # MenuBarExtra + Settings
│   ├── Info.plist
│   ├── ZimuAI.entitlements
│   ├── Audio/                  # SystemAudioTap, AudioFormatConverter
│   ├── Speech/                 # AppleSpeechEngine, OpenAICompatibleSTT
│   ├── Translation/            # AppleTranslationEngine
│   ├── Overlay/                # OverlayPanel, SubtitleView
│   ├── Settings/               # SettingsView, KeychainStore
│   └── Pipeline/               # PipelineController, SubtitleStore
├── Packages/ZimuCore/          # 纯 Swift 逻辑，可单元测试
│   ├── Sources/ZimuCore/       # 引擎协议、SubtitleSegmenter、Prompt 构建、
│   │                           # OpenAI 兼容客户端与 SSE 解析、设置模型
│   └── Tests/ZimuCoreTests/
└── .github/workflows/build.yml
```

## 4. 阶段与任务

> 标记说明：`[x]` 已完成；`[ ]` 未完成；`（待用户实测）` 表示代码已完成但需用户在 Mac 上确认后才能勾选。

### 阶段 0：工程骨架与长期记忆
- [x] 0.1 制定开发计划，建立 `CLAUDE.md` + `docs/DEVELOPMENT_PLAN.md` 长期记忆
- [x] 0.2 `.gitignore`（忽略 `*.xcodeproj`、`DerivedData`、`.build` 等）
- [x] 0.3 `project.yml` + 菜单栏空壳 App（`LSUIElement`、Info.plist、entitlements）
- [x] 0.4 `Packages/ZimuCore` 包 + 一个示例单元测试
- [x] 0.5 GitHub Actions workflow（`macos-26`：xcodegen → build → test）

**验收**：CI 绿；用户在 Mac 上 `xcodegen generate` 后运行，菜单栏出现图标，可退出。

### 阶段 1：悬浮字幕窗（先用演示字幕驱动）
- [x] 1.1 `OverlayPanel`：置顶、不抢焦点、所有桌面可见、全屏视频之上可见
- [x] 1.2 `SubtitleOverlayView`：原文 / 译文两行，单语 / 双语显示切换
- [x] 1.3 外观设置：背景透明度、文字透明度、字号、颜色、圆角
- [ ] 1.4 锁定 = 鼠标穿透（`ignoresMouseEvents`）；解锁 = 可拖动、可缩放（用户实测：锁定与拖动正常，缩放失败 → 见 9.1）
- [x] 1.5 窗口位置 / 大小记忆
- [x] 1.6 「演示字幕」模式：定时滚动假字幕，便于调外观

**验收**：全屏播放视频时字幕窗可见；透明度等外观设置实时生效；锁定后点击穿透到下层窗口。

### 阶段 2：系统音频捕获
- [x] 2.1 `SystemAudioCapture`：全局 Tap（排除本应用进程）
- [x] 2.2 指定 App 捕获（列出正在发声的进程供选择）
- [x] 2.3 权限申请与引导（首次使用、被拒绝后的提示与跳转系统设置）
- [x] 2.4 `AudioFormatConverter`：转换为识别引擎需要的格式
- [x] 2.5 菜单栏 / 设置里显示实时电平
- [x] 2.6 调试功能：录制 10 秒为 WAV 文件（设置 › 通用）

**验收**：播放视频时电平跳动；导出的 WAV 能正常播放且无回环。

### 阶段 3：本地语音识别（Apple SpeechAnalyzer）
- [x] 3.1 `TranscriptionEngine` 协议（App 层，见 D7）+ `TranscriptEvent`（ZimuCore）：输入音频 buffer，输出草稿 / 定稿片段
- [x] 3.2 `AppleSpeechEngine`：源语言选择、`AssetInventory` 模型下载、草稿 / 定稿结果
- [x] 3.3 `SubtitleSegmenter`（ZimuCore）：断句、最长时长 / 字数限制 + 单元测试
- [x] 3.4 `PipelineController` 串起 捕获 → 识别 → 字幕窗，原文实时上屏

**验收**：播放英文视频，原文字幕延迟约 ≤1.5s，断句自然。

### 阶段 4：翻译
- [x] 4.1 `TranslationEngine` 协议（ZimuCore）
- [x] 4.2 `AppleTranslationEngine`：`TranslationSession(installedSource:target:)` + 语言包可用性检测与下载引导
- [x] 4.3 `OpenAICompatibleTranslator`（ZimuCore）：Base URL / Key / Model 配置，SSE 流式解析，带上下文的翻译 prompt + 单元测试
- [x] 4.4 设置页「测试翻译 / 测试连接」按钮
- [x] 4.5 按 segment id 对齐译文；积压时丢弃旧句、失败时降级为只显示原文（SubtitleTimeline 单元测试覆盖）
- [x] 4.6 目标语言选择

**验收**：两种翻译引擎都能出译文；断网时 Apple 本地引擎仍然可用。

### 阶段 5：云端语音识别
- [x] 5.1 能量 VAD 分段 + WAV 编码（ZimuCore）+ 单元测试
- [x] 5.2 `OpenAICompatibleSTTEngine`：调用 `/v1/audio/transcriptions`
- [x] 5.3 设置中切换本地 / 云端识别引擎

**验收**：切换到云端识别后字幕正常出现。

### 阶段 6：设置与体验打磨
- [x] 6.1 完整设置窗口：通用 / 识别 / 翻译 / 外观 / 快捷键
- [x] 6.2 `APIKeyStore` / `Keychain`：API Key 只存钥匙串
- [x] 6.3 全局快捷键 ⌃⌥S / ⌃⌥L / ⌃⌥H（Carbon，无需辅助功能权限）
- [x] 6.4 菜单栏状态指示、电平 + 错误提示
- [x] 6.5 开机启动（`SMAppService`）
- [x] 6.6 字幕历史，导出 SRT（格式化有单元测试）

**验收**：全部设置可用且重启后保留；快捷键在任意 App 前台时可用。

### 阶段 7：性能、测试与发布
- [ ] 7.1 延迟 / CPU / 内存测量与优化（需要在真机上测量）
- [x] 7.2 Developer ID 签名 + 公证流程（CI 中配置 Secrets 后自动启用；未配置时本地签名）
- [x] 7.3 DMG 打包（`scripts/package_dmg.sh`），CI 上传 DMG 产物，推送 `v*` 标签或手动触发 CI 并填写 `release_tag` 发布 Release；App 图标
- [x] 7.4 README 使用说明（安装、权限、配置 API）

**验收**：在一台干净的 macOS 26 机器上从 DMG 安装并完整跑通。

### 阶段 8：v1.1 用户实测反馈（2026-09-27）
> 反馈：① 翻译速度跟不上识别（Apple 本地翻译）；② 第一次请求权限时卡住；③ 菜单栏「退出」无法关闭软件；④ 需要同时识别多种语言、自动判断原声语言（三种方案都做，设置中切换）。

- [x] 8.1 权限卡住：音频捕获的创建 / 启动 / 停止移到后台线程，等待授权时界面不冻结并显示提示
- [x] 8.2 退出：退出前在后台停止音频捕获（带超时），`applicationShouldTerminate` 延迟退出，超时兜底强制退出
- [x] 8.3 翻译提速：识别中的文字实时翻译（节流）、句子提交时复用实时译文、翻译并发 + Apple 批量翻译、积压时丢弃最旧
- [x] 8.4 多语言方案一：Apple 多语言并行识别，按识别置信度自动切换（候选 2～4 种语言）
- [x] 8.5 多语言方案二：WhisperKit 本地识别引擎，自动检测语言，模型下载支持镜像地址
- [x] 8.6 多语言方案三：云端识别「自动检测」入口；识别结果携带语言，翻译按识别出的语言选择源语言
- [x] 8.7 设置界面：识别引擎四选一及各自设置；翻译增加「实时翻译」「并发数」「额外请求参数」
- [x] 8.8 下载进度条：Apple 语音模型、WhisperKit 模型在设置页和菜单栏面板显示进度条；Apple 翻译语言包下载时显示进行中状态（系统不提供具体进度）
- [x] 8.9 合并 PR lingchenfs1/zimu-ai#3 并发布 v1.1.0（用户反馈 Release 中的 v1.0.0 没有新功能）

**验收**：Apple 本地翻译时译文与原文基本同步；首次授权不卡顿；菜单栏退出立即生效；三种多语言方案都能在中英日混合内容上自动切换语言。

### 阶段 9：v1.2 用户实测反馈（2026-09-28）
> 反馈：v1.1.0 功能测试正常；① 拖动缩放字幕窗大小失败；② 希望能同时翻译成多种语言。

- [ ] 9.1 缩放修复：改用 AppKit 缩放手柄（四条边 + 四个角，带缩放光标），不受字幕内容遮挡，也不和拖动手势冲突（待用户实测）
- [ ] 9.2 多目标语言：主目标语言之外可再选最多 2 种「同时翻译成」的语言；每句分别翻译，字幕中依次显示；实时翻译、Apple 语言包检查、SRT 导出都支持多种译文（待用户实测）
- [ ] 9.3 发布 v1.2.0

**验收**：解锁后能从四边和四角拖动缩放字幕窗；同时选择两种以上目标语言时，每句字幕显示全部译文。

## 5. 关键技术要点 / 已知坑

- 喂给 SpeechAnalyzer 的 buffer 必须先转换为 `SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith:)` 返回的格式；格式不符时**不会报错，但也没有任何识别结果**。
- `SpeechTranscriber` 需要指定源语言 locale，不会自动检测语言 → 设置里让用户选择源语言（云端识别可以自动检测）。
- `TranslationSession(installedSource:target:)` 只能用于**已安装**的语言对；未安装的需要在 SwiftUI 视图里用 `.translationTask` 触发系统下载对话框。
- Process Tap 必须排除本应用自身进程，避免回环。
- 悬浮窗要盖住全屏视频，需要 `.fullScreenAuxiliary` + 足够高的 window level，并使用 `.nonactivatingPanel` 避免抢焦点。
- Claude 的云端开发容器是 Linux，无法编译 macOS 代码：平台无关逻辑尽量放进 ZimuCore，编译以 GitHub Actions 为准。
- 悬浮窗 `canBecomeKey = false`（不抢键盘焦点），因此内容视图要重写 `acceptsFirstMouse` 才能直接响应点击和拖动。
- 系统音频权限被拒绝时，Process Tap 不会报错，只会收到静音数据 → 通过电平表和「录制 10 秒测试」来排查。
- 同一次运行中字幕 id 单调递增（`SubtitleTimeline.reset()` 不重置 id），避免上一轮迟到的译文写到新字幕上。
- 聚合设备优先只包含 Tap（参考 audiotee），不把输出设备加进来：带麦克风的输出设备（耳机、AirPods）会让聚合设备多出输入流并可能激活麦克风；失败时才退回 AudioCap 的「输出设备 + Tap」方式，并在回调中只取最后的 Tap buffer。
- 不要把 `kAudioObjectUnknown` 放进 Tap 的排除列表，否则 `AudioHardwareCreateProcessTap` 返回 560947818，看起来像权限被拒。
- SpeechAnalyzer 不需要 `SFSpeechRecognizer` 授权（只需系统录音权限）；`.fastResults` 可降低延迟；结果流抛错后会话结束，需关闭输入流并按致命错误处理。
- `AnalyzerInputConverter` 等是 macOS 27 API，不能用；音频格式转换自己用 AVAudioConverter 做。
- 停止识别时引擎还会吐出最后的定稿结果：接收事件的运行编号（eventRunID）要在引擎停止后才失效。
- Apple 翻译在源语言与目标语言相同时（如 zh-CN → zh-Hans）直接返回原文，比较前先转成 maximalIdentifier。
- WhisperKit 与 ZimuCore 都有 `EnergyVAD` / `TextUtilities` 类型：`WhisperKitTranscriber.swift` 不能 import ZimuCore。WhisperKit 自动检测语言必须同时设 `usePrefillPrompt: true` 和 `detectLanguage: true`；分词器下载只认 `HF_ENDPOINT` 环境变量。
- WhisperKit 1.1.0 的 `WhisperKit.download` 每次都会联网检查文件，模型已完整下载时要直接用本地目录；取消下载不会抛错，需自己检查 `Task.isCancelled`。
- 多语言并行识别时，各语言识别器会对同一段音频各输出一份定稿结果：切换语言时按音频时间范围去重。
- 第一次系统音频授权会阻塞调用线程：Core Audio 的 Tap / 聚合设备操作只能在后台队列执行（D11）。
- 浏览器的声音通常来自子进程（如 `com.google.Chrome.helper`、Safari 的 `com.apple.WebKit.GPU`），指定应用捕获时按 bundle ID 前缀匹配；Safari 请在列表中选择 WebKit 进程或直接用「全部系统音频」。

## 6. 决策记录

| 编号 | 日期 | 决策 | 理由 |
|---|---|---|---|
| D1 | 2026-09-27 | 最低支持 macOS 26 (Tahoe) | 可直接用 SpeechAnalyzer 和无 UI 的 TranslationSession，代码最简单 |
| D2 | 2026-09-27 | 本地识别用 SpeechAnalyzer，云端识别用 OpenAI 兼容接口 | 本地免费、隐私好、低延迟；云端可接入多家服务 |
| D3 | 2026-09-27 | 翻译同时支持 Apple 本地 Translation + OpenAI 兼容服务 | 用户要求；本地离线可用，大模型翻译质量高 |
| D4 | 2026-09-27 | 系统音频用 Core Audio Process Tap | 只需"系统录音"权限，可按 App 捕获，不需要屏幕录制权限 |
| D5 | 2026-09-27 | XcodeGen + ZimuCore 本地包 + GitHub Actions macos-26 | 工程文件纯文本易维护；纯逻辑可测试；云端容器无法编译 macOS 代码 |
| D6 | 2026-09-27 | App target 使用 Swift 5 语言模式（Swift 6.2 编译器），ZimuCore 保持 Swift 6 严格并发 | 云端容器无法本地编译，Swift 6 模式的并发报错只能靠 CI 反复试；且 Swift 6 模式会对音频回调等 C 回调插入运行时隔离断言，容易在音频线程崩溃。平台代码自行保证线程安全（音频类标注 nonisolated / 专用队列） |
| D7 | 2026-09-27 | `TranscriptionEngine` 协议放在 App 层（依赖 AVAudioPCMBuffer），`TranscriptEvent` 等数据类型放 ZimuCore；`TranslationEngine` 协议放 ZimuCore | 识别引擎输入是 AVFoundation 类型，ZimuCore 保持不依赖 Apple 专有框架 |
| D17 | 2026-09-28 | 多目标语言：保留原 `targetLanguage` 作为主目标语言，新增 `additionalTargetLanguages`（最多 2 种）；每种目标语言各建一个翻译引擎实例；`SubtitleEntry` 改为按目标语言保存译文与状态（保留主语言的便捷属性） | 兼容旧设置与现有代码；各目标语言独立翻译、互不阻塞 |
| D16 | 2026-09-28 | 字幕窗缩放改用 AppKit 手柄视图（覆盖在 SwiftUI 内容之上，处理 mouseDown/mouseDragged 并设置缩放光标），不再用 SwiftUI 手势 | SwiftUI 缩放角标会被字幕背景遮挡、与整窗拖动手势冲突，用户实测缩放失败 |
| D15 | 2026-09-27 | `TranscriptEvent.final` 携带语言代码；`TranslationEngine.translate` 增加 `sourceLanguage`，并支持批量翻译 | 多语言识别时翻译需要知道每句的源语言；Apple 翻译批量接口更快 |
| D14 | 2026-09-27 | 引入第三方依赖 WhisperKit（SPM），模型运行时从 HuggingFace 下载，可配置镜像地址 | 用户要求本地自动识别语言；Apple 识别无语言检测能力 |
| D13 | 2026-09-27 | 多语言三种方案并存、设置中切换：Apple 多识别器并行 + 置信度切换 / WhisperKit / 云端自动检测 | 用户要求三种都做；各有取舍（离线与延迟、语言覆盖、依赖与算力） |
| D12 | 2026-09-27 | 翻译提速：对识别中的文字节流实时翻译并在提交时复用；翻译队列支持并发与批量；积压时丢弃最旧 | 用户反馈 Apple 本地翻译跟不上；原方案只在整句定稿后逐句串行翻译 |
| D11 | 2026-09-27 | Core Audio 的 Tap / 聚合设备创建、启动、停止都放在后台队列执行 | 首次使用时系统授权弹窗会阻塞调用线程，放在主线程会让整个应用卡住（也导致无法退出） |
| D10 | 2026-09-27 | 发布也可以通过手动触发 CI（`workflow_dispatch` 填 `release_tag`）完成，由 CI 创建标签和 Release | Claude 云端会话只能推送到指定分支，推送标签会被拒绝（HTTP 403）；本地推送 `v*` 标签的方式仍然可用 |
| D9 | 2026-09-27 | 识别引擎的 prepare / start / stop 统一在 MainActor 上执行，append 可在任意线程 | 避免启动与停止交错时在多个线程读写引擎状态 |
| D8 | 2026-09-27 | 允许任意 HTTP 地址（`NSAllowsArbitraryLoads`），设置窗口由自己管理的 NSWindow 承载 | 支持局域网 / 本机 Ollama 等 http 服务；菜单栏应用打开 SwiftUI Settings 场景时窗口不易置前 |

## 7. 进度日志

> 格式：`日期 | 任务编号 | 做了什么 | 如何验证 | 遗留问题`

- 2026-09-27 | 0.1 | 制定开发计划，建立 `CLAUDE.md` + `docs/DEVELOPMENT_PLAN.md` 长期记忆 | 文档审阅 | 无
- 2026-09-27 | 0.2–0.5 | .gitignore、project.yml、Info.plist / entitlements、菜单栏空壳、ZimuCore 包、CI workflow | CI（macos-26，Xcode 26）生成工程 + 测试 + 构建全部通过 | 菜单栏图标需用户在 Mac 上实测
- 2026-09-27 | 3.3 / 4.3 / 5.1（提前） | ZimuCore 纯逻辑：SubtitleSegmenter、SubtitleTimeline、OpenAI 兼容翻译 / 识别客户端、SSE 解析、EnergyVAD、WAV、SRT、设置模型 + 单元测试 | CI `swift test` | App 层接入在对应阶段完成
- 2026-09-27 | 1.1–1.6 | 悬浮字幕窗、外观设置、锁定穿透、拖动缩放、位置记忆、演示字幕、菜单栏面板 | CI 构建通过 | 待用户实测（全屏视频之上是否可见、点击穿透）
- 2026-09-27 | 2.x / 3.x / 4.x / 5.x / 6.x | 系统音频捕获（Process Tap）、Apple 识别 / 翻译引擎、云端识别、流水线、完整设置、钥匙串、快捷键、开机启动、SRT 导出 | CI 构建通过（无警告），ZimuCore 46 个单元测试通过 | 待用户实测：权限弹窗、识别效果与延迟、翻译语言包下载
- 2026-09-27 | 2.1 / 3.2 / 3.4 / 4.2 / 6.5 | 按 SDK 核实与代码审查修复：Tap-only 聚合设备、输入 buffer 数不匹配、.fastResults、停止时保留最后结果、翻译队列代数、启停交错、致命识别错误、同语言翻译、开机启动错误提示、自动检测与 Apple 识别冲突 | CI 构建 | 待用户实测
- 2026-09-27 | 7.2–7.4 | App 图标、DMG 打包脚本、CI 产出 DMG / Release、可选签名公证、README 使用说明 | CI 打包步骤 | 7.1 性能测量需真机；Developer ID 需用户提供证书
- 2026-09-27 | 7.3 | 发布 v1.0.0：合并 PR lingchenfs1/zimu-ai#1 到 main，推送 `v1.0.0` 标签，由 CI 构建 DMG 并创建 GitHub Release（发布说明见 `docs/releases/v1.0.0.md`） | Release 工作流结果与 Release 页面 | 未签名公证；所有「待用户实测」项仍需真机确认
- 2026-09-27 | 7.3 | PR 已合并（a91a794）；会话推送标签被拒（403），改为给 CI 增加手动发布入口（D10），合并后触发 `release_tag=v1.0.0` | Release 工作流结果与 Release 页面 | 同上
- 2026-09-27 | 7.3 | v1.0.0 已发布（Release 附 ZimuAI-1.0.0.dmg） | Release 页面 | 无
- 2026-09-27 | 8.1–8.7 | 实测反馈改进：音频捕获后台启动 + 授权提示；退出前停止捕获 + 兜底退出；实时翻译 + 复用 + 批量 / 并发调度；Apple 多语言并行识别（LanguageSelector）；WhisperKit 引擎（argmax-oss-swift 1.1.0）；识别结果带语言；设置界面四种引擎；版本号 1.1.0 | 本地用 macOS 26.5 SDK 类型检查（含真实 WhisperKit 源码）零错误零警告；ZimuCore 新增单元测试；CI | 全部待用户实测
- 2026-09-27 | 8.3–8.5 | 按代码审查修复：流式中的实时译文不再被当作整句译文复用；WhisperKit 已下载时离线加载、并发加载去重；多语言切换时按音频时间去重，当前语言长时间无结果时衰减得分；未知语言的句子不合并批量、Apple 批量翻译按语言分组；Apple 翻译请求串行化；翻译提示清除、任务表泄漏、下载进度覆盖状态 | 本地 SDK 类型检查零错误零警告；新增单元测试 | 待用户实测
- 2026-09-28 | 8.8 / 8.9 | 用户反馈 Release 中的 v1.0.0 没有新功能（v1.1.0 尚未发布），并要求下载模型 / 语言包时显示进度条：新增 PreparationStatus（文字 + 进度），设置页与菜单栏面板显示进度条，翻译语言包下载显示进行中；随后合并 PR lingchenfs1/zimu-ai#3 并通过 CI 手动发布 v1.1.0 | 本地 SDK 类型检查；CI；Release 页面 | 进度条待用户实测
- 2026-09-28 | 1.x–8.x | 用户实测 v1.1.0：功能正常，勾选此前「待用户实测」的各项；缩放字幕窗失败（1.4 未勾选，转 9.1） | 用户实测 | 9.1、9.2 待开发
- 2026-09-28 | 9.1 | 缩放修复：悬浮窗根视图改为 OverlayContainerView（SwiftUI 字幕 + 四边四角的 AppKit ResizeHandleView，带系统缩放光标），缩放几何放入 ZimuCore（OverlayGeometry + 单测）；SwiftUI 右下角按钮只保留为提示图标 | 本地 macOS 26.5 SDK 类型检查零错误零警告；Linux 上 `swift test` 全部通过 | 待用户实测
- 2026-09-28 | 9.2 | 多目标语言：设置新增 additionalTargetLanguages（最多 2 种）+ translationTargets；时间线按目标语言保存译文和实时译文；TranslationJob 带目标语言，调度器按目标语言限流、分批；流水线每种目标语言一个翻译引擎，实时翻译并行；字幕窗依次显示多种译文；SRT 导出全部译文；设置页「同时翻译成」多选、每种语言单独显示 Apple 语言包状态、测试翻译覆盖全部语言；演示字幕可预览多语样式；版本号 1.2.0 (3) | 同上（ZimuCore 76 个测试通过） | 待用户实测
