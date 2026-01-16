---
name: fix-compilation-errors
overview: 根据用户提供的错误日志，修复翻译模块和 UI 代码中的一系列编译错误。
todos:
  - id: explore-codebase
    content: 使用 [subagent:code-explorer] 探查项目结构，定位所有待修复文件
    status: completed
  - id: fix-types
    content: 修复 `types/index.ts` 文件，为 `Translator` 接口添加缺失的 `translate` 方法
    status: completed
    dependencies:
      - explore-codebase
  - id: fix-engine-instantiation
    content: 修复 `services/engine.ts`，确保 `TranslateService` 类能被正确导出和实例化
    status: completed
    dependencies:
      - explore-codebase
  - id: fix-translation-provider
    content: 修复 `components/provider.tsx`，为 `createContext` 提供正确的默认值并在 `value` 中传递 `engine`
    status: completed
    dependencies:
      - fix-types
      - fix-engine-instantiation
  - id: fix-ai-hud-component
    content: 修复 `components/ai-hud.tsx`，添加上下文消费的空值保护并修正 `onTranslate` 属性类型
    status: completed
    dependencies:
      - fix-translation-provider
---

## 产品概述

本计划旨在根据用户提供的编译错误日志，修复项目中翻译模块和相关 UI 组件的代码问题，以确保项目能够成功编译和运行。

## 核心修复任务

- **翻译引擎修复**：解决在 `services/engine.ts` 文件中，`TranslateService` 类无法被正确实例化为构造函数的问题。
- **类型定义修正**：在 `types/index.ts` 文件中，为 `Translator` 类型补充缺失的 `translate` 方法定义，确保类型完整性。
- **AI HUD 组件修复**：处理 `components/ai-hud.tsx` 组件中因翻译上下文（Context）为空导致的 `TypeError`，并修正 `onTranslate` 属性的类型定义。
- **服务提供者修复**：在 `components/provider.tsx` 文件中，为 `createContext` 提供合法的默认值，并确保在 `TranslateProvider` 的 `value` 中正确传递 `engine` 属性。

## 技术栈选型

该项目为现有项目，我们将沿用其当前的技术栈进行问题修复，推断为基于 React 和 TypeScript 的前端应用。

## 架构设计

### 现有项目分析

本次任务是修复现有代码中的编译错误，重点在于理解并修正已有逻辑，而非引入新架构。我们将精确地修改涉及错误的文件，保持项目原有的结构和设计模式。

### 模块划分

根据错误日志，本次修改将涉及以下核心模块：

- **翻译引擎模块 (`services/engine.ts`)**: 负责实现核心的文本翻译逻辑。
- **类型定义模块 (`types/index.ts`)**: 统一定义项目中使用的 TypeScript 类型，特别是与翻译功能相关的类型。
- **UI 组件模块 (`components/ai-hud.tsx`)**: 显示翻译结果并提供交互的用户界面。
- **上下文提供者模块 (`components/provider.tsx`)**: 通过 React Context 为子组件提供翻译服务的实例。

## 实施细节

### 核心目录结构

我们将重点修改以下文件，不会新增文件或目录：

```
airread/
└── src/
    ├── services/
    │   └── engine.ts      # 待修复：翻译服务实例化问题
    ├── types/
    │   └── index.ts       # 待修复：翻译器类型定义缺失
    └── components/
        ├── ai-hud.tsx     # 待修复：上下文使用和属性类型错误
        └── provider.tsx   # 待修复：上下文创建和值提供问题
```

### 关键代码结构与修复方案

#### 1. 问题：`types/index.ts` - 类型定义不完整

- **问题描述**: `Translator` 接口缺少 `translate` 方法的定义。
- **解决方案**: 为 `Translator` 接口添加 `translate` 方法签名。

```typescript
// types/index.ts
export interface Translator {
  // ... 其他属性
  translate: (text: string) => Promise<string>; // 新增此行
}
```

#### 2. 问题：`services/engine.ts` - 服务类导出与实例化错误

- **问题描述**: `TranslateService` 可能被错误地导出或实例化，导致 "is not a constructor" 错误。
- **解决方案**: 确保 `TranslateService` 是一个类，并使用 `new` 关键字进行实例化。如果它是单例模式，则导出实例而非类本身。

```typescript
// services/engine.ts
export class TranslateService {
  // ... 实现
}

// 确保在其他地方使用 new TranslateService() 来创建实例
```

#### 3. 问题：`components/provider.tsx` - 上下文创建与提供错误

- **问题描述**: `createContext` 的默认值为 `null`，且提供给 `Provider` 的 `value` 对象中缺少 `engine` 属性。
- **解决方案**: 为 `createContext` 提供一个符合接口的默认值，并在 `TranslateProvider` 中完整地提供 `value`。

```typescript
// components/provider.tsx
import { TranslateService } from '../services/engine';

// 提供一个安全的默认值
const defaultContextValue = {
  t: (text: string) => text, // 提供一个默认的翻译函数
  engine: new TranslateService() // 提供一个默认的引擎实例
};
export const TranslateContext = createContext(defaultContextValue);

// 在 Provider 中确保 value 完整
// ...
const engine = new TranslateService();
return (
  <TranslateContext.Provider value={{ t: i18n.t, engine }}>
    {children}
  </TranslateContext.Provider>
);
```

#### 4. 问题：`components/ai-hud.tsx` - 上下文消费与属性类型错误

- **问题描述**: 在未被 `TranslateProvider` 包裹的场景下使用 `use(TranslateContext)` 导致空指针异常，并且 `onTranslate` 属性的类型与预期不符。
- **解决方案**: 在使用 `use(TranslateContext)` 之前进行空值检查，并修正 `onTranslate` 的类型定义。

```typescript
// components/ai-hud.tsx
const translateContext = use(TranslateContext);
// 添加保护，防止上下文为空
if (!translateContext) {
    throw new Error("AIHud must be used within a TranslateProvider");
}
const { t } = translateContext;

// 修正 onTranslate 的类型
interface AIHudProps {
  onTranslate: (text: string) => void; // 假设 onTranslate 是一个不返回 Promise 的回调
}
```

## Agent Extensions

### SubAgent

- **code-explorer**
- **用途**: 用于在 `airread` 项目中搜索和分析与错误日志相关的代码文件。它将帮助我们快速定位 `engine.ts`、`index.ts`、`ai-hud.tsx` 和 `provider.tsx` 文件，并理解它们当前的实现细节和相互之间的依赖关系。
- **预期结果**: 获取到上述四个文件的准确路径和内容，为后续的代码修复提供精确的上下文信息，确保修复方案的准确性。