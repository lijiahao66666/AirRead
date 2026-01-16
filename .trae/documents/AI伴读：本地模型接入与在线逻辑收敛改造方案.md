## 目标
- 引入“端侧离线模型”Hunyuan-0.5B-Instruct-AWQ-Int4，支持翻译与智能问答（离线可用）。
- 在线模型去掉“自定义凭证”逻辑，只保留统一的在线调用通道（短期沿用内置凭证，长期建议代理后端）。
- 把“大模型开关/模型来源选择”前置到 AI 伴读面板，作为三个功能开关的总闸与前置步骤。
- 清理旧的机器翻译代码与失效的 engineType 分流，统一到“LLM 引擎”架构。

## 架构改造
- 新增统一抽象：
  - I LlmClient：send(messages)→stream/text；两种实现：OnlineHunyuanLlmClient（保留现有在线逻辑）与 LocalLlmClient（离线推理）。
  - TranslationEngine 继续沿用，但去掉 machine/ai 双分支，仅保留 LlmTranslationEngine（注入 LlmClient）。
- TranslationService 简化：
  - 移除 engineType 分支与 batch-only 逻辑，统一通过一个 engine；保留缓存构建、术语占位符与 in-flight 去重<mccoremem id="03femjrtkhrwtedkpxfrx78sm"/>。
  - _validateEngineConfig 改为依据“模型来源 + 准备状态”：在线→需要凭证可用；本地→需要模型已下载且 runtime 就绪。
- Provider 层：
  - TranslationProvider 增加 modelSource 字段（none/local/online），作为三类能力的前置 gate；去掉 setEngineType 的强制 ai 回写。
  - _rebuildService 按 modelSource 注入 OnlineHunyuanLlmClient 或 LocalLlmClient。

## 在线模型收敛
- 移除“自定义凭证”代码与 UI：
  - 删除 TencentHunyuanConfigProvider 中 useCustom/secretId/secretKey 持久化与相关计算（effectiveCredentials 仅保留公共/统一通道）。
  - AiHud 的 _TencentHunyuanSettingsPanel 去掉自定义凭证输入与检查按钮，仅保留“在线模型说明/费用提示”。
- 安全建议（中期）：将在线调用改为经服务端代理签名/计费，不在客户端存放任何密钥；此改造为后续收费与风控留口（本次代码先维持现状）。

## 本地模型接入（推理）
- 模型文件：首次启用“本地模型”时检查 Documents/models/hunyuan/model.safetensors 是否存在；否则弹窗说明与下载。
- 推理后端选型（Flutter 端侧）：
  - 优先方案：Rust+FFI 使用 Candle 加载 safetensors（支持 AWQ），构建 LocalLlmClient，暴露 generate/text 与 chat 接口。
  - 备选方案：若后端因平台受限，改用预转换的 GGUF + llama.cpp 通过 FFI；下载链接需替换为 GGUF 版本。
- 翻译实现：LocalLlmTranslationEngine 用“指令模板 + 段落文本”进行翻译（保留术语占位与上下文缓存），统一走 TranslationService 的缓存键生成<mccoremem id="03femjrtkhrwtedkpxfrx78sm"/>。
- 问答实现：AiHud 的发送逻辑新增 LocalLlmClient 路径；在线/本地共享同一 ChatViewModel，但按 modelSource 分流。

## 下载与存储
- 下载管理器：
  - 使用 http 流式下载 + Content-Length 进度；支持断点续传（Range）与失败重试；下载完成后写入临时文件再原子移动到目标路径。
  - 完整性校验：保存 SHA256（若官方提供）或至少校验大小；失败则清理并重试。
- 路径：Documents/models/hunyuan/model.safetensors（path_provider）。
- UI：在 AiHud 主面板的“本地模型”开关旁显示状态与进度条；失败状态给出重试按钮。

## AI 伴读面板 UX
- 主面板顶部新增“模型来源”单选：未选择/本地/在线；默认未选择。
- 三个功能开关的 gating：
  - 未选择模型来源→三个开关禁用并展示提示文案。
  - 选择本地→启用“翻译/问答”；“图文生成”禁用（当前只在线）。朗读保持在线 TTS，需明确费用提示。
  - 选择在线→启用全部，但首次开启弹收费提示与条款确认。
- 入口合并：保留“翻译设置”作为细项；“大模型设置”缩减为“在线模型说明/费用/跳后端签约”的说明入口。

## 旧代码清理
- 删除未接入的引擎文件：google_translator_engine.dart、microsoft_translator_engine.dart、libre_translate_engine.dart。
- 移除 machine/ai 的历史分流：
  - TranslationProvider.setEngineType 与相关 prefs（_kCfgEngine）字段。
  - TranslationService.translateParagraphs 中 machine 分支（batch）不可达路径一并收敛到统一实现。
- 验证引用：确认 ReaderPage 与 TranslationSheet 不再依赖 engineType；改为依赖 modelSource 与 aiTranslateEnabled。

## 行为与错误提示
- 在线模型：开启时弹窗“可能产生费用/后续计费”，并允许一次性确认；无凭证（或代理不可用）时给出统一错误文案。
- 本地模型：未下载→弹窗说明大小与存储占用；下载失败→SnackBar + 重试；运行失败→提示“本地推理后端异常”。
- 离线可用：无网络时只允许本地模型；若当前为在线则提示切换或保持不可用。

## 测试与回归
- 单元测试：
  - TranslationService 缓存键一致性/术语占位流程/并发去重。
  - Provider gating：modelSource 切换对三个开关与 ReaderPage 的影响。
- 集成测试：
  - 本地模型下载流程（成功/失败/断网恢复）。
  - 在线模型费用提示与错误处理。
- 手工回归：
  - AiHud 主面板交互路径；翻译/问答在两种模型来源下的可用性与渲染结果。

## 交付与渐进替换
- 第一版交付：完成 UI/Provider/Service 收敛 + 下载器 + LocalLlmClient FFI 框架（最低可跑通 CPU 推理）。
- 后续迭代：性能优化（流式输出、缓存上下文）、多平台兼容（Android/iOS/macOS/Windows）。
