import 'dart:async';
import 'dart:io';
import 'package:llama_cpp_dart/llama_cpp_dart.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// llama.cpp 本地 LLM 客户端
/// 支持 GGUF 格式的模型文件
class LlamaCppClient {
  static LlamaCppClient? _instance;
  Llama? _llama;
  ModelParams? _modelParams;
  ContextParams? _contextParams;
  
  bool _isInitialized = false;
  String? _modelPath;
  
  factory LlamaCppClient() {
    _instance ??= LlamaCppClient._internal();
    return _instance!;
  }
  
  LlamaCppClient._internal();
  
  /// 检查是否可用（模型是否已加载）
  bool get isAvailable => _isInitialized && _llama != null;
  
  /// 获取模型路径
  String? get modelPath => _modelPath;
  
  /// 初始化模型
  /// 
  /// [modelPath] GGUF 模型文件路径
  /// [nCtx] 上下文长度，默认 4096
  /// [nThreads] 线程数，默认自动检测
  Future<bool> initialize({
    required String modelPath,
    int nCtx = 4096,
    int? nThreads,
  }) async {
    try {
      // 检查模型文件是否存在
      final modelFile = File(modelPath);
      if (!await modelFile.exists()) {
        print('[LlamaCppClient] 模型文件不存在: $modelPath');
        return false;
      }
      
      // 如果已经初始化，先释放资源
      await dispose();
      
      // 设置模型参数
      _modelParams = ModelParams();
      _contextParams = ContextParams();
      _contextParams!.nCtx = nCtx;
      
      // 设置线程数
      if (nThreads != null) {
        _contextParams!.nThreads = nThreads;
      } else {
        // 自动检测线程数（使用物理核心数）
        _contextParams!.nThreads = Platform.numberOfProcessors ~/ 2;
      }
      
      // 加载模型
      _llama = Llama(
        modelPath: modelPath,
        modelParams: _modelParams!,
        contextParams: _contextParams!,
      );
      
      _modelPath = modelPath;
      _isInitialized = true;
      
      print('[LlamaCppClient] 模型加载成功: $modelPath');
      return true;
    } catch (e) {
      print('[LlamaCppClient] 模型加载失败: $e');
      _isInitialized = false;
      _llama = null;
      return false;
    }
  }
  
  /// 生成文本
  /// 
  /// [prompt] 输入提示词
  /// [maxTokens] 最大生成 token 数
  /// [temperature] 温度参数，默认 0.7
  /// [onToken] 每个 token 生成时的回调
  Future<String> generate({
    required String prompt,
    int maxTokens = 512,
    double temperature = 0.7,
    Function(String token)? onToken,
  }) async {
    if (!_isInitialized || _llama == null) {
      throw Exception('模型未初始化');
    }
    
    try {
      final params = SamplingParams();
      params.temp = temperature;
      params.nPredict = maxTokens;
      
      final buffer = StringBuffer();
      
      await for (final token in _llama!.prompt(prompt, params: params)) {
        buffer.write(token);
        if (onToken != null) {
          onToken(token);
        }
      }
      
      return buffer.toString();
    } catch (e) {
      print('[LlamaCppClient] 生成失败: $e');
      rethrow;
    }
  }
  
  /// 流式生成文本
  /// 
  /// [prompt] 输入提示词
  /// [maxTokens] 最大生成 token 数
  /// [temperature] 温度参数，默认 0.7
  Stream<String> generateStream({
    required String prompt,
    int maxTokens = 512,
    double temperature = 0.7,
  }) async* {
    if (!_isInitialized || _llama == null) {
      throw Exception('模型未初始化');
    }
    
    try {
      final params = SamplingParams();
      params.temp = temperature;
      params.nPredict = maxTokens;
      
      await for (final token in _llama!.prompt(prompt, params: params)) {
        yield token;
      }
    } catch (e) {
      print('[LlamaCppClient] 流式生成失败: $e');
      rethrow;
    }
  }
  
  /// 释放资源
  Future<void> dispose() async {
    if (_llama != null) {
      _llama!.dispose();
      _llama = null;
    }
    _isInitialized = false;
    _modelPath = null;
  }
  
  /// 获取模型信息
  Map<String, dynamic>? getModelInfo() {
    if (_llama == null) return null;
    
    return {
      'modelPath': _modelPath,
      'nCtx': _contextParams?.nCtx,
      'nThreads': _contextParams?.nThreads,
    };
  }
}

/// 模型下载管理器
class LlamaModelDownloader {
  static const String _kModelFileName = 'qwen3-0.6b-q4_k_m.gguf';
  
  /// 获取模型存储目录
  static Future<Directory> getModelDir() async {
    final appDir = await getApplicationDocumentsDirectory();
    final modelDir = Directory(p.join(appDir.path, 'models', 'llama'));
    if (!await modelDir.exists()) {
      await modelDir.create(recursive: true);
    }
    return modelDir;
  }
  
  /// 获取模型文件路径
  static Future<String> getModelPath() async {
    final modelDir = await getModelDir();
    return p.join(modelDir.path, _kModelFileName);
  }
  
  /// 检查模型是否存在
  static Future<bool> isModelExists() async {
    final modelPath = await getModelPath();
    final file = File(modelPath);
    return await file.exists() && await file.length() > 0;
  }
  
  /// 获取模型大小
  static Future<int> getModelSize() async {
    final modelPath = await getModelPath();
    final file = File(modelPath);
    if (await file.exists()) {
      return await file.length();
    }
    return 0;
  }
  
  /// 删除模型
  static Future<void> deleteModel() async {
    final modelPath = await getModelPath();
    final file = File(modelPath);
    if (await file.exists()) {
      await file.delete();
    }
  }
}
