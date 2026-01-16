# 重做 AI 设置面板与本地下载交互

## 1. UI 调整（lib/presentation/widgets/ai\_hud.dart）

### 本地模型（AiModelSource.local）

* **标签修改**：将“本地（离线）”改为“本地”。

* **下载交互重构**：

  * **未下载状态**：

    * 移除原来的宽按钮。

    * 下方提示文字：“模型未下载，下载后可无网环境使用AI功能”。

    * 右侧添加“下载”文字按钮（`TextButton` 或 `InkWell`），点击触发下载，右侧给出模型大小约500M

  * **下载中状态**：

    * 下方提示文字：“模型下载中，下载后可无网环境使用AI功能”

    * 右侧“下载”文字变为圆圈进度，类似于苹果app store中下载的样式，点击可暂停，右侧有一个取消文字按钮，点击可取消下载，取消下载后，变为未下载状态。

  * **已下载状态**：

    * 下方提示文字**改为使用本地模型，可无网环境使用AI功能**

    * 右侧下载/百分比文字**移除**。

    * 整体显得干净，仅保留选中状态。

### 在线模型（AiModelSource.online）

* **交互简化**：

  * 移除切换时的 `showDialog` 确认弹窗。

  * 移除面板下方的费用提示文字。

## 2. 功能逻辑确认（lib/presentation/providers/ai\_model\_provider.dart）

* `startLocalModelDownload` 方法已存在且逻辑完整（支持断点续传、HTTP Range 头、文件流写入）。

* `stopLocalModelDownload` 方法已存在。

* **无需修改逻辑代码**，重点是 UI 层面的正确调用与状态展示。

## 3. 实现计划

1. **修改** **`_modelCard`** **组件**：

   * 重写 `chip` 组件的选中样式与标签。

   * 在 `_modelCard` 底部根据 `AiModelSource` 和 `aiModel` 状态动态构建 UI：

     * `local` 且 `!exists`：显示提示文本 + “下载”按钮。

     * `local` 且 `downloading`：显示提示文本 + “xx%” 进度文本。

     * `local` 且 `exists`：不显示额外内容。

     * `online`：不显示额外内容。

   * 移除 `select` 方法中的 `showDialog` 逻辑。

2. **验证**：

   * 运行 `flutter test`。

   * 运行 `flutter build web` 确保无编译错误。

