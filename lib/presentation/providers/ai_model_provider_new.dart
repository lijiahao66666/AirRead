// 这是修复后的 _extractZipWorker 函数
// 请复制这个函数替换原文件中的对应部分

void _extractZipWorker(Map<String, dynamic> args) {
  final SendPort sendPort = args['sendPort'] as SendPort;
  try {
    final zipPath = (args['zipPath'] as String?) ?? '';
    final tmpDirPath = (args['tmpDirPath'] as String?) ?? '';
    if (zipPath.isEmpty || tmpDirPath.isEmpty) {
      throw Exception('模型安装失败：参数错误');
    }

    // 使用系统 unzip 命令解压，避免内存占用过高
    // iOS 内存限制约 2GB，830MB zip 解压需要大量内存
    sendPort.send(<String, dynamic>{
      'type': 'progress',
      'extracted': 1,
      'total': 8,
      'file': '开始解压...',
    });
    
    // 尝试使用系统 unzip 命令
    final result = Process.runSync('unzip', ['-o', zipPath, '-d', tmpDirPath]);
    
    if (result.exitCode != 0) {
      // 如果系统命令失败，回退到 Dart 解压（小文件）
      sendPort.send(<String, dynamic>{
        'type': 'progress',
        'extracted': 2,
        'total': 8,
        'file': '使用备用解压方式...',
      });
      
      final input = InputFileStream(zipPath);
      try {
        final archive = ZipDecoder().decodeBuffer(input, verify: false);
        final total = archive.files.length;
        int extracted = 0;
        
        for (int i = 0; i < archive.files.length; i++) {
          final file = archive.files[i];
          final rawName = file.name.replaceAll('\\', '/');
          final name = p.posix.normalize(rawName);
          if (name == '.' || name.startsWith('..') || p.posix.isAbsolute(name)) {
            extracted++;
            continue;
          }
          final outPath = p.joinAll(<String>[tmpDirPath, ...name.split('/'));
          
          try {
            if (file.isFile) {
              final outFile = File(outPath);
              outFile.parent.createSync(recursive: true);
              final output = OutputFileStream(outFile.path);
              try {
                file.writeContent(output);
              } finally {
                output.close();
              }
            } else {
              Directory(outPath).createSync(recursive: true);
            }
          } catch (e) {
            throw Exception('模型安装失败：解压异常 file=$name error=$e');
          }
          extracted++;
          
          if (extracted % 10 == 0 || extracted == total) {
            sendPort.send(<String, dynamic>{
              'type': 'progress',
              'extracted': extracted,
              'total': total,
              'file': name,
            });
          }
        }
        archive.clear();
      } finally {
        input.close();
      }
    }

    final configAtRoot = File(p.join(tmpDirPath, 'config.json'));
    if (configAtRoot.existsSync()) {
      sendPort.send(<String, dynamic>{
        'type': 'done',
        'rootDirPath': tmpDirPath,
      });
      return;
    }

    final tmodelsDirPath = p.join(tmpDirPath, 'tmodels');
    final configAtTmodels = File(p.join(tmodelsDirPath, 'config.json'));
    if (configAtTmodels.existsSync()) {
      sendPort.send(<String, dynamic>{
        'type': 'done',
        'rootDirPath': tmodelsDirPath,
      });
      return;
    }

    String? foundRoot;
    // 限制递归深度，减少内存占用
    try {
      final entities = Directory(tmpDirPath).listSync(recursive: false, followLinks: false);
      for (final e in entities) {
        if (e is File && p.basename(e.path).toLowerCase() == 'config.json') {
          foundRoot = p.dirname(e.path);
          break;
        }
        if (e is Directory) {
          final subEntities = e.listSync(recursive: false, followLinks: false);
          for (final sub in subEntities) {
            if (sub is File && p.basename(sub.path).toLowerCase() == 'config.json') {
              final norm = sub.path.replaceAll('\\', '/');
              if (!norm.contains('/__macosx/')) {
                foundRoot = p.dirname(sub.path);
                break;
              }
            }
          }
          if (foundRoot != null) break;
        }
      }
    } catch (_) {
      // 如果查找失败，继续后面的逻辑
    }

    if (foundRoot == null) {
      throw Exception('模型安装失败：解压后未找到 config.json');
    }

    sendPort.send(<String, dynamic>{
      'type': 'done',
      'rootDirPath': foundRoot,
    });
  } catch (e) {
    sendPort.send(<String, dynamic>{
      'type': 'error',
      'error': '$e',
    });
  }
}
