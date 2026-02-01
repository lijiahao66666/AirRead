import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'mnn_model_downloader.dart';

/// 模型管理器
/// 负责检查、下载和管理 MNN 模型
class ModelManager {
  static const String _modelDir = 'models/qwen3-0.6b-mnn';

  static final List<String> _modelFiles = [
    'config.json',
    'llm_config.json',
    'llm.mnn',
    'llm.mnn.json',
    'llm.mnn.weight',
    'tokenizer.txt',
  ];

  /// 检查模型是否已安装到文档目录
  static Future<bool> isModelInstalled() async {
    return await MnnModelDownloader.isModelDownloaded();
  }

  /// 获取已下载的模型大小（字节）
  static Future<int> getDownloadedSize() async {
    return await MnnModelDownloader.getDownloadedSize();
  }

  /// 获取模型总大小（字节）- 预估260MB
  static int get totalSize => 260 * 1024 * 1024;

  /// 获取格式化的模型大小文本
  static String get formattedTotalSize => '260MB';

  /// 安装模型（从网络下载）
  /// 返回下载器实例，用于监听进度
  static MnnModelDownloader installModel() {
    final downloader = MnnModelDownloader();
    downloader.download();
    return downloader;
  }

  /// 获取模型路径
  static Future<String?> getModelPath() async {
    return await MnnModelDownloader.getModelPath();
  }

  /// 删除模型
  static Future<bool> deleteModel() async {
    return await MnnModelDownloader.deleteModel();
  }

  /// 获取模型目录路径
  static Future<String> getModelDir() async {
    return await MnnModelDownloader.getModelDir();
  }
}
