# AirRead (灵阅) 📚✨

**AirRead** 是一个基于 Flutter 开发的现代化 AI 辅助电子书阅读器。它不仅支持流畅的 EPUB 和 TXT 阅读体验，还深度集成了 AI 能力，提供沉浸式的 **AI 翻译**、**智能伴读** 和 **高拟真 TTS 朗读** 功能。

![Platform](https://img.shields.io/badge/Platform-Android%20|%20iOS%20|%20Windows%20|%20Linux%20|%20Web-blue)
![Flutter](https://img.shields.io/badge/Flutter-%3E%3D3.22.0-02569B)
![License](https://img.shields.io/badge/License-MIT-green)

---

## 📱 核心亮点 (Highlights)

*   **📖 极致阅读**：支持 EPUB 和 TXT 格式，内置多种配色主题与字体设置，支持 GBK 编码自动识别。
*   **🤖 AI 赋能**：
    *   **沉浸式翻译**：调用腾讯混元大模型，提供高质量的段落/全文翻译，打破语言障碍。
    *   **智能伴读**：基于上下文的 AI 问答，随时解析书中难点、背景知识。
    *   **本地隐私大模型**：集成 MNN 框架，支持在手机端运行轻量级 LLM (如 Qwen3-0.6B)，无需联网即可体验 AI 能力 (Experimental)。
*   **🗣️ 真人级 TTS**：集成腾讯云 TTS 引擎，情感丰富，媲美真人朗读。
*   **🔒 安全架构**：支持 "直连模式"  和 "代理模式" ，通过配套的 Serverless 后端保护 API 密钥安全。

---

## 🚀 快速上手 (Quick Start for Mobile)

如果你想快速将 AirRead 安装到你的 Android 或 iOS 手机上，请按照以下步骤操作。

### 1. 环境准备 (Prerequisites)

确保你的开发环境已安装：
*   **Flutter SDK**: 版本 `>= 3.22.0`
*   **Dart SDK**: 配套版本
*   **AI IDE** (用于开发) 和 **Xcode** (用于 iOS 开发，仅限 macOS)
*   **CocoaPods**: iOS 开发必需 (`sudo gem install cocoapods`)

### 2. 获取代码

```bash
git clone https://github.com/lijiahao66666/AirRead.git
cd AirRead
flutter pub get
```

### 3. 配置 API 密钥 (重要)
AirRead 的核心 AI 功能依赖腾讯云服务 (混元大模型、TTS)。你可以选择 **快速体验模式** 或 **安全部署模式**。

#### 🅰️ 快速体验模式 (推荐开发者个人使用)
直接在 App 设置中输入密钥，无需部署后端。

1.  注册 [腾讯云账号](https://cloud.tencent.com/) 并开通 **混元大模型** ，**语音合成 (TTS)** 和 **腾讯机器翻译** 服务。
2.  获取你的 `SecretId` 和 `SecretKey` ([访问密钥控制台](https://console.cloud.tencent.com/cam/capi))。
3.  编译并运行 App (见下文)。
4.  打开 App，进入 **设置 -> API 设置**，填入你的 `SecretId` 和 `SecretKey` 即可立即使用。

#### 🅱️ 安全部署模式 (推荐公开分发使用)
如果你计划将 App 分发给他人使用，建议部署 Serverless 后端来隐藏密钥。
*请参考后文的 [☁️ 后端部署](#-后端部署-server-deployment) 章节。*

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
    或者构建 Release 包安装：
    ```bash
    flutter build apk --release
    flutter install
    ```

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

## ☁️ 后端部署 (Server Deployment) - 可选

本项目提供一个基于 Node.js 的 Serverless 代理后端 (`app.js`)，用于在生产环境中隐藏腾讯云密钥。

1.  **部署环境**: 腾讯云云函数 (SCF)。
2.  **代码**: 使用项目根目录下的 `app.js`。
3.  **环境变量**:
    *   `TENCENT_SECRET_ID`: 你的腾讯云 SecretId
    *   `TENCENT_SECRET_KEY`: 你的腾讯云 SecretKey
    *   `JWT_SECRET`: 自定义密钥，用于生成 App 访问 Token
    *   `LICENSE_PUBLIC_KEY`: 配套的卡密验证公钥
4.  **App 接入**:
    编译时注入后端地址：
    ```bash
    flutter run --dart-define=AIRREAD_TENCENT_SCF_URL=https://your-func-url.com
    ```

---

## ❓ 常见问题 (FAQ)

**Q: 本地 AI 模型有多大？需要下载吗？**
A: 本地 AI 功能 (MNN) 首次使用时会自动从 ModelScope 下载模型文件。目前使用的是 `Qwen3-0.6B` (或更新版本)，总大小约为 **450MB**。下载过程支持断点续传。

**Q: Android 模拟器无法运行，提示找不到 libMNN.so？**
A: 请使用 **真机** 调试。由于 MNN 库针对性能优化，我们目前仅配置了 `arm64-v8a` 架构的支持 (见 `android/app/build.gradle`)，这可以显著减小包体积。大多数 x86 模拟器无法运行。

**Q: iOS 编译报错 `Sandbox: rsync.samba(...) deny(1) file-write-create`？**
A: 这是 Xcode 14+ 的常见权限问题。请在 Xcode 中 Build Settings -> Build Options -> User Script Sandboxing 设置为 `No`。

**Q: 如何导入书籍？**
A: 
*   **Android**: 点击书架右上角 `+` 号，选择文件导入。支持多选。
*   **iOS**: 可以通过 "文件" App 分享到 AirRead，或者在 AirRead 内点击 `+` 号浏览 iCloud/本地文件。

---

## 📄 许可证 (License)

本项目基于 [MIT License](LICENSE) 开源。
