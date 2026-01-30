import 'dart:io';

void main() async {
  // 清理 iOS 模拟器中的模型数据
  final home = Platform.environment['HOME'] ?? '';
  final simulatorPath = '$home/Library/Developer/CoreSimulator/Devices';
  
  final simulatorDir = Directory(simulatorPath);
  if (await simulatorDir.exists()) {
    await for (final device in simulatorDir.list()) {
      if (device is Directory) {
        final modelPath = '${device.path}/data/Containers/Data/Application';
        final modelDir = Directory(modelPath);
        if (await modelDir.exists()) {
          await for (final app in modelDir.list()) {
            if (app is Directory) {
              final hunyuanPath = '${app.path}/Documents/models/hunyuan';
              final hunyuanDir = Directory(hunyuanPath);
              if (await hunyuanDir.exists()) {
                print('Found model at: $hunyuanPath');
                try {
                  await hunyuanDir.delete(recursive: true);
                  print('Deleted: $hunyuanPath');
                } catch (e) {
                  print('Failed to delete: $e');
                }
              }
            }
          }
        }
      }
    }
  }
  
  print('Model cleanup completed');
}
