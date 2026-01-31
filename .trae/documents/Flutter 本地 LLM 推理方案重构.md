## 问题分析

当前问题：
1. `fllama` 插件版本过旧 (v0.0.1)，存在 iOS Metal 兼容性问题
2. `llama_cpp` 插件 (v1.2.0) 虽然较新，但仍可能在 iOS 上遇到内存限制
3. 模型下载链接不稳定

## 推荐方案

### 1. 更换 Flutter 插件

**推荐：`llama_cpp_dart`**
- 这是一个 Dart 绑定库，直接绑定 llama.cpp
- 更灵活，可以自定义编译选项
- 支持禁用 Metal GPU，避免内存问题

**备选：`fllama` 最新版**
- 检查是否有更新版本修复了 iOS 问题

### 2. 推荐模型（从 ModelScope 下载）

| 模型 | 大小 | 特点 | ModelScope 链接 |
|------|------|------|-----------------|
| **Qwen2.5-0.5B-Instruct-GGUF** | ~300MB | 最新 Qwen2.5，中文优秀，最小版本 | `https://modelscope.cn/models/qwen/Qwen2.5-0.5B-Instruct-GGUF/resolve/master/qwen2.5-0.5b-instruct-q4_0.gguf` |
| **Qwen2.5-1.5B-Instruct-GGUF** | ~900MB | 更好的性能，适合中高端手机 | `https://modelscope.cn/models/qwen/Qwen2.5-1.5B-Instruct-GGUF/resolve/master/qwen2.5-1.5b-instruct-q4_0.gguf` |
| **Phi-4-mini-GGUF** | ~2GB | 微软最新小模型，英文优秀 | `https://modelscope.cn/models/okwinds/Phi-4-mini-GGUF/resolve/master/phi-4-mini-q4_0.gguf` |

**首选：Qwen2.5-0.5B-Instruct-GGUF**
- 只有 0.5B 参数，Q4_0 量化后约 300-400MB
- 2024年底最新发布，性能优秀
- 中文支持好
- 适合手机端推理

### 3. 实施步骤

1. **移除现有插件**：删除 `fllama` 和 `llama_cpp`
2. **添加 `llama_cpp_dart`**：`flutter pub add llama_cpp_dart`
3. **更新模型 URL**：使用 Qwen2.5-0.5B 的 ModelScope 链接
4. **优化内存参数**：
   - 禁用 GPU: `nGpuLayers: 0`
   - 小上下文: `nCtx: 128` (足够用于简单对话)
   - 单线程: `nThread: 1`
5. **测试验证**

### 4. 预期结果

- 模型大小：~350MB
- 内存占用：~500MB
- 推理速度：可接受（CPU 模式）
- 兼容性：iOS/Android 都支持

请确认这个方案后，我将开始实施具体的代码修改。