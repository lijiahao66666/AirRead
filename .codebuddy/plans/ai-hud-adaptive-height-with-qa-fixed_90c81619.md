---
name: ai-hud-adaptive-height-with-qa-fixed
overview: AI HUD 改为“除问答外内容自适应高度 + 平滑动画 + 防抖防抖动”，AI问答保持现有高高度档位（约0.72屏高clamp）不变。
todos:
  - id: repo-scan-aihud
    content: 使用[subagent:code-explorer]定位AiHud实现、面板状态与现有问答高度档位代码
    status: completed
  - id: define-height-policy
    content: 梳理并固化高度策略：QA固定clamp + 非QA自适应min/max/阈值/防抖参数
    status: completed
    dependencies:
      - repo-scan-aihud
  - id: add-height-controller
    content: 新增自适应高度控制器hook，输出HUD容器高度style与回退逻辑
    status: completed
    dependencies:
      - define-height-policy
  - id: wire-non-qa-panels
    content: 将主面板/设置类面板接入内容ref测量与稳定后的目标高度
    status: completed
    dependencies:
      - add-height-controller
  - id: preserve-qa-behavior
    content: 问答面板走原固定高度链路，切换到QA时强制目标高度为现有档位
    status: completed
    dependencies:
      - add-height-controller
  - id: apply-smooth-animation
    content: 为HUD高度变化添加平滑过渡与可降级策略（减少动态偏好）
    status: completed
    dependencies:
      - wire-non-qa-panels
      - preserve-qa-behavior
  - id: verify-jitter-cases
    content: 覆盖抖动场景验证：快速输入/加载/字体图片就绪/频繁切换，确保高度稳定
    status: completed
    dependencies:
      - apply-smooth-animation
---

## Product Overview

AI HUD：除“AI问答”外的各内容面板高度根据内容自适应，采用平滑动画过渡，并通过阈值/防抖/节流避免高度频繁微调导致抖动；“AI问答”面板继续保持现有高高度档位（约 0.72 屏高 clamp）不变。

## Core Features

- **问答高度保持不变**：进入/切换到 AI 问答时，HUD 高度沿用现有固定档位与 min/max clamp 策略，视觉表现与当前一致。
- **非问答面板自适应高度**：主面板/翻译设置/术语表/朗读设置/图文设置等内容区高度随内容变化自动更新，尽量贴合内容但不超出可用视区约束。
- **平滑高度动画**：HUD 容器高度变化采用连续过渡（展开/收起/内容增减），避免“瞬间跳变”的卡顿观感。
- **防抖与防抖动**：对细碎高度波动设置阈值（hysteresis）+ 防抖/节流，避免输入、加载、字体/图片就绪等引发的频繁抖动与闪动。

## Tech Stack

- 复用项目现有前端技术栈（通过代码仓库确认；通常为 React + TypeScript + CSS/Tailwind/组件库其一）

## Architecture Design（贴合现有项目结构，局部增强）

- 在 **AiHud 容器** 增加“高度控制层（Height Controller）”，统一处理：
- 模式判定：问答模式（固定档位） vs 非问答模式（内容高度驱动）
- 高度测量：对内容容器进行实时测量
- 高度稳定：阈值过滤 + 防抖/节流 + 最终高度锁定
- 动画应用：将目标高度以动画方式应用到 HUD 外层

```mermaid
flowchart TD
  A[面板切换/内容变化] --> B{是否AI问答?}
  B -- 是 --> C[使用现有固定高度档位<br/>clamp(~0.72vh, min/max)]
  B -- 否 --> D[测量内容高度<br/>ResizeObserver/scrollHeight]
  D --> E[阈值过滤/滞回<br/>忽略微小波动]
  E --> F[防抖/节流<br/>合并频繁更新]
  F --> G[计算目标高度<br/>含min/max与安全边距]
  C --> H[应用高度到HUD容器]
  G --> H[应用高度到HUD容器]
  H --> I[平滑过渡动画<br/>CSS transition或motion]
  H --> J[异常回退<br/>测量失败/为0时保留上次高度]
```

## Module Division（仅涉及新增/改动点）

- **AiHudHeightController（新增或内聚到AiHud）**
- 责任：维护 currentHeight/targetHeight、面板模式、测量订阅、稳定策略、动画触发
- 依赖：AiHud面板状态（当前tab/panel类型）、内容容器ref
- **ContentHeightMeasurer**
- 责任：对内容容器测量高度（优先 ResizeObserver；必要时兼容 scrollHeight + rAF）
- 输出：rawHeight（原始高度变化流）
- **HeightStabilizer**
- 责任：阈值/滞回、防抖/节流、边界clamp、回退策略
- 输出：stableTargetHeight（稳定后的目标高度）

## Implementation Details

### Core Directory Structure（以仓库实际结构为准，仅示例“可能会改到/新增”的文件）

```
project-root/
├── src/
│   ├── components/
│   │   └── ai-hud/
│   │       ├── AiHud.tsx                # 修改：接入高度控制
│   │       ├── useHudAdaptiveHeight.ts  # 新增：自适应高度hook/控制器
│   │       └── heightStabilizer.ts      # 新增：阈值/防抖/滞回算法
│   └── styles/
│       └── ai-hud.css                   # 修改：高度动画过渡样式（如需要）
```

### Key Code Structures（示例接口，按现有代码风格落地）

```ts
type HudPanelType = 'qa' | 'main' | 'translateSettings' | 'glossary' | 'ttsSettings' | 'mediaSettings';

interface HudHeightPolicy {
  qaFixed: { enabled: true; vhClamp: { preferred: number; minPx: number; maxPx: number } };
  adaptive: { minPx: number; maxPx: number; paddingPx: number; thresholdPx: number; debounceMs: number; throttleMs: number };
}

interface UseHudAdaptiveHeightParams {
  panelType: HudPanelType;
  contentRef: React.RefObject<HTMLElement>;
  policy: HudHeightPolicy;
}

interface UseHudAdaptiveHeightResult {
  containerStyle: React.CSSProperties; // height / maxHeight / transition 等
}
```

## Technical Implementation Plan（关键点）

1) **问答固定高度不回归**

- Approach：保持现有 QA clamp 计算与档位逻辑原样；仅在“非QA”路径启用自适应
- Steps：识别现有 QA 高度来源 → 抽成 policy.qaFixed → 切到 QA 时强制 targetHeight=qaHeight
- Testing：QA 面板切换前后高度一致；窗口变化时仍按原 clamp 行为

2) **内容高度测量与稳定**

- Approach：ResizeObserver 订阅内容容器；输出 rawHeight；通过阈值/滞回过滤微小波动；防抖/节流合并更新；保留 lastStableHeight 作为回退
- Steps：实现 measurer → stabilizer → 生成 stableTargetHeight → 写入状态（尽量 rAF 合批）
- Testing：快速输入/加载列表/图片延迟加载时不抖动；高度不出现频繁 1~2px 来回跳

3) **平滑动画**

- Approach：对 HUD 外层容器 height 使用 transition（或项目已有 motion 方案），并确保切换面板时也走同一套 targetHeight 更新
- Steps：添加/复用动画样式 → 控制 height 只由 targetHeight 驱动 → 处理 prefers-reduced-motion
- Testing：切换面板无“瞬跳”；动画时长/缓动符合现有视觉

## Integration Points

- 与 AiHud 的“当前面板状态（tab/panelType）”集成：决定走 qaFixed 或 adaptive
- 与内容区域容器集成：提供 ref 以测量实际渲染高度
- 数据格式：内部状态与计算均为 number(px)，最终写入 style.height = `${px}px`

## Agent Extensions

- **SubAgent: code-explorer**
- Purpose: 在仓库中定位 AiHud 相关组件/样式/现有问答高度策略与切换链路，确认最小改动面与复用点
- Expected outcome: 输出关键文件清单、现有高度计算位置、面板类型枚举/状态来源、可直接复用的动画/样式方案