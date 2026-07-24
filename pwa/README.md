# AirRead 灵阅 PWA

AirRead 当前的主线实现是一个本地优先的 React + TypeScript + Vite Web/PWA。它不依赖 AirRead 旧服务端、登录、积分、签到、COS、短信、腾讯云余额或本地模型，适合直接部署到任意静态站点。

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
- AirTranslate 已并入“书籍工作室”；工作室和阅读器共享翻译底层 Provider 与缓存，但实时阅读翻译和整书制作仍是两条独立流程。
- 内置免费翻译 Provider，无需账号即可尝试；也支持用户自行配置 OpenAI-compatible、Azure Translator、腾讯云 TMT。

## BYOK 与隐私

用户的翻译服务配置（包括 API Key）只保存在当前浏览器的本地存储中。请求从浏览器直接发往用户选择的服务，AirRead 不提供官方付费翻译额度，也不会代为转发请求或保存密钥。

浏览器直连第三方服务可能受到 CORS 限制。遇到跨域错误时，需要在对应服务开启允许当前站点访问的 CORS、改用支持浏览器直连的 API 地址，或在自己的设备上运行中转服务。腾讯云 TMT 是否允许浏览器直连取决于腾讯云接口的 CORS 策略。

免费翻译服务由第三方提供，稳定性、配额和内容政策可能变化；重要内容建议配置自己的 Provider，并使用书籍工作室导出前进行抽样校对。

## 数据与离线

- 书籍原始字节、解析后的章节、封面和阅读进度保存在当前浏览器的 IndexedDB。
- 翻译缓存和 Provider 配置保存在当前浏览器本地存储。
- Service Worker 只缓存应用壳和同源静态资源；首次打开不会自动登录、签到、初始化积分、生成设备 ID 或请求 AirRead 后端。
- 清理浏览器站点数据会删除本机书籍和配置，请在清理前导出需要保留的 EPUB。

## 仓库边界

当前项目是静态 Web/PWA，不包含需要单独部署或充值的业务后端，也不依赖应用市场发布链路。
