## 目标
将 MNN 模型从 App 包中移除，改为运行时从网络下载，保持原有的 UI 交互流程：
1. 选择"本地"模型后显示模型信息（名称、大小）
2. 右侧显示下载按钮
3. 点击下载，显示下载进度
4. 下载完成后自动安装
5. 安装成功后可在问答面板使用

## 实施步骤

### 1. 更新 pubspec.yaml
- 移除 assets/models/minicpm4-0.5b-mnn/ 下的模型文件引用
- 只保留 config.json 作为配置模板

### 2. 创建 MNN 模型下载器
- 新建 `lib/ai/local_llm/mnn_model_downloader.dart`
- 实现从网络下载模型文件（使用你提供的模型链接）
- 支持下载进度回调
- 断点续传（可选）

### 3. 更新 ModelManager
- 修改 `installModel()` 为从网络下载而非从 assets 复制
- 添加下载进度状态管理
- 支持暂停/恢复下载

### 4. 更新 AiModelProvider
- 添加下载状态管理（未下载、下载中、已下载）
- 添加下载进度监听
- 提供开始下载、取消下载方法

### 5. 更新 AI HUD UI
- 修改 `_localModelStatusRow` 方法
- 未下载时显示"下载"按钮
- 下载中显示进度条和百分比
- 已下载显示"已就绪"
- 点击下载按钮触发下载流程

### 6. 模型文件清单
需要下载的文件（从 ModelScope）：
- config.json
- llm_config.json
- llm.mnn
- llm.mnn.json
- llm.mnn.weight
- tokenizer.txt

### 7. 下载源配置
使用 ModelScope 的下载链接，支持国内快速下载

请确认这个方案后，我将开始实施具体的代码修改。