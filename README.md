# AirRead（灵阅）

AirRead 是一个本地优先的沉浸式双语阅读器。当前唯一主线是 Web/PWA：用户可以在浏览器中导入自己的 EPUB/TXT，阅读时实时翻译，也可以在书籍工作室中处理和导出电子书。

## 推荐使用方式

```bash
cd pwa
npm install
npm run dev
```

构建生产版本：

```bash
cd pwa
npm run build
```

将 `pwa/dist/` 部署到任意静态托管即可。服务器只需要提供静态文件和 `index.html` 回退，不需要启动 AirRead 旧服务端，也不需要配置腾讯云密钥、短信、积分或登录系统。

更完整的运行、部署、BYOK 和隐私说明见 [`pwa/README.md`](pwa/README.md)。

## 当前产品边界

- **书架与阅读器**：支持 EPUB 2/3、UTF-8/GBK/GB18030 TXT、章节目录、进度记忆、选中文本实时翻译、失败重试。
- **书籍工作室**：作为可扩展的本地工具中心；目前已提供双语书制作，界面中明确列出 TXT 转 EPUB、EPUB 格式整理等后续方向。
- **制作双语书**：AirTranslate 的能力并入 AirRead，提供整本 EPUB 的顺序翻译、暂停/恢复、失败段落重试、双语或仅译文导出。
- **共享底层、不混流程**：阅读器的实时翻译保持即时交互；工作室的整书制作保持可暂停、可重试、可导出的批处理流程。两者共享 Provider Registry 和翻译缓存。
- **免费 + BYOK**：内置免费翻译用于开箱体验；用户也可自行填写 OpenAI-compatible、Azure Translator 或腾讯云 TMT 的地址、区域和 API Key。
- **本地优先**：书籍、进度、翻译缓存和 Provider 配置留在当前浏览器；首次启动不登录、不签到、不初始化积分、不生成设备 ID、不请求 AirRead 后端。

## 翻译与跨域说明

AirRead 不提供官方付费翻译额度，也不再依赖腾讯云余额。浏览器会直接请求用户选择的翻译服务，AirRead 不会代为转发请求或保存 API Key。第三方接口需要允许当前站点的 CORS；如果浏览器提示无法连接，应开启对应服务的网页访问能力、更换支持浏览器直连的地址，或在自己的设备上运行中转服务。腾讯云 TMT 是否允许浏览器直连，以腾讯云接口的实际 CORS 策略为准。

免费翻译服务的可用性和配额由第三方决定，重要书籍建议配置自己的 Provider，并在导出前抽样校对译文。

## 仓库状态

当前仓库只保留 Web/PWA 实现，不包含需要单独部署的业务后端。运行、测试和部署只依赖 `pwa/`。

## 目录结构

```text
AirRead/
└── pwa/       # 唯一运行主线：React + TypeScript + Vite Web/PWA
```

## 验证

在 `pwa/` 目录运行：

```bash
npm test -- --run
npm run build
```
