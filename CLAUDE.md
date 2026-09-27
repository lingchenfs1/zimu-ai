# CLAUDE.md — 字幕AI（zimu-ai）

macOS 26+ 菜单栏应用：捕获 Mac 本地播放的音频 → 语音识别 → AI 翻译 → 以可调透明度的悬浮窗显示字幕。

开发计划与进度（长期记忆）：@docs/DEVELOPMENT_PLAN.md

## 工作流规则（必须遵守）

1. **开始任何任务前**，先重新阅读 `docs/DEVELOPMENT_PLAN.md`，确认当前所处阶段、下一个未完成任务及其验收标准；只做该任务范围内的事。
2. **完成一个任务后**，在计划中勾选对应 checkbox，并在「进度日志」追加一行：日期 | 任务编号 | 做了什么 | 如何验证 | 遗留问题。
3. **技术方案需要变更时**，先在「决策记录」追加一条（日期、决策、理由），再改代码。
4. 需要在真机 Mac 上验证的项（UI、权限、音频、识别效果等），代码完成后标注「（待用户实测）」，用户确认后才勾选。一个阶段的验收标准全部通过后，才进入下一阶段。
5. 回复用户时说明：本步做了什么、对应计划中的哪一项、下一步是什么。

## 环境约束

- Claude 的云端开发容器是 **Linux**，无法编译或运行 Swift macOS 代码。推送后以 GitHub Actions（`macos-26` runner，Xcode 26）的构建结果为准；界面、权限、音频类功能由用户在 Mac 上实测。
- 与平台无关的逻辑（断句、Prompt 构建、OpenAI 兼容客户端、SSE 解析、VAD 等）尽量放进 `Packages/ZimuCore`，并配单元测试。

## 代码约定

- ZimuCore 使用 Swift 6 严格并发；App target 使用 Swift 5 语言模式（决策 D6）。UI 相关类型标注 `@MainActor`，音频回调在专用队列上处理，不要在音频线程访问 MainActor 状态。
- 依赖 Apple 平台框架的代码放 `App/`，可测试的纯逻辑放 `Packages/ZimuCore`。
- `.xcodeproj` 由 XcodeGen 从 `project.yml` 生成，不提交到仓库。
- API Key 只存 Keychain，绝不写进代码、日志或提交记录。
- 识别 / 翻译引擎都通过协议抽象（`TranscriptionEngine` / `TranslationEngine`），新增引擎不改动流水线。

## 常用命令（在 Mac 上）

```bash
brew install xcodegen
xcodegen generate                                   # 生成 ZimuAI.xcodeproj
open ZimuAI.xcodeproj
xcodebuild -project ZimuAI.xcodeproj -scheme ZimuAI build
swift test --package-path Packages/ZimuCore         # 运行核心逻辑单元测试
```
