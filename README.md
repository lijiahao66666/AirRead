# AirRead（灵阅）

AirRead 是一个基于 Flutter 的 AI 辅助电子书阅读器，支持 Android / iOS / Web 三端。它提供稳定的 EPUB/TXT 阅读体验，并将翻译、伴读问答与朗读能力整合到阅读流程中。

![Platform](https://img.shields.io/badge/Platform-Android%20|%20iOS%20|%20Web-blue)
![Flutter](https://img.shields.io/badge/Flutter-%3E%3D3.22.0-02569B)
![License](https://img.shields.io/badge/License-MIT-green)

---

## 功能概览

- 阅读体验：支持 EPUB/TXT，主题与字体设置，GBK 编码自动识别
- 书架与导入：文件导入、书架管理、阅读进度与本地存储
- 翻译：沉浸式翻译（机器翻译 / 大模型翻译），支持队列与缓存，适配阅读场景
- 伴读问答：基于“当前阅读上下文”的问答与章节能力（如总结、提取要点）
- 插图生成：一键分析当前章节内容，自动提取场景并生成精美插图（支持国风、水墨、日漫等多种风格），提供可视化阅读体验
- 朗读：支持在线朗读（腾讯云 TTS）、iOS/Android 设备自带朗读（系统 TTS）与 Web 本地朗读（浏览器 SpeechSynthesis），并提供朗读调度/预取能力
- 本地大模型（实验）：iOS/Android 端集成 MNN LLM，提供混元（Hunyuan）系列模型下载后离线推理
- 凭据与安全：支持直连（个人密钥）与代理（自建服务）两种调用方式

## 平台与限制

- Android：仓库配置仅打包 `arm64-v8a`（不支持 x86 模拟器），需使用真机或 ARM64 模拟器
- iOS：本地大模型仅支持 arm64 设备/模拟器；Intel 模拟器不支持本地模型
- Web：本地朗读依赖浏览器 SpeechSynthesis，受浏览器策略/音色可用性影响；本地大模型推理暂不支持

---

## 🚀 快速上手 (Quick Start)

如果你想快速运行 AirRead，请按照以下步骤操作。

### 1. 环境准备 (Prerequisites)

确保你的开发环境已安装：
*   **Flutter SDK**: 版本 `>= 3.22.0`
*   **Dart SDK**: 配套版本
*   **Android Studio / VS Code** (用于开发)
*   **Xcode** + **CocoaPods**: iOS 开发必需（仅限 macOS，`sudo gem install cocoapods`）

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
如果你计划将 App 分发给他人使用，建议通过后端代理服务隐藏密钥，并在编译时注入代理地址。
*请参考后文的 [☁️ 后端服务](#-后端服务-server) 章节。*

---

### 4. 编译与运行 (Run on Device)

⚠️ **注意**：由于集成了 MNN 本地大模型库，移动端仅支持 **ARM64 架构** 的设备。

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

项目将常用的 Release 打包参数收敛到了 `scripts/` 目录的脚本中（包含 `--obfuscate`、`--split-debug-info` 以及 API 代理地址注入等）。

> 说明：脚本内已设置默认的后端代理地址（`AIRREAD_API_PROXY_URL`）和 API Key。如果你部署了自己的后端，请在脚本顶部修改为你的地址。

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

### Web

*   **Web (Windows / PowerShell)**：
    ```powershell
    pwsh ./scripts/build_web_release.ps1
    ```
    产物在 `build/web/`，部署到任意静态托管即可。

---

## 🛠️ 技术细节 (Tech Details)

### 技术栈
*   **Framework**: Flutter (Dart)
*   **State Management**: Provider
*   **Database**: Sqflite (Android/iOS/Web)
*   **Native Modules**:
    *   **C++**: 集成 MNN (Mobile Neural Network) 推理引擎
    *   **JNI / FFI**: Dart 与 Native 层的高效通信

### 目录结构
```
lib/
├── ai/                 # AI 核心模块 (Tencent Hunyuan Online, TTS, Local MNN)
├── core/               # 全局配置 (Theme, Constants)
├── data/               # 数据层 (Database, Models, Parsers)
├── presentation/       # UI 层
│   ├── pages/          # 页面 (书架, 阅读器)
│   ├── widgets/        # 通用组件
│   └── providers/      # 状态管理
└── main.dart           # App 入口
```

---

## ☁️ 后端服务 (Server)

AirRead 后端是一个轻量 Node.js 服务 (`server/app.js`)，部署在腾讯云轻量服务器上，提供以下能力：

| 端点 | 方法 | 说明 |
|------|------|------|
| `/` `/health` | GET | 健康检查 |
| `/config` | GET | 远程配置（签到开关、版本更新等） |
| `/points/init` | POST | 初始化设备积分（首次赠送，服务端防重复） |
| `/points/balance` | POST | 查询积分余额 |
| `/checkin` | POST | 每日签到（服务端防重复） |
| `/checkin/status` | POST | 查询今日签到状态 |
| `/auth/sms/send` | POST | 发送短信验证码（60s限频，每日10条上限） |
| `/auth/sms/verify` | POST | 验证码登录/注册（自动迁移deviceId积分到userId） |
| `/auth/profile` | POST | 获取用户信息（需token） |
| `/auth/logout` | POST | 退出登录（吊销token） |
| `/stats/today` | GET | 今日日活统计（管理用） |
| `/` | POST | API 代理（混元/TMT/TTS），含积分扣费 |

### 鉴权

- 客户端请求头 `X-Api-Key` 携带静态 API Key
- 客户端请求头 `X-Device-Id` 携带设备唯一标识（Android: ANDROID_ID, iOS: identifierForVendor, Web: UUID）
- 客户端请求头 `X-Auth-Token` 携带登录token（登录后自动注入）
- 服务端通过 `process.env.API_KEY` 校验，不匹配返回 401
- 积分优先绑定 userId（来自token），fallback 到 deviceId

### 用户登录体系

- 手机号 + 短信验证码登录（腾讯云 SMS）
- 未注册手机号自动创建账号
- 登录后积分绑定到 userId，支持跨设备同步
- 首次登录自动将 deviceId 上的积分迁移到 userId
- 使用个人密钥的用户无需登录

### 积分体系

- 积分数据存储在服务器 `server/data/points/{userId或deviceId}.json`
- 初始积分赠送、签到奖励、翻译/问答扣费均由服务端控制
- 卸载重装不会导致积分重置或重复赠送（Android/iOS 使用硬件 ID）
- 登录后积分跨设备同步

### 数据存储（文件系统）

| 目录 | 内容 |
|------|------|
| `data/points/{id}.json` | 积分余额和签到记录 |
| `data/users/{phone}.json` | 用户信息 |
| `data/tokens/{token}.json` | token→userId 映射 |
| `data/sms/{phone}.json` | 验证码临时存储 |
| `data/stats/daily/{date}.json` | 日活统计 |

### 服务器 .env 配置

```bash
PORT=9000
TENCENT_SECRET_ID=你的腾讯云SecretId
TENCENT_SECRET_KEY=你的腾讯云SecretKey
API_KEY=f56dc8fc812647992db74ee0a419b3b2b7171b669cb2046caa53e19f3c564c73

# 短信登录（腾讯云SMS）
SMS_APP_ID=你的短信应用ID（如1400xxxxxx）
SMS_SIGN=灵阅
SMS_TEMPLATE_ID=你的短信模板ID（如1234567）
```

### 部署与更新流程

```bash
# 1. 上传 server/app.js 到服务器
scp server/app.js root@air-inc.top:/www/airread/app.js

# 2. 重启服务
ssh root@air-inc.top "pm2 restart airread"

# 3. 验证
curl http://air-inc.top:9000/health   # 应返回 OK
curl http://air-inc.top:9000/config   # 应返回 JSON 配置
```

### 远程配置 (config.json)

服务端 `server/config.json` 控制 App 行为，首次启动自动生成默认值：

```json
{
  "checkin_enabled": true,
  "checkin_points": 5000,
  "initial_grant_points": 500000,
  "ad_enabled": false,
  "ad_reward_points": 2000,
  "ad_daily_limit": 10,
  "purchase_enabled": false,
  "latest_version": "1.0.0",
  "min_version": "1.0.0",
  "update_url": "",
  "update_message": "",
  "force_update": false,
  "announcement": ""
}
```

修改此文件后无需重启服务，下次请求 `/config` 会自动读取新值。

---

## 🌐 域名与二级域名规划

主域名：`air-inc.top`

| 二级域名 | 用途 | 指向 |
|----------|------|------|
| `read-api.air-inc.top` | AirRead 后端 API | 轻量云服务器 IP（反向代理到 :9000） |
| `translate-api.air-inc.top` | AirTranslate 后端 API | 轻量云服务器 IP（反向代理到 :9001） |
| `read.air-inc.top` | AirRead Web 版 | 静态托管（Nginx / 宝塔） |
| `translate.air-inc.top` | AirTranslate Web 版 | 静态托管 |
| `www.air-inc.top` | 主站/落地页（可选） | 同上 |

### 配置步骤

#### 1. 腾讯云 DNS 解析添加记录

登录 [腾讯云 DNS 解析控制台](https://console.cloud.tencent.com/cns)，为 `air-inc.top` 添加以下 A 记录：

| 主机记录 | 记录类型 | 记录值 | 说明 |
|----------|----------|--------|------|
| `read-api` | A | `你的服务器IP` | AirRead 后端 API |
| `translate-api` | A | `你的服务器IP` | AirTranslate 后端 API |
| `read` | A | `你的服务器IP` | AirRead Web |
| `translate` | A | `你的服务器IP` | AirTranslate Web |

#### 2. 宝塔面板配置 Nginx 反向代理

为每个后端服务分别配置反向代理：

**AirRead 后端（`read-api.air-inc.top` → `:9000`）**

在宝塔面板中新建网站 `read-api.air-inc.top`，**设置 → 反向代理**：
- 目标 URL：`http://127.0.0.1:9000`
- 申请 SSL 证书，启用 HTTPS

**AirTranslate 后端（`translate-api.air-inc.top` → `:9001`）**

同上新建网站 `translate-api.air-inc.top`，反向代理到 `:9001`。

Nginx 配置示例（以 AirRead 为例）：

```nginx
server {
    listen 80;
    listen 443 ssl http2;
    server_name read-api.air-inc.top;

    # SSL 证书（宝塔自动管理或手动配置）
    # ssl_certificate    /path/to/fullchain.pem;
    # ssl_certificate_key /path/to/privkey.pem;

    location / {
        proxy_pass http://127.0.0.1:9000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

AirTranslate 同理，把 `server_name` 改为 `translate-api.air-inc.top`，`proxy_pass` 改为 `:9001`。

#### 3. 宝塔面板配置静态网站（read.air-inc.top）

1. 宝塔新建网站 `read.air-inc.top`，网站目录指向如 `/www/wwwroot/read.air-inc.top`
2. 将 `build/web/` 目录的所有文件上传到该目录
3. 申请 SSL 证书，启用 HTTPS

#### 4. 更新打包脚本中的 URL

配置好 HTTPS 二级域名后，需要更新各打包脚本：

```
# 旧
http://air-inc.top:9000
http://air-inc.top:9000/config

# 新（AirRead）
https://read-api.air-inc.top
https://read-api.air-inc.top/config
```

需要修改的文件：
- `scripts/build_android_apk_arm64_release.ps1`
- `scripts/build_android_aab_release.ps1`
- `scripts/build_ios_ipa_release.sh`
- `scripts/build_web_release.ps1`

---

## 📋 日常运维 Checklist

### 更新后端代码

1. 修改 `server/app.js`
2. 上传到服务器：`scp server/app.js root@air-inc.top:/www/airread/app.js`
3. 重启：`ssh root@air-inc.top "pm2 restart airread"`

### 发布 Android 新版本

1. 修改 `pubspec.yaml` 中的 `version`
2. 更新打包脚本中的 `$appVersion`
3. 运行 `pwsh ./scripts/build_android_apk_arm64_release.ps1`
4. APK 产物在 `build/app/outputs/flutter-apk/app-release.apk`
5. 更新 `server/config.json` 中的 `latest_version`

### 发布 iOS 新版本

1. 同上修改版本号
2. 在 macOS 上运行 `bash ./scripts/build_ios_ipa_release.sh`
3. 使用 Xcode / Transporter 上传至 App Store Connect

### 发布 Web 新版本

1. 运行 `pwsh ./scripts/build_web_release.ps1`
2. 将 `build/web/` 内容上传到 `read.air-inc.top` 对应目录
3. 刷新 CDN 缓存（如使用）

### 修改远程配置

直接编辑服务器上的 `/www/airread/config.json`，无需重启。

---

## ❓ 备案说明

### App 备案

- Android/iOS App 上架应用商店需要先完成 App 备案
- 已提交备案，等待审核

### 网站备案

- 域名 `air-inc.top` 如果在国内服务器上提供 **Web 网站**，需要完成 ICP 备案
- **备案前**：可以用 IP 直连或境外服务器临时测试
- **备案流程**：在腾讯云控制台提交 ICP 备案申请，一般 7-20 个工作日
- **注意**：备案期间域名不能解析到网站，备案通过后才可正式上线
- 纯 API 接口服务（`api.air-inc.top`）目前通过 IP + 端口访问，App 端不受网站备案影响

---

## 📄 许可证 (License)

本项目基于 [MIT License](LICENSE) 开源。
