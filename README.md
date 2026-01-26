# AirRead (灵阅) 📚✨

**AirRead** 是一个基于 Flutter 开发的现代化 AI 辅助电子书阅读器。它不仅支持流畅的 EPUB，TXT阅读体验，还深度集成了 AI 能力，提供沉浸式的**AI 翻译**、**智能伴读**和**高拟真 TTS 朗读**功能。

![Platform](https://img.shields.io/badge/Platform-Android%20|%20iOS%20|%20Windows%20|%20Linux%20|%20Web-blue)
![Flutter](https://img.shields.io/badge/Flutter-%3E%3D3.3.0-02569B)
![License](https://img.shields.io/badge/License-MIT-green)

---

## 🚀 核心功能 (Key Features)

*   **📖 全平台阅读体验**：支持 Android, iOS, Windows, Linux 和 Web，一次编写，处处运行。
*   **🤖 AI 深度集成**：
    *   **AI 翻译**：调用腾讯混元大模型进行高质量的段落/全文翻译。
    *   **智能伴读**：基于上下文的 AI 问答与解析。
    *   **本地模型 (Experimental)**：集成 MNN 框架，支持在端侧运行轻量级 LLM (如 Qwen2-0.5B)，保护隐私且离线可用。
*   **🗣️ 高拟真 TTS**：集成腾讯云 TTS 引擎，提供媲美真人的语音朗读体验。
*   **☁️ 安全的云端代理**：配套的 Serverless (SCF) 后端，保护 API 密钥安全，并支持 JWT 鉴权与防盗用。
*   **🔐 完善的授权体系**：支持 Ed25519 签名验证的卡密系统，配合后端实现安全的授权管理。

---

## 🛠️ 技术栈 (Tech Stack)

*   **前端 (Client)**
    *   **Framework**: Flutter (Dart)
    *   **State Management**: Provider
    *   **Storage**: Sqflite (SQLite), SharedPreferences
    *   **Reader Core**: epubx, flutter_widget_from_html_core
    *   **AI Engine**: MNN (Mobile Neural Network) for Local LLM
*   **后端 (Server)**
    *   **Runtime**: Node.js (Tencent Cloud SCF)
    *   **Security**: Ed25519 (License Verification), JWT (Auth), HMAC-SHA256

---

## 🏁 快速开始 (Getting Started)

### 1. 环境准备
*   Flutter SDK (>= 3.3.0)
*   Dart SDK
*   Node.js (仅用于部署后端)
*   腾讯云账号 (用于开通混元大模型、TTS 和 SCF 服务)

### 2. 获取代码
```bash
git clone https://github.com/lijiahao66666/AirRead.git
cd AirRead
flutter pub get
```

### 3. 配置与运行 (客户端)

**本地开发模式 (Dev Mode)**:
你可以在 `lib/main.dart` 或应用设置中手动输入你的腾讯云 `SecretId` 和 `SecretKey` 进行测试。

**生产模式 (Prod Mode)**:
为了安全起见，建议使用我们提供的 SCF 代理后端。在编译时通过 `dart-define` 注入后端地址：

```bash
# 运行
flutter run --dart-define=AIRREAD_TENCENT_SCF_URL=https://your-scf-url.tencentcloudapi.com

# 打包 (Android)
flutter build apk --dart-define=AIRREAD_TENCENT_SCF_URL=https://your-scf-url.tencentcloudapi.com
```

---

## ☁️ 后端部署 (Server Deployment)

本项目包含一个轻量级的 Node.js 后端 (`app.js`)，专为**腾讯云云函数 (SCF)** 设计。它负责代理 AI 接口请求，隐藏你的 SecretKey，并提供卡密验证功能。

### 1. 部署步骤
1.  登录腾讯云控制台，创建一个新的云函数 (Node.js 环境)。
2.  将项目根目录下的 `app.js` 代码复制到云函数中。
3.  配置环境变量 (Environment Variables)。

### 2. 环境变量配置 (必填)

| 变量名 (Key) | 说明 | 示例 |
| :--- | :--- | :--- |
| `TENCENT_SECRET_ID` | 腾讯云 SecretId (用于调用 AI 接口) | `AKIDxxxx...` |
| `TENCENT_SECRET_KEY` | 腾讯云 SecretKey | `xxxxxx...` |
| `JWT_SECRET` | 自定义的 JWT 签名密钥 (用于保护接口) | `MySuperSecretKey` |
| `LICENSE_PUBLIC_KEY` | 卡密验证公钥 (Base64) | `Z+RpD1T...`  |
| `BUCKET_NAME` | COS 存储桶名称 (用于防重放) | `license-1250000000` |
| `REGION` | COS 地域 | `ap-guangzhou` |

> **注意**: `LICENSE_PUBLIC_KEY` 需与客户端 `lib/ai/licensing/license_codec.dart` 中的公钥保持一致。

---

## 📂 项目结构

```
lib/
├── ai/                 # AI 相关逻辑 (Hunyuan, TTS, Local LLM)
├── core/               # 核心配置 (Theme, Constants)
├── data/               # 数据层 (Database, Models, Importers)
├── presentation/       # UI 层 (Pages, Widgets, Providers)
└── main.dart           # 入口文件
app.js                  # 后端 Serverless 代码
```

---

## 🤝 贡献 (Contributing)

欢迎提交 Issue 和 Pull Request！
1.  Fork 本仓库
2.  创建你的特性分支 (`git checkout -b feature/AmazingFeature`)
3.  提交你的修改 (`git commit -m 'Add some AmazingFeature'`)
4.  推送到分支 (`git push origin feature/AmazingFeature`)
5.  开启一个 Pull Request

## 📄 许可证 (License)

本项目基于 [MIT License](LICENSE) 开源。
