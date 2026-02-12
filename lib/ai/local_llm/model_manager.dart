import 'mnn_model_downloader.dart';
import 'mnn_model_spec.dart';

/// 模型管理器
/// 负责检查、下载和管理 MNN 模型
class ModelManager {
  static const String hunyuan_1_8b = 'hunyuan-1.8b-mnn';
  static const String hunyuan_0_5b = 'hunyuan-0.5b-mnn';

  static const MnnModelSpec hunyuan_1_8bSpec = MnnModelSpec(
    id: hunyuan_1_8b,
    displayName: 'Hunyuan-1.8B',
    sizeLabel: '1.25G',
    estimatedTotalSizeBytes: 1250 * 1024 * 1024,
    baseUrl:
        'https://modelscope.cn/models/MNN/Hunyuan-1.8B-Instruct-MNN/resolve/master/',
    filesToDownload: [
      'config.json',
      'configuration.json',
      'llm.mnn',
      'llm.mnn.json',
      'llm.mnn.weight',
      'llm_config.json',
      'tokenizer.txt',
    ],
    criticalFiles: [
      'llm.mnn',
      'llm.mnn.weight',
      'tokenizer.txt',
      'config.json',
    ],
    minExpectedBytesByFile: {
      'llm.mnn.weight': 600 * 1024 * 1024,
      'llm.mnn': 200 * 1024,
      'llm.mnn.json': 50 * 1024,
      'tokenizer.txt': 256 * 1024,
      'config.json': 200,
      'configuration.json': 40,
      'llm_config.json': 200,
    },
  );

  static const MnnModelSpec hunyuan_0_5bSpec = MnnModelSpec(
    id: hunyuan_0_5b,
    displayName: 'Hunyuan-0.5B',
    sizeLabel: '402M',
    estimatedTotalSizeBytes: 402 * 1024 * 1024,
    baseUrl:
        'https://modelscope.cn/models/MNN/Hunyuan-0.5B-Instruct-MNN/resolve/master/',
    filesToDownload: [
      'config.json',
      'configuration.json',
      'llm_config.json',
      'llm.mnn',
      'llm.mnn.json',
      'llm.mnn.weight',
      'tokenizer.txt',
    ],
    criticalFiles: [
      'llm.mnn',
      'llm.mnn.weight',
      'tokenizer.txt',
      'config.json',
    ],
    minExpectedBytesByFile: {
      'llm.mnn.weight': 200 * 1024 * 1024,
      'llm.mnn': 200 * 1024,
      'llm.mnn.json': 50 * 1024,
      'tokenizer.txt': 256 * 1024,
      'config.json': 200,
      'llm_config.json': 200,
      'configuration.json': 40,
    },
  );

  static const List<MnnModelSpec> localModels = [
    hunyuan_1_8bSpec,
    hunyuan_0_5bSpec,
  ];

  static MnnModelSpec specFor(String modelId) {
    return localModels.firstWhere(
      (e) => e.id == modelId,
      orElse: () => hunyuan_1_8bSpec,
    );
  }

  static String displayNameFor(String modelId) => specFor(modelId).displayName;
  static String sizeLabelFor(String modelId) => specFor(modelId).sizeLabel;
  static String memoryHintFor(String modelId) {
    return switch (modelId) {
      hunyuan_1_8b => '建议手机内存≥6G',
      hunyuan_0_5b => '建议手机内存≥4G',
      _ => '',
    };
  }

  /// 检查模型是否已安装到文档目录
  static Future<bool> isModelInstalled(String modelId) async {
    return await MnnModelDownloader(spec: specFor(modelId)).isModelDownloaded();
  }

  /// 获取已下载的模型大小（字节）
  static Future<int> getDownloadedSize(String modelId) async {
    return await MnnModelDownloader(spec: specFor(modelId)).getDownloadedSize();
  }

  /// 获取模型总大小（字节）- 预估
  static int totalSizeFor(String modelId) => specFor(modelId).estimatedTotalSizeBytes;

  /// 获取格式化的模型大小文本
  static String formattedTotalSizeFor(String modelId) => specFor(modelId).sizeLabel;

  /// 安装模型（从网络下载）
  /// 返回下载器实例，用于监听进度
  static MnnModelDownloader installModel(String modelId) {
    final downloader = MnnModelDownloader(spec: specFor(modelId));
    downloader.download();
    return downloader;
  }

  /// 获取模型路径
  static Future<String?> getModelPath(String modelId) async {
    return await MnnModelDownloader(spec: specFor(modelId)).getModelPath();
  }

  /// 删除模型
  static Future<bool> deleteModel(String modelId) async {
    return await MnnModelDownloader(spec: specFor(modelId)).deleteModel();
  }

  /// 获取模型目录路径
  static Future<String> getModelDir(String modelId) async {
    return await MnnModelDownloader(spec: specFor(modelId)).getModelDir();
  }
}
