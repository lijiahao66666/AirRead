## 问题定位（已确认）

* 朗读开关当前只切换“启用/不启用”，不会触发播放；且图文开启时会隐藏右下角播放按钮并禁止开始播放，所以用户会感觉“没反应”。

* 图文开启时现在只“暂停”翻译/朗读，但不会把它们的开关置为关闭；关闭图文时还会按翻译开关状态自动恢复翻译应用。

## 目标行为（按你的描述落地）

* 图文开启后：翻译开关与朗读开关都应自动关闭（并停止/撤销正在生效的功能），且关闭图文后不自动恢复其它开关。

* 公共凭证与自定义凭证互斥：任意一个打开会自动关闭另一个；默认两者都关闭。

* 检查配置仅在“使用自定义凭证”打开时可用；放在开关旁边的小按钮，成功后变为对勾状态。

* AI 伴读右侧“设置”文案改为“大模型设置”（包含相关 tooltip/标题/文案）。\
  ai伴读右侧设置图标修改一个更好好看，并符合当前ui风格的图标。\
  实现步骤（不改变你现有结构，做最小侵入改造）

### 1) 修复阅读页三开关状态机（核心逻辑）

在 ReaderPage 的三个 setter 中统一约束：

* `_setAiImageTextEnabled(enabled: true)`：

  * 强制关闭翻译（`_aiTranslateEnabled=false` + `TranslationProvider.setApplyToReader(false)` + prefs 持久化）。

  * 强制关闭朗读（`_aiReadAloudEnabled=false` + stop 播放 + 清空当前朗读 key + prefs 持久化）。

  * 最后才打开图文（`_aiImageTextEnabled=true`）。

* `_setAiTranslateEnabled(enabled: true)`：若图文开着先关闭图文（只关图文，不动朗读）。

* `_setAiReadAloudEnabled(enabled: true)`：若图文开着先关闭图文；并让“打开朗读开关”产生可感知反馈：

  * 方案 A（推荐）：开=立即开始朗读当前页、关=停止朗读（更符合你反馈“没反应”）。

  * 方案 B：仍不自动播放，但在 UI 上提示“朗读按钮已开启”，并确保图文模式下该开关不可打开。
    （我会按方案 A 实现，体验更直观。）

### 2) 调整 AI 伴读主面板的“设置”文案

* 将每个 feature row 右侧的 `tooltip: '设置'` 改为 `tooltip: '大模型设置'`。

* 顶部齿轮入口 tooltip 与路由标题：`腾讯混元设置` 改为 `大模型设置`；并同步替换所有引用“腾讯混元设置”的提示语。

### 3) 重做“大模型设置”UI（在 AI HUD 内的 tencentSettings 路由）

把当前 `_TencentHunyuanSettingsPanel` 改成新交互：

* 第一行：左侧“腾讯混元大模型”，右侧两个互斥开关：

  * 「使用公共凭证」(默认 off)

  * 「使用自定义凭证」(默认 off) + 旁边一个小问号按钮（点击弹出“开通方式”提示）

* 第二行：小字提示“其他模型正在接入...”

* 当“使用自定义凭证”打开时：

  * 显示 AppId/SecretId/SecretKey 输入框

  * 在该开关右侧显示“检查”小按钮；检查成功后按钮变为对勾（状态持久化或至少本次会话保持）

* 当“使用公共凭证”打开时：

  * 不展示输入框

  * 给出轻量提示（例如“公共凭证已启用”）

### 4) Provider 改造：支持 usePublic/useCustom 互斥 + 默认都关闭

修改 `TencentHunyuanConfigProvider`：

* 新增 `_usePublic`（并保留 `_useCustom`），两者互斥；提供 `setUsePublic/setUseCustom`，内部做互斥切换与持久化。

* `effectiveCredentials`：

  * useCustom -> customCredentials

  * usePublic -> embeddedPublicCredentials

  * 两者都 false -> 返回空凭证（使 hasUsableCredentials=false）

* hasUsableCredentials 只基于当前选择的凭证判断。

### 5) 写死公共凭证（加密后写入）

* 使用现有 `embedded_public_hunyuan_credentials.dart` 的 enc:base64(XOR) 方案把你提供的 SecretId/SecretKey 加密成字符串常量写入 `_publicSecretIdEnc/_publicSecretKeyEnc`。

* 我不会在代码或输出中明文展示这两个值；只会写入加密后的 enc: 串。

## 验证方式

* 本地 Web 启动后：

  * 打开图文：确认翻译/朗读开关立刻关闭且不再自动恢复。

  * 打开翻译后再开朗读：确认朗读能立即开始/停止且不受翻译影响。

  * 在大模型设置里切换公共/自定义：确认互斥、默认都 off、问号提示可弹出、检查按钮只在自定义开启时出现且可变为对勾。

## 额外说明（安全）

* 你在聊天里给出的 SecretId/SecretKey 我不会在任何输出中重复展示；实现时只把加密后的结果写进仓库常量。

