# 解决 MissingPluginException 的步骤

## 问题
```
MissingPluginException(No implementation found for method getApplicationDocumentsDirectory on channel plugins.flutter.io/path_provider)
```

## 解决方案

### 方法 1: 清理并重新构建（推荐）

```powershell
# 1. 清理项目
flutter clean

# 2. 删除 .dart_tool 文件夹
Remove-Item -Recurse -Force .dart_tool

# 3. 删除 pubspec.lock
Remove-Item -Force pubspec.lock

# 4. 重新获取依赖
flutter pub get

# 5. 检查 Flutter 环境
flutter doctor

# 6. 运行应用
flutter run -d windows
```

### 方法 2: 检查 path_provider 版本

确保 `pubspec.yaml` 中的 path_provider 版本正确：
```yaml
path_provider: ^2.1.4
```

### 方法 3: 重新生成插件代码

```powershell
# 进入 Windows 项目目录
cd windows

# 清理构建文件
Remove-Item -Recurse -Force build
Remove-Item -Recurse -Force .flutter-plugins

# 返回项目根目录
cd ..

# 重新获取依赖
flutter pub get

# 运行应用
flutter run -d windows
```

### 方法 4: 检查 Visual Studio 工具链

如果以上方法都不行，检查 Visual Studio 是否正确安装：

```powershell
flutter doctor -v
```

确保：
- Visual Studio 2022 已安装
- 包含 "使用 C++ 的桌面开发" 工作负载
- Windows SDK 已安装

### 方法 5: 使用平台特定的目录（代码层）

如果需要在代码中绕过 path_provider，可以使用：
- Windows: `Directory.current.path` 或 `PathProvider.getDownloadsDirectory()`
- 临时方案：使用 `Directory.systemTemp.createTemp()` 创建临时目录

## 已添加的代码保护

所有使用 `getApplicationDocumentsDirectory` 的地方都已经添加了：
1. **kIsWeb 检查** - 防止在 Web 平台调用
2. **try-catch 异常处理** - 捕获并转换异常信息
3. **详细的错误消息** - 帮助诊断问题

## 测试建议

修复后测试：
1. 导入书籍功能
2. 下载本地模型功能（如果需要）
3. AI 问答功能（确保内容正确清理了 XML）

## 预期行为

- ✅ Web 平台：使用 `processWebFiles()` 处理文件上传
- ✅ Windows/MacOS/Linux：使用原生文件系统
- ✅ 所有平台：适当的错误提示
