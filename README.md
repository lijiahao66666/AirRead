# AirRead（爱阅）

AirRead 是一款 AI 驱动的阅读应用，旨在提供智能、便捷的阅读体验。它结合了本地 LLM 能力和云端 AI 服务，支持多种电子书格式，并提供沉浸式的阅读环境。

## 项目结构

本项目采用统一的结构设计：

- **client/**: Flutter 客户端源代码。包含 Android, iOS, Web, Windows, Linux, macOS 的跨平台实现。
  - `lib/`: 核心代码逻辑。
  - `android/`, `ios/`, `web/` 等: 平台特定配置。
- **server/**: Node.js 后端服务代码。负责业务逻辑和数据处理。
- **scripts/**: 项目构建和部署脚本。

## 技术栈

- **客户端**: Flutter
  - 状态管理: `provider`
  - 动画: `flutter_animate`
  - 阅读引擎: `epubx`, `flutter_widget_from_html_core`, `page_flip`
  - AI 能力: 
    - 本地: MNN (Mobile Neural Network) 端侧推理
    - 云端: 腾讯云 TTS (语音合成), TMT (机器翻译), Hunyuan (混元大模型)
- **服务端**: Node.js
- **部署**: 宝塔面板, Nginx, PM2

## 部署指南

### Web 端部署

1. 运行构建脚本：
   ```powershell
   ./scripts/build_web_release.ps1
   ```
2. 构建产物位于 `client/build/web` (或脚本输出目录)。
3. 将构建产物上传至云服务器宝塔面板的 HTML 站点目录。
4. 访问域名：[read.air-inc.top](https://read.air-inc.top)

### 服务端部署

1. 将 `server/` 目录上传至服务器。
2. 在服务器上运行 `npm install` 安装依赖。
3. 使用 PM2 启动服务：`pm2 start ecosystem.config.cjs` (如果存在) 或 `npm start`。
4. 配置 Nginx 反向代理 (参考 `server/nginx.read.air-inc.top.conf`)。

### 移动端/桌面端

使用 `scripts/` 目录下的相应脚本进行构建 (如 `build_android_apk_arm64_release.ps1`)。
