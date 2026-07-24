# AirRead（灵阅）

AirRead 是一个本地优先的沉浸式双语阅读器。用户可以在浏览器中导入自己的 EPUB/TXT，阅读时生成本章双语，也可以选中片段按需翻译或朗读；书籍工作室负责处理和导出电子书。

## 产品能力

- **书架与阅读器**：支持 EPUB 2/3、UTF-8/GBK/GB18030 TXT、章节目录、进度记忆、一键生成本章双语、划词翻译和设备语音朗读。
- **书籍工作室**：提供双语书制作，并为 TXT 转 EPUB、EPUB 格式整理等后续工具保留入口。
- **制作双语书**：支持整本 EPUB 顺序翻译、暂停/恢复、失败段落重试，以及双语或仅译文导出。
- **两种翻译体验**：阅读器提供本章双语与划词即时翻译，工作室提供可暂停、可重试、可导出的整书处理流程；两者共享翻译服务配置与缓存。阅读页使用“设置 → 阅读偏好”作为全局默认值，书籍正文和划词翻译分别保存自己的目标语言，不会互相改动。
- **同语言保护**：阅读器会先判断内容是否已经是目标语言；中文、英语、日语、韩语、法语、德语、西班牙语和俄语等明显同语言内容不会重复请求翻译，并会明确提示无需翻译。
- **免费 + 自带密钥**：内置免费翻译，默认自动按 MyMemory → Azure Edge → Google Translate 尝试；也可以在设置中选择单条免费线路。自定义服务分为“大语言模型翻译”（OpenAI Responses API、OpenAI Chat Completions 兼容协议、Anthropic Messages API）和“专用翻译 API”（自定义 HTTP JSON、腾讯云翻译 TMT、Azure AI Translator、有道智云文本翻译、DeepL API）。大语言模型服务可单独设置翻译提示词，AirRead 会自动附加源语言、目标语言、术语表和原文。
- **本地优先**：书籍、进度、翻译缓存、阅读语言、书籍翻译偏好、划词翻译偏好和翻译服务配置保存在当前浏览器，打开网页即可使用。

## 本地运行

```bash
npm install
npm run dev
```

生产构建：

```bash
npm run build
```

构建产物位于 `dist/`，可部署到 Nginx、GitHub Pages、Cloudflare Pages、Vercel 等静态托管服务。部署时需要将未知路径回退到 `index.html`。

## 翻译与隐私

翻译请求由浏览器直接发送到所选服务，API Key 保存在当前浏览器。第三方接口需要允许当前站点的 CORS；如果浏览器提示无法连接，应开启对应服务的网页访问能力、更换支持浏览器直连的地址，或在自己的设备上运行中转服务。

免费翻译服务的可用性和配额由第三方决定。自动线路会按 MyMemory、Azure Edge、Google Translate 顺序尝试；Google Translate 线路需要可访问 Google 的网络环境，Azure Edge 是微软 Edge 使用的非官方无 Key 接口，可能随时变化。重要书籍建议配置自己的翻译服务，并在导出前抽样校对译文。

专用翻译 API 都使用用户自己的账户：Azure AI Translator 官方 F0 每月 200 万字符，需要 Azure 资源 Key；腾讯云翻译 TMT 使用 SecretId、SecretKey 和地域；有道智云文本翻译使用 App Key、App Secret 签名；DeepL API Free 使用 `https://api-free.deepl.com` 和 DeepL Auth Key，Pro 账户可改用 `https://api.deepl.com`。这些额度均不由 AirRead 提供。

自定义 HTTP JSON 翻译约定为 `POST` 请求，Body 使用 `{ text, sourceLanguage, targetLanguage }`，通过 `Authorization: Bearer <API Key>` 鉴权，响应返回 `translation` 或 `translatedText` 字段。

章节朗读使用当前浏览器和操作系统提供的语音能力，不上传音频，也不依赖 AirRead 服务。可在“设置 → 阅读偏好”选择声音和速度；可用声音与朗读效果由设备决定，声音较少时可以先在系统语音设置中安装增强或高级语音。

## 数据与离线

- 书籍原始文件、解析后的章节、封面、阅读进度、书籍正文目标语言和划词目标语言保存在浏览器 IndexedDB；全局阅读默认值保存在当前浏览器。
- 翻译缓存和翻译服务配置保存在浏览器本地存储。
- Service Worker 缓存应用壳和同源静态资源，为离线打开和本地阅读提供支持。
- 清理浏览器站点数据会删除本机书籍和配置，请提前导出需要保留的 EPUB。

## 项目结构

```text
AirRead/
├── public/          # PWA 清单、图标与 Service Worker
├── src/             # 应用源码与测试
├── index.html       # Web 入口
├── package.json     # 依赖与脚本
└── vite.config.ts   # 构建与测试配置
```

## 验证

```bash
npm test -- --run
npm run build
```
