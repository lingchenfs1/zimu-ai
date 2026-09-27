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
- [ ] 0.2 `.gitignore`（忽略 `*.xcodeproj`、`DerivedData`、`.build` 等）
- [ ] 0.3 `project.yml` + 菜单栏空壳 App（`LSUIElement`、Info.plist、entitlements）
- [ ] 0.4 `Packages/ZimuCore` 包 + 一个示例单元测试
- [ ] 0.5 GitHub Actions workflow（`macos-26`：xcodegen → build → test）

**验收**：CI 绿；用户在 Mac 上 `xcodegen generate` 后运行，菜单栏出现图标，可退出。

### 阶段 1：悬浮字幕窗（先用演示字幕驱动）
- [ ] 1.1 `OverlayPanel`：置顶、不抢焦点、所有桌面可见、全屏视频之上可见
- [ ] 1.2 `SubtitleView`：原文 / 译文两行，单语 / 双语显示切换
- [ ] 1.3 外观设置：背景透明度、文字透明度、字号、颜色、圆角
- [ ] 1.4 锁定 = 鼠标穿透（`ignoresMouseEvents`）；解锁 = 可拖动、可缩放
- [ ] 1.5 窗口位置 / 大小记忆
- [ ] 1.6 「演示字幕」模式：定时滚动假字幕，便于调外观

**验收**：全屏播放视频时字幕窗可见；透明度等外观设置实时生效；锁定后点击穿透到下层窗口。

### 阶段 2：系统音频捕获
- [ ] 2.1 `SystemAudioTap`：全局 Tap（排除本应用进程）
- [ ] 2.2 指定 App 捕获（列出正在发声的进程供选择）
- [ ] 2.3 权限申请与引导（首次使用、被拒绝后的提示与跳转系统设置）
- [ ] 2.4 `AudioFormatConverter`：转换为识别引擎需要的格式
- [ ] 2.5 菜单栏 / 设置里显示实时电平
- [ ] 2.6 调试功能：录制 N 秒为 WAV 文件

**验收**：播放视频时电平跳动；导出的 WAV 能正常播放且无回环。

### 阶段 3：本地语音识别（Apple SpeechAnalyzer）
- [ ] 3.1 `TranscriptionEngine` 协议（ZimuCore）：输入音频 buffer，输出草稿 / 定稿片段流
- [ ] 3.2 `AppleSpeechEngine`：源语言选择、`AssetInventory` 模型下载、草稿 / 定稿结果
- [ ] 3.3 `SubtitleSegmenter`（ZimuCore）：断句、最长时长 / 字数限制 + 单元测试
- [ ] 3.4 `PipelineController` 串起 捕获 → 识别 → 字幕窗，原文实时上屏

**验收**：播放英文视频，原文字幕延迟约 ≤1.5s，断句自然。

### 阶段 4：翻译
- [ ] 4.1 `TranslationEngine` 协议（ZimuCore）
- [ ] 4.2 `AppleTranslationEngine`：`TranslationSession(installedSource:target:)` + 语言包可用性检测与下载引导
- [ ] 4.3 `OpenAICompatibleTranslator`（ZimuCore）：Base URL / Key / Model 配置，SSE 流式解析，带上下文的翻译 prompt + 单元测试
- [ ] 4.4 设置页「测试连接」按钮
- [ ] 4.5 按 segment id 对齐译文；乱序、超时、失败时降级为只显示原文
- [ ] 4.6 目标语言选择

**验收**：两种翻译引擎都能出译文；断网时 Apple 本地引擎仍然可用。

### 阶段 5：云端语音识别
- [ ] 5.1 能量 VAD 分段 + WAV 编码（ZimuCore）+ 单元测试
- [ ] 5.2 `OpenAICompatibleSTT`：调用 `/v1/audio/transcriptions`
- [ ] 5.3 设置中切换本地 / 云端识别引擎

**验收**：切换到云端识别后字幕正常出现。

### 阶段 6：设置与体验打磨
- [ ] 6.1 完整设置窗口：通用 / 识别 / 翻译 / 外观 / 快捷键
- [ ] 6.2 `KeychainStore`：API Key 只存 Keychain
- [ ] 6.3 全局快捷键：开始 / 停止、锁定 / 解锁、显示 / 隐藏字幕
- [ ] 6.4 菜单栏状态指示 + 错误提示
- [ ] 6.5 开机启动（`SMAppService`）
- [ ] 6.6 （可选）字幕历史，导出 SRT

**验收**：全部设置可用且重启后保留；快捷键在任意 App 前台时可用。

### 阶段 7：性能、测试与发布
- [ ] 7.1 延迟 / CPU / 内存测量与优化
- [ ] 7.2 Developer ID 签名 + 公证（notarization）
- [ ] 7.3 DMG 打包，CI 自动发布 Release
- [ ] 7.4 README 使用说明（安装、权限、配置 API）

**验收**：在一台干净的 macOS 26 机器上从 DMG 安装并完整跑通。

## 5. 关键技术要点 / 已知坑

- 喂给 SpeechAnalyzer 的 buffer 必须先转换为 `SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith:)` 返回的格式；格式不符时**不会报错，但也没有任何识别结果**。
- `SpeechTranscriber` 需要指定源语言 locale，不会自动检测语言 → 设置里让用户选择源语言（云端识别可以自动检测）。
- `TranslationSession(installedSource:target:)` 只能用于**已安装**的语言对；未安装的需要在 SwiftUI 视图里用 `.translationTask` 触发系统下载对话框。
- Process Tap 必须排除本应用自身进程，避免回环。
- 悬浮窗要盖住全屏视频，需要 `.fullScreenAuxiliary` + 足够高的 window level，并使用 `.nonactivatingPanel` 避免抢焦点。
- Claude 的云端开发容器是 Linux，无法编译 macOS 代码：平台无关逻辑尽量放进 ZimuCore，编译以 GitHub Actions 为准。

## 6. 决策记录

| 编号 | 日期 | 决策 | 理由 |
|---|---|---|---|
| D1 | 2026-09-27 | 最低支持 macOS 26 (Tahoe) | 可直接用 SpeechAnalyzer 和无 UI 的 TranslationSession，代码最简单 |
| D2 | 2026-09-27 | 本地识别用 SpeechAnalyzer，云端识别用 OpenAI 兼容接口 | 本地免费、隐私好、低延迟；云端可接入多家服务 |
| D3 | 2026-09-27 | 翻译同时支持 Apple 本地 Translation + OpenAI 兼容服务 | 用户要求；本地离线可用，大模型翻译质量高 |
| D4 | 2026-09-27 | 系统音频用 Core Audio Process Tap | 只需"系统录音"权限，可按 App 捕获，不需要屏幕录制权限 |
| D5 | 2026-09-27 | XcodeGen + ZimuCore 本地包 + GitHub Actions macos-26 | 工程文件纯文本易维护；纯逻辑可测试；云端容器无法编译 macOS 代码 |

## 7. 进度日志

> 格式：`日期 | 任务编号 | 做了什么 | 如何验证 | 遗留问题`

- 2026-09-27 | 0.1 | 制定开发计划，建立 `CLAUDE.md` + `docs/DEVELOPMENT_PLAN.md` 长期记忆 | 文档审阅 | 无
