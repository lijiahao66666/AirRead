---
name: airread-ai-fixes-plan
overview: 修复 AI 问答提示词与阅读范围、Web 流式展示、思考区样式与折叠、会话持久化与新话题、AI 设置与图文隐藏、翻译术语/上下文一致性与自动术语提取等需求。
design:
  architecture:
    framework: react
    component: shadcn
  styleKeywords:
    - 现代简洁
    - 高可读性
    - 卡片化
    - 轻量动效
  fontSystem:
    fontFamily: PingFang SC
    heading:
      size: 24px
      weight: 600
    subheading:
      size: 16px
      weight: 500
    body:
      size: 14px
      weight: 400
  colorSystem:
    primary:
      - "#3B82F6"
      - "#2563EB"
    background:
      - "#F7F8FA"
      - "#FFFFFF"
    text:
      - "#111827"
      - "#6B7280"
    functional:
      - "#22C55E"
      - "#EF4444"
      - "#F59E0B"
todos:
  - id: scan-repo
    content: 使用 [subagent:code-explorer] 扫描问答、流式与会话相关文件
    status: completed
  - id: prompt-scope
    content: 调整提示词拼装与阅读范围限制为当前书籍
    status: completed
    dependencies:
      - scan-repo
  - id: streaming-thought
    content: 优化 Web 流式展示与思考区样式及折叠交互
    status: completed
    dependencies:
      - scan-repo
  - id: session-newtopic
    content: 完善会话持久化与新话题流程与按钮位置
    status: completed
    dependencies:
      - scan-repo
  - id: ai-settings-terms
    content: 更新 AI 设置：图文隐藏与自动术语提取默认开启
    status: completed
    dependencies:
      - scan-repo
  - id: term-consistency
    content: 优化术语一致性与自动提取不覆盖规则
    status: completed
    dependencies:
      - ai-settings-terms
  - id: copy-input
    content: 更新欢迎词文案与回车发送行为
    status: completed
    dependencies:
      - scan-repo
---

## Product Overview

对 airread 的 AI 问答、阅读范围、流式展示与会话能力进行修复与优化，保证提问范围一致、显示更清晰、设置更可控。

## Core Features

- 问答提示词按“系统指令 + 当前阅读内容片段 + 最近 N 轮历史问答摘要/最近 N 轮 + 用户问题”组合，且问答历史仅限当前书籍
- Web 端流式展示稳定可读，支持思考区样式优化与折叠/展开
- 会话持久化与“新话题”流程完善，按钮位于输入框上方
- AI 设置中将图文设置隐藏，ai伴读面板将图文隐藏，自动术语提取（默认开启），术语表仅限当前书籍且新增不覆盖已有
- 翻译术语与上下文一致性优化，欢迎词文案更新为“回答基于当前阅读内容的问题”

## Tech Stack

- 复用现有项目技术栈与组件体系
- 维持现有状态管理与存储方案

## Module Division

- **AI 问答模块**：提示词拼装、上下文与历史控制
- **流式展示模块**：Web 流式输出、思考区渲染与折叠
- **会话与设置模块**：会话持久化、新话题、AI 设置与术语配置

## Design Style

采用现代简洁风格，强调阅读场景的专注与层级清晰。输入区与快捷操作集中在底部上方区域，思考区为半透明卡片式，支持折叠态与展开态平滑过渡。流式输出使用轻量动效提示生成中状态，整体保持低干扰与高可读性。

## Page Planning

- **阅读问答页**：顶部导航、阅读内容区、问答流式输出区、思考区卡片、输入区与快捷操作区
- **AI 设置弹窗**：开关项与术语设置区域，含默认开启提示
- **术语表页/面板**：列表与新增术语输入区域

## Block Design (阅读问答页)

1. 顶部导航：书名与当前阅读位置提示，轻量阴影与固定定位。
2. 阅读内容区：主内容高对比排版，段落间距清晰。
3. 问答流式输出区：气泡式输出，带生成中动效指示。
4. 思考区卡片：浅色背景、边框虚化，折叠按钮置右上。
5. 输入与快捷操作区：新话题与快捷按钮在输入框上方，输入框支持回车发送。

## Agent Extensions

### SubAgent

- **code-explorer**
- Purpose: 扫描项目目录与关键文件以定位现有问答、流式展示与会话逻辑
- Expected outcome: 形成可复用的修改点清单与依赖关系