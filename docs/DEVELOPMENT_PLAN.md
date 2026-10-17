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
- [x] 1.4 锁定 = 鼠标穿透（`ignoresMouseEvents`）；解锁 = 可拖动、可缩放（缩放经 9.1 修复，用户实测 v1.2.0 确认）
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

- [x] 9.1 缩放修复：改用 AppKit 缩放手柄（四条边 + 四个角，带缩放光标），不受字幕内容遮挡，也不和拖动手势冲突
- [x] 9.2 多目标语言：主目标语言之外可再选最多 2 种「同时翻译成」的语言；每句分别翻译，字幕中依次显示；实时翻译、Apple 语言包检查、SRT 导出都支持多种译文
- [x] 9.3 发布 v1.2.0

**验收**：解锁后能从四边和四角拖动缩放字幕窗；同时选择两种以上目标语言时，每句字幕显示全部译文。

### 阶段 10：v1.3 用户实测反馈（2026-09-29）
> 反馈：v1.2.0 功能正常；① 识别精度仍然不够（Apple 本地识别单一语言：同音错字、人名 / 专有名词错、漏句 / 断句不对、语言判断错）；② 用 API 翻译（Ollama / LM Studio 本机模型）时字幕里出现了思维链，需要调好提示词；③ 同意新增可选的「用 AI 校对识别文字」。

- [ ] 10.1 去掉思维链：输出过滤支持成对推理标签、只有结束标签、gpt-oss 格式；流式输出在推理结束前不显示；忽略 `reasoning_content` / `reasoning` 字段（待用户实测）
- [ ] 10.2 自动关闭模型思考：按服务附加参数（Ollama / LM Studio `reasoning_effort: none` 等），用户参数优先，HTTP 400 时去掉自动参数重试；推理模型提示（待用户实测）
- [ ] 10.3 内置调好的翻译提示词：说明原文来自语音识别、只输出译文、不回答字幕里的问句；按目标语言的风格提示；「翻译场景」；术语表；提示词预览（待用户实测）
- [ ] 10.4 识别精度：「识别模式」准确优先（默认，去掉 `.fastResults`）/ 速度优先；断句放宽（停顿 1.8 秒、最长 10 秒、在停顿处切）；「专有名词」；「纠错替换」（待用户实测）
- [ ] 10.5 用 AI 校对识别文字（可选，默认关）：OpenAI 兼容翻译的主目标语言请求同时返回校正后的原文，差异过大不采用；字幕、上下文、SRT 使用校正后的原文（待用户实测）
- [x] 10.6 发布 v1.3.0

**验收**：用 Ollama / LM Studio 的思考模型翻译时，字幕不再出现任何思考文字；同一段视频在「准确优先」下错字明显减少，长句不再被切碎；专有名词、纠错替换、AI 校对生效。

### 阶段 11：软件内在线更新（2026-10-15）
> 需求：软件内在线更新。用户确认：启动时和每天自动检查，提示后一键下载、安装并自动重启；可关闭自动检查、可跳过版本；直连 GitHub；自研更新器；源码仓库保持私有，新建公开发布仓库；用自签名证书固定签名身份。

- [ ] 11.1 发布源与签名（代码已完成；自签名与跨仓库发布要等用户完成一次性配置后，由首次发布验证）：CI 按证书 SHA-1 自签名（未受信任证书、临时钥匙串加入搜索列表、`--timestamp=none`、不再 `--deep`）；额外生成 zip；发布前校验 tag 与版本、配置了证书指纹却没有证书或 `RELEASES_TOKEN` 时发布失败、在任何发布步骤之前验证 token 有效；机密只交给用到它的步骤、Action 固定到提交 SHA、打包后删除临时钥匙串；同时发布到公开仓库 `lingchenfs1/zimu-ai-releases`；手动发布不再被推送取消
- [x] 11.2 检查更新（ZimuCore）：版本比较、Release 列表解析与资产选择（zip + sha256 digest）、限流与错误提示、自动检查策略与跳过版本、下载地址白名单、暂存 App 校验、更新标记、原子交换、重启脚本 + 单元测试
- [ ] 11.3 下载与安装：下载进度与重定向白名单、SHA-256 校验、解压暂存、Bundle ID / 版本 / 最低系统 / 代码签名（同一签名）校验、运行中原子交换、重启；位置不可安装时给出指引（待用户实测）
- [ ] 11.4 界面：菜单栏面板更新提示与进度；设置「软件更新」区（自动检查开关、检查更新、更新说明、下载并安装、跳过这个版本、查看发布页面）（待用户实测）
- [x] 11.5 文档：README「在线更新」（使用 + 维护者一次性配置：发布仓库、token、自签名证书、Secrets / 变量）、发布说明
- [ ] 11.6 用户完成一次性配置后发布 v1.4.0（发布到两个仓库）

**验收**：手动安装 v1.4.0 后，发布 v1.4.1，软件内能检查、下载、安装并自动重启到 v1.4.1；音频权限保留（自签名后预期保留）；跳过版本、关闭自动检查、在 DMG 中运行时的拒绝提示都正常。

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
- SpeechAnalyzer 不需要 `SFSpeechRecognizer` 授权（只需系统录音权限）；`.fastResults` 可降低延迟但会牺牲准确度（默认不用，见 D19）；`AnalysisContext.contextualStrings` 只对 DictationTranscriber 生效，SpeechTranscriber 没有自定义词汇接口；结果流抛错后会话结束，需关闭输入流并按致命错误处理。
- `AnalyzerInputConverter` 等是 macOS 27 API，不能用；音频格式转换自己用 AVAudioConverter 做。
- 停止识别时引擎还会吐出最后的定稿结果：接收事件的运行编号（eventRunID）要在引擎停止后才失效。
- Apple 翻译在源语言与目标语言相同时（如 zh-CN → zh-Hans）直接返回原文，比较前先转成 maximalIdentifier。
- WhisperKit 与 ZimuCore 都有 `EnergyVAD` / `TextUtilities` 类型：`WhisperKitTranscriber.swift` 不能 import ZimuCore。WhisperKit 自动检测语言必须同时设 `usePrefillPrompt: true` 和 `detectLanguage: true`；分词器下载只认 `HF_ENDPOINT` 环境变量。
- WhisperKit 1.1.0 的 `WhisperKit.download` 每次都会联网检查文件，模型已完整下载时要直接用本地目录；取消下载不会抛错，需自己检查 `Task.isCancelled`。
- 多语言并行识别时，各语言识别器会对同一段音频各输出一份定稿结果：切换语言时按音频时间范围去重。
- 第一次系统音频授权会阻塞调用线程：Core Audio 的 Tap / 聚合设备操作只能在后台队列执行（D11）。
- 本机模型的聊天模板常把 `<think>` 放在提示里，模型只输出「推理…</think>译文」：过滤时只见到结束标签也要删掉之前的内容。Ollama / LM Studio 的 OpenAI 兼容接口关闭思考只认 `"reasoning_effort": "none"`（Ollama 不认 `think`）；部分「始终思考」的模型会拒绝关闭思考的参数（HTTP 400）。
- 主仓库是私有的：用户电脑上的软件读不到私有仓库的 Release（未登录下载返回 404），在线更新只能读公开发布仓库；绝不能把 token 放进软件。
- ad-hoc 签名每次构建身份都不同（DR 是 cdhash）：系统音频权限、钥匙串授权都会被当成新 App。自签名证书固定 DR（`certificate leaf = H"…"`），TCC 预计可保留；但钥匙串分区列表对没有 Team ID 的 App 仍按 cdhash 记录，每次更新后读取 API Key 仍会弹一次。
- codesign 可以用未受信任的自签名证书签名：用 SHA-1 指定身份、临时钥匙串要 `list-keychains` 加入搜索列表并 `set-key-partition-list`；不要 `add-trusted-cert`（需要交互式管理员授权）。
- 跨仓库发布 Release 不能带 `target_commitish`（提交不在目标仓库里），目标仓库要先有一个提交；GitHub 的 latest 按 created_at 排序，软件端自己取最高版本号。
- GitHub Actions 步骤的 `if:` 里不能直接用 `secrets`：在 job 级 env 里转成布尔值（`HAS_CERT: ${{ secrets.MACOS_CERTIFICATE != '' }}`，值是字符串 `'true'`）再判断；机密本身只放在用到它的步骤的 `env` / `with` 里，第三方 Action 固定到完整提交 SHA。
- 发布前只能确认 `RELEASES_TOKEN` 有效（`GET /repos/…` 返回 200），确认不了写权限（响应里的 `permissions` 反映的是用户角色，不是 token 的授权）：token 有效但没有 Contents 写权限时，仍会出现主仓库已发布、公开仓库失败的情况，按 README 授予 **Contents: Read and write**。
- `browser_download_url` 会 302 到 `release-assets.githubusercontent.com`；Info.plist 开了 `NSAllowsArbitraryLoads`，更新下载必须自己限定 https 与主机白名单。
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
| D23 | 2026-10-17 | 审查后加固在线更新：CI 机密只交给用到它的步骤（job 级只放 `HAS_CERT` / `HAS_RELEASES_TOKEN` 布尔值），Action 固定到完整提交 SHA，打包后删除临时钥匙串；配置了证书指纹变量后，没有 `RELEASES_TOKEN` 的发布也直接失败，并在任何发布步骤之前验证 token 有效；安装前重新校验暂存的新版本，签名校验放到后台线程；旧版本没能放回原处时保留暂存目录（重试一次放回）；App 旁边的后备暂存目录记在 UserDefaults 里，启动时只清理记录过的 | 自签名证书是软件内更新唯一的信任根，`RELEASES_TOKEN` 能写更新渠道，不能让无关步骤和可变标签的第三方 Action 读到；避免只发到私有仓库、或主仓库已发布而公开仓库才失败；等待确认安装可能长达数小时，暂存目录用户可写；不能在任何失败路径上删掉仅有的副本；列出桌面、外接磁盘等位置会触发系统访问提示 |
| D22 | 2026-10-15 | CI 用自签名代码签名证书（按 SHA-1 指定、`--timestamp=none`、不公证、保留 Hardened Runtime、不用 `--deep`）；证书有效期 10 年以上并离线备份；配置了证书指纹变量后，没有证书的发布直接失败 | 固定签名身份，系统音频权限预计可在更新后保留，更新器可校验同一签名；没有付费开发者账号也能做到。钥匙串每次更新弹一次授权是已知限制（无 Team ID） |
| D21 | 2026-10-15 | 自研在线更新：从公开发布仓库 `lingchenfs1/zimu-ai-releases` 的 Release 列表取最高版本；下载 zip 资产，校验大小与 GitHub sha256 digest，下载与重定向只允许 GitHub 发布地址；解压暂存后校验 Bundle ID、版本、最低系统和代码签名（当前不是 ad-hoc 时要求满足当前 App 的 DR）；在软件仍运行时用 `renamex_np(RENAME_SWAP)` 原子交换，再由小脚本等待退出后重启 | 源码仓库私有；Sparkle 需要额外 EdDSA 密钥并关闭库验证；运行中交换没有「App 不见了」的窗口，失败时软件还在、能给出手动安装的指引；zip 比挂载 DMG 简单可靠 |
| D20 | 2026-09-29 | AI 校对识别文字：只在 OpenAI 兼容翻译的主目标语言整句请求中进行，输出 `<source>…</source><translation>…</translation>`；校正结果与识别结果的归一化编辑距离超过 50% 或为空时不采用 | 不增加请求次数；防止模型改写、润色或胡编原文 |
| D19 | 2026-09-29 | 识别默认「准确优先」（SpeechTranscriber 不用 `.fastResults`），保留「速度优先」选项；断句放宽（停顿 1.8 秒、最长 10 秒、强制切分时在停顿标点处切）；SpeechTranscriber 没有词汇接口，专有名词靠识别后的「纠错替换」和 AI 校对解决 | 用户反馈识别精度不够、长句被切碎；`.fastResults` 按文档会牺牲准确度；实时草稿行照常显示，放宽断句不影响看到文字的速度 |
| D18 | 2026-09-29 | OpenAI 兼容翻译默认自动关闭模型思考：按服务地址附加参数（Ollama / LM Studio `reasoning_effort: none`、百炼 / 硅基流动 `enable_thinking: false`、智谱 / 火山方舟 `thinking.type: disabled`、OpenAI gpt-5 `reasoning_effort: minimal`、Qwen3 `/no_think`），用户额外参数优先；服务返回 HTTP 400 时去掉自动参数重试一次并在本次运行中记住；输出过滤去掉各种形式的推理内容 | 用户在本机模型上看到思维链；思考模式下字幕翻译又慢又会漏出推理；不同服务参数不同且部分模型拒绝该参数 |
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
- 2026-09-28 | 9.1 / 9.3 | 解锁提示栏（「锁定」按钮、提示标签）内缩避开四角缩放手柄；合并 PR lingchenfs1/zimu-ai#4，通过 CI 手动发布 v1.2.0（Release 附 ZimuAI-1.2.0.dmg） | 本地 SDK 类型检查、Linux `swift test`；CI；Release 页面 | 9.1、9.2 待用户实测
- 2026-09-29 | 9.1 / 9.2 | 用户实测 v1.2.0：缩放与多目标语言正常，勾选 9.1、9.2；反馈识别精度不够、API 翻译出现思维链 → 新增阶段 10 与决策 D18–D20 | 用户实测 | 阶段 10 待开发
- 2026-09-29 | 10.1–10.5 | 思维链：新增 ReasoningFilter（成对推理标签、只有结束标签、gpt-oss 格式、「译文：」前缀）和 StreamingTranslationFilter（推理结束前不显示，见过推理后按会话记住）；ThinkingControl 按服务自动关闭思考，用户参数优先，HTTP 400 去掉自动参数重试；重写翻译提示词（语音识别原文、只输出译文、不回答问句、目标语言风格）+ 翻译场景 + 术语表 + 提示词预览；识别模式（准确优先去掉 fastResults）、断句放宽并在停顿处切、专有名词、纠错替换（TextCorrections）；AI 校对（<source>/<translation> 输出、差异阈值 50%、updateOriginal）；版本号 1.3.0 (4) | 本地 macOS 26.5 SDK 类型检查零错误零警告；Linux 上 ZimuCore 109 个测试通过 | 待用户实测
- 2026-09-30 | 1.4 / 10.6 | 用户实测 v1.2.0 已确认缩放正常，勾选 1.4；用户确认后合并 PR lingchenfs1/zimu-ai#5 并通过 CI 手动发布 v1.3.0（Release 附 ZimuAI-1.3.0.dmg） | CI；Release 页面 | 10.1–10.5 待用户实测
- 2026-10-15 | 11 | 需求：软件内在线更新。调研 Sparkle 与自研方案、核实主仓库为私有；与用户确认：自研更新器 + 公开发布仓库 + 自签名证书；新增阶段 11 与决策 D21、D22 | 调研、设计审查 | 待开发
- 2026-10-15 | 11.1–11.5 | 实现软件内在线更新：ZimuCore 新增 SemanticVersion、UpdateChecker（GitHub Release 列表、zip 资产与 sha256 digest、限流）、UpdatePolicy（自动检查、跳过版本、下载地址白名单）、BundleInfo / StagedBundleValidator / InstallLocationCheck / PendingUpdateMarker、BundleSwapper（RENAME_SWAP 与两次改名后备）、ProcessRunner、重启脚本；App 新增 CodeSignature、UpdateDownloader、UpdateInstaller、AppUpdater 与菜单栏 / 设置界面；CI 按证书 SHA-1 自签名、生成 zip、发布到公开仓库；README 与 v1.4.0 发布说明；版本 1.4.0 (5) | Linux `swift test` 141 个通过；macOS 26.5 SDK 类型检查零错误零警告 | 界面、权限与安装待用户实测；需要用户完成一次性配置
- 2026-10-17 | 11（审查） | 多视角对抗式审查（安全 / 安装 / 并发 / CI / 核心 5 个视角，每条发现再由 2 个验证者复核）确认 13 个问题，按设计工作流（4 组设计 + 4 组反驳）全部修复：回滚失败不再删除仅有的副本（并重试一次放回）、安装前重新校验、签名校验移出主线程、暂存目录泄漏、下载完成后取消无效、「稍后」注释、手动检查失败丢失新版本、横幅可见性、CI 机密范围 / Action 固定 SHA / 删除钥匙串、token 缺失或失效时发布前失败、标记超过 24 小时误判、限流时间无上限、重启脚本测试可能误通过；新增决策 D23 | Linux `swift test` 143 个全部通过（重启脚本测试连跑 3 次稳定；去掉等待循环后测试能发现）；macOS 26.5 SDK 类型检查 ZimuCore / App 零错误零警告；workflow YAML 解析与每个 run 块 `bash -n` 通过 | 回滚失败、取消、等待确认时退出、更新后提示与开机启动待用户实测；11.1 待一次性配置后首次发布验证
