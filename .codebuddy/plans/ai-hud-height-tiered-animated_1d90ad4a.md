---
name: ai-hud-height-tiered-animated
overview: 将 AI 伴读 HUD 改为三档固定高度（主面板矮/翻译设置中/术语表&问答高），并用动画过渡消除切换时的跳变，同时保持内部滚动与返回层级不变。
design:
  architecture:
    framework: react
  styleKeywords:
    - Bottom-sheet HUD
    - Smooth height transition
    - Stable scrolling
    - Reduced motion friendly
  fontSystem:
    fontFamily: PingFang SC
    heading:
      size: 16px
      weight: 600
    subheading:
      size: 14px
      weight: 600
    body:
      size: 14px
      weight: 400
  colorSystem:
    primary:
      - "#3B82F6"
      - "#6366F1"
      - "#22C55E"
    background:
      - "#0B1220"
      - "#111827"
      - "#FFFFFF"
    text:
      - "#E5E7EB"
      - "#111827"
      - "#9CA3AF"
    functional:
      - "#22C55E"
      - "#F59E0B"
      - "#EF4444"
todos:
  - id: scan-hud-structure
    content: 使用[subagent:code-explorer]定位HUD外壳、面板切换与返回栈实现
    status: completed
  - id: define-height-tiers
    content: 新增三档高度常量与面板到档位映射
    status: completed
    dependencies:
      - scan-hud-structure
  - id: animate-hud-shell-height
    content: 在HUD外壳实现高度动画与可打断切换
    status: completed
    dependencies:
      - define-height-tiers
  - id: preserve-scroll-behavior
    content: 确保内部滚动容器不变且切换不重置滚动
    status: completed
    dependencies:
      - animate-hud-shell-height
  - id: keep-nav-stack-unchanged
    content: 确保前进/返回层级与面板状态不因动画变化
    status: completed
    dependencies:
      - animate-hud-shell-height
  - id: reduced-motion-support
    content: 增加reduced-motion降级策略避免不适与抖动
    status: completed
    dependencies:
      - animate-hud-shell-height
  - id: polish-and-regression
    content: 回归验证三面板切换流畅度与无跳变
    status: completed
    dependencies:
      - preserve-scroll-behavior
      - keep-nav-stack-unchanged
      - reduced-motion-support
---

## Product Overview

AI 伴读 HUD 采用三档固定高度：主面板（矮）、翻译设置（中）、术语表&问答（高）。在面板切换时通过动画过渡消除高度跳变，同时保持现有的内部滚动行为与返回层级逻辑不变。

## Core Features

- **三档固定高度**：按面板类型锁定到矮/中/高三档，避免主面板内容少时“空高”。
- **高度平滑过渡**：切换面板时 HUD 外壳高度做连贯动画，视觉上无“卡一下/跳一下”。
- **滚动体验不变**：各面板内部依旧在自身滚动容器中滚动；外壳仅负责高度变化与裁切。
- **返回层级不变**：面板前进/返回的层级与状态保持原样，不因高度动画导致重置或闪烁。

## Tech Stack

- 沿用项目现有前端技术栈与组件体系（在仓库中确认现有动画/样式方案后复用）
- 动画优先使用现有方案：CSS transition（height）或项目已引入的 motion 库（若已存在）

## Architecture (Scope: HUD 高度与过渡的小范围改动)

- 在 HUD “外壳容器”引入 **Height Tier Controller**：
- 输入：当前激活面板类型（主/翻译设置/术语表&问答）
- 输出：目标固定高度（px 或 vh），以及过渡时长/曲线
- 保持面板内容层不卸载：仅改变外壳高度与 overflow 裁切，避免影响内部滚动与返回栈状态。

## Implementation Details

### Core Directory Structure (modified/new; 以仓库实际位置为准)

```
project-root/
├── src/
│   ├── components/ (or features/)
│   │   ├── ai-hud/
│   │   │   ├── HudShell.*          # 修改：三档高度 + 动画容器
│   │   │   ├── hudHeightTiers.*    # 新增/修改：高度常量与映射
│   │   │   └── *.css|*.scss        # 修改：过渡曲线、reduced-motion
```

### Key Code Structures (concept)

- `HudHeightTier = 'main' | 'translate-settings' | 'glossary-qa'`
- `HUD_HEIGHT_MAP: Record<HudHeightTier, number | string>`
- `getHudHeightTier(activePanelId): HudHeightTier`
- `HudShell({ activePanelId, navStack, ... })`：根据 tier 设置容器 `height`，并启用过渡

- **视觉效果**：HUD 在三档高度间顺滑伸缩（无突跳），面板内容区域保持稳定裁切与内部滚动；切换时顶部/边框/阴影连续过渡，避免“抖动”与闪白。
- **动效规范**：高度过渡 220–320ms，ease-out；交互频繁时保持可打断与连续（新目标高度覆盖旧动画）。支持 `prefers-reduced-motion` 降级为无动画或更短过渡。
- **布局约束**：三档高度为固定值（可按断点对桌面/移动端分别设定），外壳 `overflow: hidden`，内容区独立滚动容器 `overflow: auto`。

## Agent Extensions

### SubAgent

- **code-explorer**
- Purpose: 在仓库中定位 HUD 相关组件、面板路由/返回层级实现、现有样式与动画实现方式
- Expected outcome: 输出精确的改动文件清单与关键调用链，确保改动最小且不破坏滚动与返回逻辑