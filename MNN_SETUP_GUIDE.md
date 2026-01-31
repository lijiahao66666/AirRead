# MNN + MiniCPM iOS 集成指南

## 项目状态

✅ 已完成：
- iOS 桥接代码 (MnnLlmBridge.h/mm)
- Dart MNN 客户端 (mnn_client.dart)
- LlmClient MNN 实现 (llm_client.dart)
- AppDelegate.swift 方法通道配置
- QA Service 和 AI Model Provider 更新
- 模型配置文件

⏳ 待完成：
- 下载 MiniCPM-1B 模型并转换为 MNN 格式
- 编译/获取 MNN.framework for iOS
- iOS 构建和测试

---

## 1. 模型准备

### 1.1 下载 MiniCPM-1B 模型

由于网络限制，模型需要手动下载：

**方式一：从 HuggingFace 下载**
```bash
# 安装 huggingface-cli
pip install huggingface-hub

# 下载模型
huggingface-cli download openbmb/MiniCPM-1B-sft-bf16 \
  --local-dir ./minicpm-1b-original \
  --local-dir-use-symlinks False
```

**方式二：从 ModelScope 下载（国内推荐）**
```bash
# 安装 modelscope
pip install modelscope

# 下载模型
python -c "from modelscope import snapshot_download; \
  snapshot_download('OpenBMB/MiniCPM-1B-sft-bf16', \
  cache_dir='./minicpm-1b-original')"
```

### 1.2 转换为 MNN 格式

```bash
# 进入 MNN 项目
cd models/MNN

# 安装依赖
pip install torch transformers onnx

# 导出为 ONNX
cd project/llm-export
python export.py \
  --model_path /path/to/minicpm-1b-original \
  --output_path ./minicpm-1b.onnx

# 转换为 MNN
cd ../../build
./MNNConvert -f ONNX \
  --modelFile ../minicpm-1b.onnx \
  --MNNModel minicpm-1b.mnn \
  --bizCode MNN
```

### 1.3 模型文件结构

将转换后的文件放入应用：
```
AirRead/assets/models/minicpm-1b/
├── config.json          # 已创建
├── tokenizer.model      # 从原始模型复制
└── model.mnn            # 转换后的模型
```

---

## 2. MNN.framework 准备

### 2.1 编译 MNN.framework for iOS

```bash
# 进入 MNN 项目
cd models/MNN

# 编译 iOS 版本
mkdir -p build-ios && cd build-ios

cmake .. \
  -DCMAKE_TOOLCHAIN_FILE=../cmake/ios.toolchain.cmake \
  -DPLATFORM=OS64 \
  -DMNN_BUILD_SHARED_LIBS=ON \
  -DMNN_BUILD_CONVERTER=OFF \
  -DMNN_OPENCL=OFF \
  -DMNN_METAL=ON

make -j8

# 生成 framework
mkdir -p MNN.framework
cp libMNN.dylib MNN.framework/MNN
cp -r ../include MNN.framework/Headers
```

### 2.2 放置 framework

```
AirRead/ios/Runner/
├── MNN.framework/       # 编译后的 framework
│   ├── MNN
│   └── Headers/
├── MnnLlmBridge.h       # 已创建
├── MnnLlmBridge.mm      # 已创建
└── AppDelegate.swift    # 已更新
```

---

## 3. Xcode 项目配置

### 3.1 添加 Framework

1. 打开 `ios/Runner.xcworkspace`
2. 将 `MNN.framework` 拖入 Runner 目录
3. 在 **Build Phases** → **Link Binary With Libraries** 中添加 `MNN.framework`
4. 在 **Build Phases** → **Embed Frameworks** 中添加 `MNN.framework`

### 3.2 配置 Framework Search Paths

在 **Build Settings** 中设置：
```
FRAMEWORK_SEARCH_PATHS = $(inherited) $(PROJECT_DIR)/Runner
```

### 3.3 启用 C++ 支持

在 `Runner-Bridging-Header.h` 中添加：
```objc
#import "MnnLlmBridge.h"
```

---

## 4. 构建和测试

### 4.1 构建 iOS 项目

```bash
cd /Users/wangjingjing/aiProjects/AirRead
flutter clean
flutter pub get
cd ios
pod install
cd ..
flutter build ios --release
```

### 4.2 运行到真机

```bash
# 连接 iPhone
flutter devices

# 运行
flutter run -d <device-id> --release
```

---

## 5. 模型放置

应用启动时，需要将模型从 assets 复制到文档目录：

```dart
// 在 AppDelegate.swift 中自动处理
// 模型路径: ~/Documents/models/minicpm-1b/
```

---

## 6. 注意事项

1. **内存限制**：MiniCPM-1B INT4 需要约 1-1.5GB 内存
2. **首次加载**：模型首次加载可能需要 5-10 秒
3. **模拟器**：MNN 不支持模拟器，必须在真机测试
4. **iOS 版本**：需要 iOS 12.0+

---

## 7. 故障排除

### 问题：模型加载失败
- 检查 config.json 是否存在
- 检查 model.mnn 和 tokenizer.model 是否完整
- 查看 Xcode 控制台日志

### 问题：内存不足
- 使用 INT4 量化版本
- 减小 max_seq_len 到 1024
- 关闭其他应用

### 问题：推理速度慢
- 确保使用 Release 模式构建
- 检查是否启用了 Metal 后端
- 调整 threads 参数

---

## 8. 替代方案

如果 MNN 集成困难，可以考虑：
1. 使用 llama.cpp（已集成 fllama）
2. 使用 ONNX Runtime
3. 继续使用 Ollama 远程方案
