## 问题定位
- 现状：AiHud 内部用 AnimatedSwitcher 切换子面板，外层用 AnimatedSize 做面板高度动画（QA 为固定高度，非 QA 为内容自适应）。
- 关键原因：AnimatedSwitcher 默认 layoutBuilder 会用 Stack 按“最大子组件尺寸”布局；从“高子面板 → 主面板(更矮)”时，切换期间尺寸会先维持高面板 200ms，等旧 child 移除后才触发高度收缩动画，体感像“卡一下/停顿后再缩”。

## 方案
- 让高度变化与内容切换同步发生：为 AnimatedSwitcher 增加自定义 layoutBuilder，使其尺寸以 currentChild 为准，previousChildren 用 Positioned.fill 叠加（不参与 Stack 尺寸计算），并配合 IgnorePointer，避免交互穿透。
- 保持现有 AnimatedSize：这样在 route 变化的同一帧就会得到新的目标高度，AnimatedSize 立即开始动画，不再等待 200ms。
- 可选微调：统一 AnimatedSwitcher 与 AnimatedSize 的时长/曲线（例如都用 220–240ms，easeOutCubic），进一步减少“先淡出再缩”的割裂感。

## 具体改动点
- 修改 [ai_hud.dart]：
  - 在 AnimatedSwitcher(...) 中新增 layoutBuilder：
    - Stack(children: [ ...previousChildren Positioned.fill + IgnorePointer, if (currentChild!=null) currentChild ])
    - 使 Stack 尺寸由 currentChild 决定。
  - 如有必要，在 body 外再包一层 ClipRect（确保旧面板在尺寸变小时不会溢出）。

## 验证方式
- 本地运行后在阅读页：
  - 打开 AI 伴读 → 进入“翻译设置/朗读设置/图文设置”任一较高面板 → 返回主面板。
  - 期望：返回时高度收缩与淡出/滑动同时进行，无明显停顿；多次快速切换也保持顺滑。
- 打开系统“减少动态效果/无动画”时：
  - 期望：所有动画时长为 0，不出现异常布局。

## 风险与回滚
- 风险：previousChildren 被 Positioned.fill 重新约束，若某子面板依赖特定高度可能需要加滚动/约束修正。
- 回滚：仅涉及 AiHud 的切换布局逻辑，随时可恢复默认 AnimatedSwitcher 行为。