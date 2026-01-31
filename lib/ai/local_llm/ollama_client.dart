import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;

class OllamaClient {
  static const String _baseUrl = 'http://localhost:11434';
  static const String _defaultModel = 'openbmb/minicpm4-0.5b-qat-int4-gptq-format';
  
  String? _currentModel;
  bool _isInitialized = false;

  OllamaClient();

  bool get isAvailable => _isInitialized;

  String? get currentModel => _currentModel;

  Future<bool> initialize({
    String? model,
  }) async {
    try {
      if (model != null) {
        _currentModel = model;
      }

      final response = await http.post(
        Uri.parse('$_baseUrl/api/tags'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'name': model ?? _defaultModel,
        }),
      );

      if (response.statusCode == 200) {
        _isInitialized = true;
        return true;
      } else {
        throw Exception('Failed to initialize model: ${response.statusCode}');
      }
    } catch (e) {
      throw Exception('Failed to initialize model: $e');
    }
  }

  Future<String> generate({
    required String prompt,
    int maxTokens = 512,
    double temperature = 0.7,
  }) async {
    if (!_isInitialized) {
      throw Exception('Model not initialized');
    }

    try {
      final response = await http.post(
        Uri.parse('$_baseUrl/api/generate'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'model': _currentModel ?? _defaultModel,
          'prompt': prompt,
          'stream': false,
          'options': {
            'num_predict': maxTokens,
            'temperature': temperature,
          },
        }),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        return data['response'] as String;
      } else {
        throw Exception('Failed to generate: ${response.statusCode}');
      }
    } catch (e) {
      throw Exception('Failed to generate: $e');
    }
  }

  Stream<String> generateStream({
    required String prompt,
    int maxTokens = 512,
    double temperature = 0.7,
  }) async* {
    if (!_isInitialized) {
      throw Exception('Model not initialized');
    }

    try {
      final request = http.Request('POST', Uri.parse('$_baseUrl/api/generate'));
      request.headers.addAll({
        'Content-Type': 'application/json',
      });
      request.body = jsonEncode({
        'model': _currentModel ?? _defaultModel,
        'prompt': prompt,
        'stream': true,
        'options': {
          'num_predict': maxTokens,
          'temperature': temperature,
        },
      });

      final response = await http.Client().send(request);

      await for (final chunk in response.stream.transform(utf8.decoder)) {
        final line = chunk;
        if (line.isNotEmpty) {
          yield line;
        }
      }
    } catch (e) {
      throw Exception('Failed to generate stream: $e');
    }
  }

  Future<void> dispose() async {
    _isInitialized = false;
    _currentModel = null;
  }
}
