# iOS 内存优化总结

## 问题
830MB 模型在 iOS 设备上加载时因内存不足导致闪退。

## 优化方案

### 1. iOS 原生层优化 (MnnLlmBridge)

#### 新增内存管理功能：
- `getAvailableMemory()` - 获取设备可用内存
- `getTotalMemory()` - 获取设备总内存
- `hasEnoughMemoryForModel()` - 检查是否有足够内存加载模型

#### 加载优化：
- 加载前检查内存是否充足
- 加载新模型前销毁旧实例并释放内存
- 添加详细的内存日志输出

### 2. Dart 层优化

#### LocalLlmClient 新增：
- `getAvailableMemory()` - 获取可用内存
- `getTotalMemory()` - 获取总内存
- `hasEnoughMemory()` - 检查内存是否充足

#### 加载前检查：
- 检查设备是否支持本地模型（至少 4GB 内存）
- 检查当前可用内存是否足够
- 提供清晰的错误提示

### 3. 解压过程优化

#### ai_model_provider.dart：
- 使用 `verify: false` 减少内存占用
- 分批处理文件（每 10 个文件一批）
- 每批处理后短暂暂停，让系统回收内存
- 解压完成后清理 archive 对象

### 4. 设备内存检测工具

#### memory_utils.dart：
- 识别 iPhone 设备型号
- 估算设备内存容量
- 提供内存建议
- 格式化内存显示

## 使用建议

### 对于用户：
1. **iPhone 15 Pro/Max (8GB)** - 可以流畅运行
2. **iPhone 12-14 系列 (4-6GB)** - 可以运行，但建议关闭其他应用
3. **iPhone 11 及更早 (3-4GB)** - 可能无法运行，建议使用云端模型

### 对于开发者：
1. 在加载模型前调用 `hasEnoughMemory()` 检查
2. 捕获 `LocalLlmMemoryInsufficient` 错误并提示用户
3. 建议用户关闭其他应用释放内存

## 错误码

- `1011` - 设备内存不足（iOS 原生层）
- `LocalLlmMemoryInsufficient` - 设备内存不足（Dart 层）

## 文件修改清单

1. `ios/Runner/MnnLlmBridge.h` - 添加内存管理接口
2. `ios/Runner/MnnLlmBridge.mm` - 实现内存管理和优化加载
3. `ios/Runner/AppDelegate.swift` - 添加 method channel 处理
4. `lib/ai/local_llm/local_llm_client.dart` - 添加内存检查和错误处理
5. `lib/presentation/providers/ai_model_provider.dart` - 优化解压过程
6. `lib/core/utils/memory_utils.dart` - 新增设备内存检测工具
7. `pubspec.yaml` - 添加 device_info_plus 依赖

## 测试建议

1. 在不同内存容量的设备上测试
2. 测试内存不足时的错误提示
3. 测试关闭其他应用后是否能正常加载
4. 监控内存使用情况
