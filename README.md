# AirRead（灵阅）

AirRead 是一个基于 Flutter 的 AI 辅助电子书阅读器，覆盖 Android / iOS / 桌面 / Web。它提供稳定的 EPUB/TXT 阅读体验，并将翻译、伴读问答与朗读能力整合到阅读流程中。

![Platform](https://img.shields.io/badge/Platform-Android%20|%20iOS%20|%20Windows%20|%20Linux%20|%20Web-blue)
![Flutter](https://img.shields.io/badge/Flutter-%3E%3D3.22.0-02569B)
![License](https://img.shields.io/badge/License-MIT-green)

---

## 功能概览

- 阅读体验：支持 EPUB/TXT，主题与字体设置，GBK 编码自动识别
- 书架与导入：文件导入、书架管理、阅读进度与本地存储
- 翻译：沉浸式翻译（机器翻译 / 大模型翻译），支持队列与缓存，适配阅读场景
- 伴读问答：基于“当前阅读上下文”的问答与章节能力（如总结、提取要点）
- 朗读：支持在线朗读（腾讯云 TTS）、iOS/Android 设备自带朗读（系统 TTS）与 Web 本地朗读（浏览器 SpeechSynthesis），并提供朗读调度/预取能力
- 本地大模型（实验）：iOS/Android 端集成 MNN LLM，模型下载后可离线推理
- 凭据与安全：支持直连（个人密钥）与代理（Serverless/自建服务）两种调用方式

## 平台与限制

- 提示：目前仅对 Android 与 iOS 的部分机型做了测试；其它平台尚未充分测试，某些功能可能存在差异，敬请谅解。
- Android：仓库配置仅打包 `arm64-v8a`（不支持 x86 模拟器）
- iOS：本地大模型仅支持 arm64 设备/模拟器；Intel 模拟器不支持本地模型
- Web：本地朗读依赖浏览器 SpeechSynthesis，受浏览器策略/音色可用性影响（部分浏览器需要用户交互触发才会出声）；本地大模型推理暂不支持（AI 设置中本地模型选项不可选）

---

## 🚀 快速上手 (Quick Start for Mobile)

如果你想快速将 AirRead 安装到你的 Android 或 iOS 手机上，请按照以下步骤操作。

### 1. 环境准备 (Prerequisites)

确保你的开发环境已安装：
*   **Flutter SDK**: 版本 `>= 3.22.0`
*   **Dart SDK**: 配套版本
*   **Android Studio / VS Code** (用于开发) 和 **Xcode** (用于 iOS 开发，仅限 macOS)
*   **CocoaPods**: iOS 开发必需 (`sudo gem install cocoapods`)

### 2. 获取代码

```bash
git clone https://github.com/lijiahao66666/AirRead.git
cd AirRead
flutter pub get
```

### 3. 配置 API 密钥 (重要)
AirRead 的在线 AI 能力（大模型问答/翻译、在线 TTS 等）依赖腾讯云服务。你可以选择 **快速体验模式** 或 **安全部署模式**。

#### 🅰️ 快速体验模式 (推荐开发者个人使用)
直接在 App 设置中输入密钥，无需部署后端。

1.  注册 [腾讯云账号](https://cloud.tencent.com/) 并开通 **混元大模型** ，**语音合成 (TTS)** 和 **腾讯机器翻译** 服务。
2.  获取你的 `SecretId` 和 `SecretKey` ([访问密钥控制台](https://console.cloud.tencent.com/cam/capi))。
3.  编译并运行 App (见下文)。
4.  打开 App，进入 **设置 -> API 设置**，填入你的 `SecretId` 和 `SecretKey` 即可立即使用。

#### 🅱️ 安全部署模式 (推荐公开分发使用)
如果你计划将 App 分发给他人使用，建议通过代理服务隐藏密钥，并在编译时注入代理地址。
*请参考后文的 [☁️ 代理与后端](#代理与后端-server-proxy) 章节。*

---

### 4. 编译与运行 (Run on Device)

⚠️ **注意**：由于集成了 MNN 本地大模型库，本项目仅支持 **ARM64 架构** 的设备。
*   **Android**: 请使用 **真机** 或 **ARM64 模拟器** (如 Apple Silicon Mac 上的模拟器)。不支持传统的 x86 Android 模拟器。
*   **iOS**: 仅支持 **真机** (需签名) 或 **ARM64 模拟器**。

#### 🤖 Android

1.  开启手机的 **开发者模式** 并启用 **USB 调试**。
2.  连接手机到电脑。
3.  运行命令：
    ```bash
    flutter run
    ```
    Release 打包请参考下文的 [📦 打包发布](#-打包发布-release-build)。

#### 🍎 iOS

1.  进入 iOS 目录安装依赖：
    ```bash
    cd ios
    pod install
    cd ..
    ```
2.  使用 Xcode 打开 `ios/Runner.xcworkspace`。
3.  配置签名 (Signing)：
    *   点击左侧 `Runner` 项目 -> `TARGETS Runner` -> `Signing & Capabilities`。
    *   在 `Team` 下拉框中选择你的 Apple ID (如果是个人开发者，可能需要连接真机并信任证书)。
4.  连接 iPhone，选择你的设备作为运行目标。
5.  点击 Xcode 顶部的 ▶️ 运行按钮，或在终端执行：
    ```bash
    flutter run
    ```
    *(首次在真机运行可能需要在手机 "设置 -> 通用 -> VPN与设备管理" 中信任你的开发者证书)*

---

## 📦 打包发布 (Release Build)

项目将常用的 Release 打包参数收敛到了 `scripts/` 目录的脚本中（包含 `--obfuscate`、`--split-debug-info` 以及 `AIRREAD_TENCENT_SCF_URL` 注入等）。

> 说明：脚本内会设置默认的 `AIRREAD_TENCENT_SCF_URL`。如果你部署了自己的后端代理地址，请在脚本顶部修改为你的地址。

### Android

*   **ARM64 APK (Windows / PowerShell)**：
    ```powershell
    pwsh ./scripts/build_android_apk_arm64_release.ps1
    ```
*   **AAB (Windows / PowerShell)**：
    ```powershell
    pwsh ./scripts/build_android_aab_release.ps1
    ```
    > 需要 PowerShell 7（`pwsh`）。

### iOS

*   **IPA (macOS / bash)**：
    ```bash
    bash ./scripts/build_ios_ipa_release.sh
    ```
    > iOS 打包仍需要在 Xcode 中完成签名配置。

---

## 🛠️ 技术细节 (Tech Details)

### 技术栈
*   **Framework**: Flutter (Dart)
*   **State Management**: Provider
*   **Database**: Sqflite (Android/iOS), Sqflite FFI (Desktop)
*   **Native Modules**:
    *   **C++**: 集成 MNN (Mobile Neural Network) 推理引擎
    *   **JNI / FFI**: Dart 与 Native 层的高效通信

### 目录结构
```
lib/
├── ai/                 # AI 核心模块 (Hunyuan, TTS, Local MNN)
├── core/               # 全局配置 (Theme, Constants)
├── data/               # 数据层 (Database, Models, Parsers)
├── presentation/       # UI 层
│   ├── pages/          # 页面 (书架, 阅读器)
│   ├── widgets/        # 通用组件
│   └── providers/      # 状态管理
└── main.dart           # App 入口
```

---

## ☁️ 代理与后端 (Server Proxy)

AirRead 支持通过代理服务访问腾讯云相关能力（混元大模型、TTS 等），用于在生产环境中隐藏 SecretId/SecretKey。

- App 侧通过 `--dart-define=AIRREAD_TENCENT_SCF_URL=...` 注入代理地址；Release 打包建议使用 `scripts/` 下脚本（脚本已包含该参数）。
- 若代理侧需要鉴权/积分体系，可在运行/打包时配置 `AIRREAD_TENCENT_SCF_TOKEN`，App 会通过请求头传递。

说明：当前仓库仅包含 App 侧对代理的调用实现，不包含可直接部署的代理后端示例代码；你可以使用腾讯云 SCF、API 网关或任意自建服务实现兼容接口。

---

## 📄 许可证 (License)

本项目基于 [MIT License](LICENSE) 开源。
