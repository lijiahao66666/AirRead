## 你问的 Region
- 自定义模式输入框不需要 Region：混元生文（ChatCompletions/ChatTranslations）文档里 Region 是可选公共参数；语音合成 TextToVoice 也不强制需要 Region。
- 代码里默认不传 `X-TC-Region`，仅在将来遇到某个接口强制要求时，再用内部默认值（不暴露 UI）。

## 目标范围
- 使用腾讯混元替换当前 LLM：
  - 翻译：混元生文 `ChatTranslations`
  - 智能问答：混元生文 `ChatCompletions`
  - 图文：混元生图 `TextToImageLite`（轻量版，先做到最小可用）
  - 朗读：腾讯云语音合成 `TextToVoice`
- 在 AI 伴读面板右侧增加“腾讯混元设置”入口：默认使用公共凭证；可切换到自定义并填入凭证。

## 现有项目接入点（不会大改架构）
- 翻译现有调用链已成型：ReaderPage → TranslationProvider → TranslationService → TranslationEngine。
  - 只需新增一个混元引擎实现并替换注入。
- QA/图文/TTS 当前仅 UI 占位：
  - QA 在 [ai_hud.dart](file:///c:/Users/28679/traeProjects/AirRead/lib/presentation/widgets/ai_hud.dart) 的 `_QaPanelState._send()` 里是占位。
  - 图文与朗读在 [reader_page.dart](file:///c:/Users/28679/traeProjects/AirRead/lib/presentation/pages/reader/reader_page.dart) 里只有开关与暂停逻辑，没有真实服务调用。

## 鉴权与凭证字段（对你现有说法做一次澄清）
- 腾讯云云 API 密钥实际是一对：`SecretId + SecretKey`（SecretKey 只在创建时展示一次，之后无法再查看，丢了只能重新创建）。
- 你提到的 AppId 可以一并展示在设置里用于说明/标识，但混元/TTS 的云 API 鉴权核心是 `SecretId/SecretKey` 的 v3 签名。
- 设置面板里：
  - 默认：使用“公共（内置）SecretId/SecretKey(+AppId 展示用)”
  - 自定义：输入框只提供 `AppId`、`SecretId`、`SecretKey`（不提供 Region）。

## 实现方案（模块拆分）
### 1) 新增“腾讯云签名 v3 + HTTP Client”底座
- 新增 `lib/ai/tencentcloud/`：
  - `tc3_signer.dart`：实现 TC3-HMAC-SHA256（canonical request / stringToSign / signature）。
  - `tencent_credentials.dart`：管理“公共/自定义”两种凭证来源。
  - `tencent_api_client.dart`：封装 POST JSON，自动加 `X-TC-Action`/`X-TC-Version`/`X-TC-Timestamp`/`Authorization`；`X-TC-Region` 默认不带。

### 2) 接入混元生文：翻译与对话
- 新增 `lib/ai/hunyuan/`：
  - `hunyuan_text_client.dart`：
    - `chatCompletions(...)` → 供智能问答使用（Action=ChatCompletions）。
    - `chatTranslations(...)` → 供翻译使用（Action=ChatTranslations）。
- 翻译侧：新增 `HunyuanTranslationEngine implements TranslationEngine`，内部调用 `ChatTranslations`。
- 在 [translation_provider.dart](file:///c:/Users/28679/traeProjects/AirRead/lib/presentation/providers/translation_provider.dart) 里默认使用 AI（不再提供“翻译引擎”切换），并用混元引擎替换现有 Volc 引擎注入。

### 3) 接入混元生图 Lite（TextToImageLite）并落地“图文模式”最小可用
- 新增 `hunyuan_image_client.dart`：实现 `textToImageLite(prompt, ...)`。
- ReaderPage 增加图文模式渲染分支（目前只有暂停翻译/朗读）：
  - 最小版本：从当前页文本构造 prompt → 调 `TextToImageLite` → 展示图片 + 当前页文本。
  - 做简单缓存（章节+页码+prompt hash），避免重复生成。

### 4) 接入语音合成 TextToVoice + 播放
- 新增 `tencent_tts_client.dart`：调用 `tts.tencentcloudapi.com` 的 `TextToVoice` 返回 base64 音频。
- 增加 Web/移动端的音频播放实现（选一个项目已支持/可引入的播放依赖），把右下角播放按钮接到 `play/stop`。

### 5) AI 伴读面板增加“腾讯混元设置”入口（右侧按钮）
- 在 AI 伴读面板 header 右侧增加设置按钮，进入“腾讯混元设置”页。
- 设置页内容：
  - 标题：腾讯混元大模型
  - 说明：如何开通/创建密钥（按你给的路径：先开通服务页，再到 CAM 密钥页创建）。
  - 开关：使用公共凭证（默认开）/使用自定义
  - 自定义输入框：AppId、SecretId、SecretKey
  - “连通性测试”：调用一次 ChatCompletions 返回测试文本。
- 新增 `TencentHunyuanConfigProvider`：SharedPreferences 持久化“是否自定义 + 3 个字段”。

## 关于“公共凭证写死 + 加密/解密”
- 按你的要求：公共 SecretId/SecretKey 以“加密/混淆后的常量”形式写在代码里，运行时解密使用。
- 说明：这类客户端可逆加密只能降低脚本化抓取难度，无法从根本上防逆向盗取；如果后续要真正保护额度，建议改为你自己的后端代签/代理。

## 验证方式
- Web 本地跑通：
  - 翻译开关生效后正文能走混元 ChatTranslations。
  - AI 问答面板发送后能返回真实回复。
  - 图文模式能生成并展示 TextToImageLite 图片。
  - 朗读按钮能合成并播放 TextToVoice 音频。
- 任一接口鉴权/配额/参数报错：在 UI 中展示可读错误信息，便于你调试。

如果你确认这版方案，我会按上述顺序落地：先“设置面板 + 翻译(ChatTranslations) + 问答(ChatCompletions)”跑通，再接入生图 Lite 与 TTS。