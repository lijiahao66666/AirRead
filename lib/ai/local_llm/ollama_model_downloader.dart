import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

class OllamaModelDownloader {
  static const String _modelName = 'openbmb/minicpm4-0.5b-qat-int4-gptq-format';
  
  static Future<String> getModelDir() async {
    final appDir = await getApplicationDocumentsDirectory();
    final modelDir = Directory(p.join(appDir.path, 'models', 'ollama'));
    if (!await modelDir.exists()) {
      await modelDir.create(recursive: true);
    }
    return modelDir.path;
  }

  static Future<String> getModelPath() async {
    final modelDir = await getModelDir();
    return p.join(modelDir, _modelName);
  }

  static Future<bool> isModelExists() async {
    final modelPath = await getModelPath();
    final file = File(modelPath);
    return await file.exists();
  }

  static Future<String> getDownloadInstructions() async {
    return '''
步骤1：安装Ollama
-------------------
iOS: 从 https://ollama.com 下载iOS版本
Android: 从 https://ollama.com 下载Android版本

步骤2：下载模型
-------------------
方法1：使用Ollama命令
ollama run $_modelName

方法2：从ModelScope下载
1. 访问 https://www.modelscope.cn/collections/MiniCPM4-ec015560e8c84d
2. 下载MiniCPM4-0.5B的GGUF格式模型
3. 将模型文件复制到应用模型目录：${await getModelPath()}

步骤3：验证模型
-------------------
运行以下命令验证模型已加载：
ollama list

步骤4：启动Ollama服务
-------------------
ollama serve

默认端口：11434
API文档：http://localhost:11434/api
    ''';
  }
}
