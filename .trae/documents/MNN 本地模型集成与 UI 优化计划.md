# MNN 本地模型集成与 UI 优化计划

## 1. 交互与 UI 调整

### AI 伴读面板

* **AI 问答**：移除右侧的“快捷语”标签/文字。

* **本地下载状态**：

  * **下载中**：

    * 右侧操作区显示为“暂停”（文字按钮）。

    * 点击“暂停” -> 下载任务暂停 -> 文字变为“继续”。

    * 点击“继续” -> 下载任务恢复 -> 文字变为“暂停”。

    * *注：原计划的百分比显示位置需调整，或与操作按钮并存。*

  * **未下载/已下载**：保持之前的优化（未下载显示“下载”按钮，已下载仅显示提示文本）。

## 2. 移动端本地模型运行方案 (MNN 集成)

### Web 端本地模型限制

* **原因**：Web 端（浏览器环境）无法直接访问设备文件系统（path\_provider 不支持），且运行大型语言模型（LLM）需要 WebGPU/WASM 等高性能计算支持，目前的 Flutter Web 架构和 MNN 移动端库主要针对 Native (Android/iOS) 优化。

* **现状**：在 Web 端暂时禁用本地模型功能，或仅作为“在线模式”的控制台。

### MNN 集成方案 (Android/iOS)

* **调研结论**：MNN (Alibaba) 支持在移动端运行 LLM，包括混元模型，但需要进行**模型转换**（转为 `.mnn` 格式）并编写 **C++ Native Bridge**。

* **实施步骤**：

  1. **模型转换**：(需用户自行操作或提供已转换模型) 使用 MNN 的 `llm_export` 工具将 HuggingFace 格式的混元模型转换为 `model.mnn`。
  2. **Native 依赖集成**：

     * **Android**：配置 CMake，引入 `libMNN.so` 和 `libMNN_LLM.so`。

     * **iOS**：配置 Pods 或手动引入 MNN Framework。
  3. **JNI/ObjC Bridge**：编写 C++ 代码调用 MNN LLM 接口（`init`, `chat`, `response`），暴露给 Dart 端。
  4. **Flutter MethodChannel**：在 `LocalLlmClient` 中实现 `MethodChannel` 调用，替换当前的模拟/空实现。

## 3. 下一步执行计划 (本次任务)

1. **UI 优化**：修改 `ai_hud.dart`，移除“快捷语”，实现下载/暂停/继续的交互逻辑。
2. **下载器增强**：修改 `AiModelProvider`，支持**暂停/恢复**下载（利用 HTTP Range 头），并正确管理状态（`downloading`, `paused`）。
3. **本地模型架构搭建**：

   * 虽然无法直接为您编译 `.so` 库，但我将生成完整的 **Native 集成代码**（`CMakeLists.txt`, `mnn_bridge.cpp`, `MainActivity.kt` 等）并写入项目，您只需放入对应的 MNN 库文件即可编译运行。

   * 更新 `LocalLlmClient` 以使用 `MethodChannel` 调用 Native 接口。

**确认**：是否同意先完成 UI 交互优化和 Native 代码的生成？（实际运行需您配合放入模型文件和 MNN 库）
