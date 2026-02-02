# AirRead 代码审计报告（首轮）

## 结论概览
- 关键功能链路（阅读/本地推理/问答）已具备可交付状态。
- 当前仓库存在一项会影响 Android 在“新环境/新 clone”构建的缺口：Gradle Wrapper 相关文件被忽略，且仓库内缺失。已补齐并调整忽略规则。
- `flutter analyze` 目前以大量 info 级问题（主要是 Flutter API 弃用提示）失败退出；不影响运行但会影响长期维护与 CI，建议安排一次“机械化修复”。

## 构建与发布链路
### Flutter
- `flutter test`：通过。
- `flutter analyze`：存在大量 info（弃用 API/const 建议），导致 analyze 退出码非 0；建议后续分批修复（优先处理弃用 API）。

### iOS
- 工程包含 `ios/Frameworks/MNN.xcframework`，同时具备 `ios-arm64`（真机）和 `ios-arm64-simulator`（模拟器）切片。
- 已在本机环境验证 `xcodebuild`（sim/device）可构建；`LocalMNN.framework` 在 sim/device 产物中均为 arm64 slice。

### Android
- 仓库内原本缺失 `android/gradlew` / `android/gradlew.bat` / `android/gradle/wrapper/gradle-wrapper.jar`，并且 `android/.gitignore` 明确忽略这些文件，导致在新环境中无法直接使用 Gradle Wrapper 构建。
- 本轮已补齐上述文件，并移除忽略规则（使其可被版本控制纳入）。
- 由于当前运行环境缺少 Android SDK（ANDROID_HOME 未配置），无法在此环境中实际执行 `flutter build apk` 作为最终验证；建议在具备 Android SDK 的机器上补跑一次 Debug/Release 构建。

## 本地推理（Local LLM）
- Android 侧 native 推理链路未在本轮直接改动（Kotlin/NDK 文件保持不动）。
- 跨平台共享的改动集中在 Dart 侧 prompt 与模型下载校验：属于“增强健壮性”而非破坏性变更。
- iOS 侧本地推理已通过真机/模拟器构建验证；运行时是否可用主要取决于模型文件下载完整与设备资源。

## 阅读器（Reader）
- 已对正文清洗增加对 `&nbsp;` / NBSP / 全角空格 / 零宽空格等特殊字符处理，降低“布局异常/分页异常”的概率。
- 首章（包含图片/前言/简介等不规则排版）仍可能出现极端分页体验问题；建议后续以“原始 HTML 结构”维度做更严格的首章处理（例如：识别并跳过纯图页面/将短标题节点合并成一个段落后再分页）。

## 可删除/可合并候选（建议人工确认后执行）
- `android/gradlew*` 与 `android/gradle/wrapper/gradle-wrapper.jar`：已补齐，建议纳入版本控制（不要删除）。
- Web/IO 双文件（例如 `*_web.dart`、`*_io.dart`）：通常通过条件导入使用，建议保留；如需删除需先全局确认 import 路径。

## 下一轮建议（按优先级）
1) 维护性修复：批量替换弃用 API（例如 `Color.withOpacity`）并让 `flutter analyze` 通过。
2) Android 构建链路：在有 Android SDK 的环境中跑通 `flutter build apk/appbundle`，确认 NDK/so 链接无回归。
3) 阅读首章健壮性：基于 EPUB HTML 结构做“图文混排/标题拆分”的更高层处理，而不是纯文本层面的补丁。

