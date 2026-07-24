# AirRead 灵阅 PWA

AirRead 是一个本地优先的 React + TypeScript + Vite Web/PWA，适合直接部署到任意静态站点。

## 本地运行

```bash
cd pwa
npm install
npm run dev
```

生产构建：

```bash
npm run build
```

构建产物在 `dist/`，可部署到 Nginx、GitHub Pages、Cloudflare Pages、Vercel 等静态托管。部署时需要把所有未知路径回退到 `index.html`，以支持 PWA 的 Hash 路由和离线应用壳。

## 当前能力

- 导入 EPUB 2/3 和 UTF-8、GBK、GB18030 TXT，书籍、进度、翻译结果保存在浏览器 IndexedDB。
- 沉浸式阅读：章节目录、进度记忆、选中文本实时翻译、失败重试和离线阅读。
- 书籍工作室：可扩展的本地书籍工具中心；目前已开放双语书制作，并为 TXT 转 EPUB、EPUB 格式整理保留清晰的后续入口。
- 制作双语书：检查 EPUB、顺序翻译、暂停/恢复、失败段落重试、导出双语 EPUB 或仅译文 EPUB。
- 阅读器和书籍工作室共享翻译服务配置与缓存，同时分别提供即时翻译和整书处理流程。
- 内置免费翻译 Provider，无需账号即可尝试；也支持用户自行配置 OpenAI-compatible、Azure Translator、腾讯云 TMT。

## BYOK 与隐私

用户的翻译服务配置（包括 API Key）保存在当前浏览器的本地存储中，翻译请求由浏览器直接发送到所选服务。

浏览器直连第三方服务可能受到 CORS 限制。遇到跨域错误时，需要在对应服务开启允许当前站点访问的 CORS、改用支持浏览器直连的 API 地址，或在自己的设备上运行中转服务。腾讯云 TMT 是否允许浏览器直连取决于腾讯云接口的 CORS 策略。

免费翻译服务由第三方提供，稳定性、配额和内容政策可能变化；重要内容建议配置自己的 Provider，并使用书籍工作室导出前进行抽样校对。

## 数据与离线

- 书籍原始字节、解析后的章节、封面和阅读进度保存在当前浏览器的 IndexedDB。
- 翻译缓存和 Provider 配置保存在当前浏览器本地存储。
- Service Worker 缓存应用壳和同源静态资源，为离线打开和本地阅读提供支持。
- 清理浏览器站点数据会删除本机书籍和配置，请在清理前导出需要保留的 EPUB。

## 部署结构

生产构建输出为静态 Web/PWA 文件，可直接发布到支持 `index.html` 路由回退的静态托管服务。
