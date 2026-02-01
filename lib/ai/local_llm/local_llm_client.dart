// 本地 LLM 类型定义（llama.cpp 迁移后保留的兼容层）
// 注意：翻译模型已移除，只保留 QA 模型

/// 本地模型类型
enum LocalLlmModelType {
  qa,
  @deprecated
  translation, // 已弃用，翻译功能已移除
}

/// 已弃用：LocalLlmClient 已迁移到 LlamaCppClient
/// 请使用 llama_cpp_client.dart 中的 LlamaCppClient
@deprecated
class LocalLlmClient {
  final LocalLlmModelType modelType;

  LocalLlmClient({this.modelType = LocalLlmModelType.qa});

  Future<bool> isAvailable() async => false;

  Future<int?> getMaxContextTokens() async => 4096;

  Future<String> chatOnce({required String userText}) async {
    throw UnimplementedError('已迁移到 LlamaCppClient');
  }

  Stream<String> chatStream({
    required String userText,
    int? maxNewTokens,
    int? maxInputTokens,
    double? temperature,
    double? topP,
    int? topK,
    double? minP,
    double? presencePenalty,
    bool? enableThinking,
  }) async* {
    throw UnimplementedError('已迁移到 LlamaCppClient');
  }
}
