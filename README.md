# AirRead（灵阅）

AirRead 是一款基于 Flutter 的电子书阅读器，面向 EPUB 阅读场景，内置 AI 伴读与朗读能力。客户端以书架与阅读器为核心界面，服务端提供腾讯云 AI 能力代理、积分与配置下发。

## 功能概览

- 书架管理与阅读器：导入 EPUB、展示封面与作者信息、进入阅读页面。
- AI 伴读面板：支持问答、总结、要点提取、插画提示词生成。
- 翻译能力：支持机器翻译与大模型翻译两种模式。
- 朗读能力：支持本地朗读与腾讯云 TTS 在线朗读。
- 积分与登录：支持短信验证码登录、积分初始化、签到与积分查询。

## 客户端功能细节

- EPUB 解析：使用 `epubx` 读取 EPUB，解析元数据与封面。
- 翻译引擎：
  - 机器翻译：Azure 翻译 (Edge Token) 与腾讯 TMT。
  - 大模型翻译：腾讯混元翻译引擎。
- AI 模型：
  - 在线：腾讯混元文本/生图能力。
  - 本地：MNN 本地模型推理（问答/插画）。
- 朗读：
  - 本地 TTS：通过 `MethodChannel` 与 `EventChannel` 驱动原生朗读。
  - 在线 TTS：腾讯云 TTS。

## 服务端功能

- 代理腾讯云 API（混元 / TTS / TMT），统一签名与请求转发。
- 积分系统（本地 JSON 存储）。
- 远程配置接口 `/config`。
- 登录与管理接口（短信验证码、积分查询与赠送）。

## 目录结构

- client/：Flutter 客户端
- server/：Node.js 服务端
- scripts/：构建与部署脚本
- README.md：项目说明

## 本地运行

客户端：
```
cd client
flutter pub get
flutter run
```

服务端：
```
cd server
npm install
node app.js
```

## 参考

项目规范请查看 `product_rule.md`。
