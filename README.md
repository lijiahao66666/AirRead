# AirRead 灵阅

AirRead 是一款 Flutter 多端阅读应用，提供 EPUB/TXT 阅读与朗读能力，并配套轻量服务端用于配置/状态输出。

## Features
- EPUB/TXT 阅读
- TTS 朗读
- Flutter 多端（Android/iOS/Web）
- 轻量 Node.js 服务端（配置/健康检查）

## Quick Start
### App
```bash
flutter pub get
flutter run
```

### Server
```bash
cd server
cp .env.example .env
npm install --omit=dev
pm2 start ecosystem.config.cjs
```

## Build
- Web: `scripts/build_web_release.ps1`
- Android: `scripts/build_android_apk_arm64_release.ps1`
- iOS: `scripts/build_ios_ipa_release.sh`

## Deploy
- Web: 将 `build/web/` 上传到站点目录
- Server: 将 `server/` 上传到 `/www/airread/`，并运行 `pm2 start ecosystem.config.cjs`
- Nginx: `server/nginx.read.air-inc.top.conf`

## Project Structure (Unified)
- `server/`: Node backend, env template, config, PM2 config, Nginx config
- `scripts/`: build/release scripts
- `web/` or `build/web/`: static web build output
- `docs/`: product and deployment notes (optional)

Nginx config location:
- `server/nginx.<domain>.conf`

Env template:
- `server/.env.example`