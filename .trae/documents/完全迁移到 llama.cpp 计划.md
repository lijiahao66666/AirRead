## 迁移计划概述

基于代码分析，我将执行以下完全迁移：

### 1. 重写 ai_model_provider.dart
- 移除所有 MNN 相关代码（LocalLlmClient 导入和使用）
- 统一使用 LlamaCppClient
- 简化本地模型管理（只保留 QA 模型，移除翻译模型）
- 重写下载逻辑：直接下载 GGUF 文件，无需解压
- 重写运行时状态检查：统一使用 llama.cpp

### 2. 重写 qa_service.dart
- 使用 LlamaCppClient 替代 LocalLlmClient
- 简化 _askLocalModel 方法

### 3. 删除 MNN 相关文件
- local_llm_client.dart（MNN 客户端）
- local_translation_engine.dart（已删除）
- mnn_bridge.cpp（已删除）

### 4. 保留的文件
- llama_cpp_client.dart（llama.cpp 客户端）
- llama_cpp_dart 依赖

### 关键变更点：

**ai_model_provider.dart 变更：**
1. 移除 LocalLlmClient 导入
2. 移除 LocalLlmModelType 枚举依赖，改为简单的 bool 状态管理
3. 重写 refreshLocalRuntimeStatus() - 统一使用 llama.cpp
4. 重写 _runLocalModelSmokeOnce() - 使用 LlamaCppClient.generate()
5. 重写 _startSingleLocalModelDownload() - 直接下载 GGUF，无需解压
6. 移除所有 zip 解压相关代码

**qa_service.dart 变更：**
1. 导入 llama_cpp_client.dart 替代 local_llm_client.dart
2. 重写 _askLocalModel() - 使用 LlamaCppClient.generateStream()