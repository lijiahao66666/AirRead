import 'mnn_model_downloader.dart';
import 'mnn_model_spec.dart';

/// 模型管理器
/// 负责检查、下载和管理 MNN 模型
class ModelManager {
  static const String qwen3_0_6b = 'qwen3-0.6b-mnn';
  // static const String sd_v1_5 = 'stable-diffusion-v1-5-mnn'; // Removed

  static const MnnModelSpec qwen3Spec = MnnModelSpec(
    id: qwen3_0_6b,
    displayName: 'Qwen3-0.6B',
    sizeLabel: '450M',
    estimatedTotalSizeBytes: 455 * 1024 * 1024,
    baseUrl: 'https://modelscope.cn/models/MNN/Qwen3-0.6B-MNN/resolve/master/',
    filesToDownload: [
      'config.json',
      'llm_config.json',
      'llm.mnn',
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
      'llm.mnn.weight': 100 * 1024 * 1024,
      'llm.mnn': 200 * 1024,
      'tokenizer.txt': 4 * 1024,
      'config.json': 200,
      'llm_config.json': 200,
    },
  );

/*
  static const MnnModelSpec sdV15Spec = MnnModelSpec(
    id: 'stable-diffusion-v1-5-mnn',
    displayName: 'Stable Diffusion v1.5',
    sizeLabel: '1.15GB',
    estimatedTotalSizeBytes: 1155 * 1024 * 1024,
    baseUrl:
        'https://modelscope.cn/models/MNN/stable-diffusion-v1-5-mnn/resolve/master/general/',
    filesToDownload: [
      'alphas.txt',
      'merges.txt',
      'vocab.json',
      'text_encoder.mnn',
      'text_encoder.mnn.weight',
      'unet.mnn',
      'unet.mnn.weight',
      'vae_decoder.mnn',
      'vae_decoder.mnn.weight',
    ],
    criticalFiles: [
      'alphas.txt',
      'merges.txt',
      'vocab.json',
      'text_encoder.mnn',
      'text_encoder.mnn.weight',
      'unet.mnn',
      'unet.mnn.weight',
      'vae_decoder.mnn',
      'vae_decoder.mnn.weight',
    ],
    minExpectedBytesByFile: {
      'alphas.txt': 2 * 1024,
      'merges.txt': 100 * 1024,
      'vocab.json': 500 * 1024,
      'text_encoder.mnn': 50 * 1024,
      'text_encoder.mnn.weight': 50 * 1024 * 1024,
      'unet.mnn': 200 * 1024,
      'unet.mnn.weight': 200 * 1024 * 1024,
      'vae_decoder.mnn': 50 * 1024,
      'vae_decoder.mnn.weight': 10 * 1024 * 1024,
    },
  );
*/

  static const List<MnnModelSpec> localModels = [qwen3Spec]; // Removed sdV15Spec

  static MnnModelSpec specFor(String modelId) {
    return localModels.firstWhere((e) => e.id == modelId, orElse: () => qwen3Spec);
  }

  static String displayNameFor(String modelId) => specFor(modelId).displayName;
  static String sizeLabelFor(String modelId) => specFor(modelId).sizeLabel;

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
