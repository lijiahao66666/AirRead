# AirRead (智能阅读器)

AirRead 是一款集成了 AI 能力的现代电子书阅读器，专为提升阅读体验而生。它不仅支持 EPUB 格式的流畅阅读，还通过集成大模型和语音合成技术，提供智能对话、辅助阅读和沉浸式听书功能。

## ✨ 核心功能

- **📚 沉浸式阅读**: 支持 EPUB 格式电子书，提供舒适的排版和翻页体验。
- **🤖 AI 辅助**:
  - **智能对话**: 集成腾讯混元大模型 (Hunyuan) 和本地大模型 (Local LLM)，可随时与 AI 探讨书中内容。
  - **辅助阅读**: AI 帮你总结章节大意、解释难懂词汇。
- **🎧 听书模式**: 集成腾讯云 TTS (语音合成)，提供自然流畅的语音朗读服务，解放双眼。
- **🌍 多语言支持**: 内置翻译功能，轻松阅读外文书籍。
- **🎨 跨平台体验**: 基于 Flutter 开发，支持 Android、iOS、Web 和 Windows 多端运行。

## 🛠️ 技术栈

### 客户端 (Client)
- **框架**: Flutter
- **语言**: Dart
- **核心库**:
  - `provider`: 状态管理
  - `epubx`: EPUB 解析与渲染
  - `sqflite`: 本地数据存储
  - `flutter_animate`: UI 动画效果
  - `audioplayers`: 音频播放
  - `http`: 网络请求

### 服务端 (Server)
- **运行环境**: Node.js
- **功能**: 提供轻量级的数据接口和鉴权服务。

## 📂 目录结构

```
AirRead/
├── client/           # Flutter 客户端源代码
│   ├── lib/
│   │   ├── ai/       # AI 功能模块 (Hunyuan, TTS, Local LLM)
│   │   ├── core/     # 核心组件与配置
│   │   ├── data/     # 数据层 (Database, Models)
│   │   └── presentation/ # UI 层 (Pages, Widgets)
│   └── pubspec.yaml
├── server/           # Node.js 服务端源代码
│   ├── app.js
│   └── package.json
├── scripts/          # 构建与部署脚本
└── README.md         # 项目说明文档
```

## 🚀 快速开始

### 客户端运行
1. 进入客户端目录:
   ```bash
   cd client
   ```
2. 安装依赖:
   ```bash
   flutter pub get
   ```
3. 运行应用:
   ```bash
   flutter run
   ```

### 服务端运行
1. 进入服务端目录:
   ```bash
   cd server
   ```
2. 安装依赖:
   ```bash
   npm install
   ```
3. 启动服务:
   ```bash
   npm start
   ```

## 📝 开发规范
请参考根目录下的 `product_rule.md` 了解详细的开发与部署规范。
