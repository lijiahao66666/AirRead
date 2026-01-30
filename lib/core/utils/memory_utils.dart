import 'dart:io';
import 'package:device_info_plus/device_info_plus.dart';

class MemoryUtils {
  static final DeviceInfoPlugin _deviceInfo = DeviceInfoPlugin();

  /// 获取设备信息
  static Future<IosDeviceInfo?> getIosDeviceInfo() async {
    if (!Platform.isIOS) return null;
    try {
      return await _deviceInfo.iosInfo;
    } catch (_) {
      return null;
    }
  }

  /// 根据设备型号估算可用内存（MB）
  static int? estimateAvailableMemory(String? model) {
    if (model == null) return null;
    
    // iPhone 设备内存映射
    final Map<RegExp, int> memoryMap = {
      // iPhone 15 系列
      RegExp(r'iPhone16,1'): 8192, // iPhone 15 Pro
      RegExp(r'iPhone16,2'): 8192, // iPhone 15 Pro Max
      RegExp(r'iPhone15,4'): 6144, // iPhone 15
      RegExp(r'iPhone15,5'): 6144, // iPhone 15 Plus
      
      // iPhone 14 系列
      RegExp(r'iPhone15,2'): 6144, // iPhone 14 Pro
      RegExp(r'iPhone15,3'): 6144, // iPhone 14 Pro Max
      RegExp(r'iPhone14,7'): 6144, // iPhone 14
      RegExp(r'iPhone14,8'): 6144, // iPhone 14 Plus
      
      // iPhone 13 系列
      RegExp(r'iPhone14,2'): 6144, // iPhone 13 Pro
      RegExp(r'iPhone14,3'): 6144, // iPhone 13 Pro Max
      RegExp(r'iPhone14,4'): 4096, // iPhone 13 mini
      RegExp(r'iPhone14,5'): 4096, // iPhone 13
      
      // iPhone 12 系列
      RegExp(r'iPhone13,1'): 4096, // iPhone 12 mini
      RegExp(r'iPhone13,2'): 4096, // iPhone 12
      RegExp(r'iPhone13,3'): 6144, // iPhone 12 Pro
      RegExp(r'iPhone13,4'): 6144, // iPhone 12 Pro Max
      
      // iPhone 11 系列
      RegExp(r'iPhone12,1'): 4096, // iPhone 11
      RegExp(r'iPhone12,3'): 4096, // iPhone 11 Pro
      RegExp(r'iPhone12,5'): 4096, // iPhone 11 Pro Max
      
      // iPhone SE/XR/XS
      RegExp(r'iPhone12,8'): 3072, // iPhone SE (2nd gen)
      RegExp(r'iPhone11,8'): 3072, // iPhone XR
      RegExp(r'iPhone11,2'): 4096, // iPhone XS
      RegExp(r'iPhone11,4|iPhone11,6'): 4096, // iPhone XS Max
      
      // iPhone X/8/7
      RegExp(r'iPhone10,3|iPhone10,6'): 3072, // iPhone X
      RegExp(r'iPhone10,1|iPhone10,4'): 2048, // iPhone 8
      RegExp(r'iPhone10,2|iPhone10,5'): 3072, // iPhone 8 Plus
      RegExp(r'iPhone9,1|iPhone9,3'): 2048, // iPhone 7
      RegExp(r'iPhone9,2|iPhone9,4'): 3072, // iPhone 7 Plus
      
      // 更早的设备
      RegExp(r'iPhone8,1'): 2048, // iPhone 6s
      RegExp(r'iPhone8,2'): 2048, // iPhone 6s Plus
      RegExp(r'iPhone8,4'): 2048, // iPhone SE (1st gen)
    };
    
    for (final entry in memoryMap.entries) {
      if (entry.key.hasMatch(model)) {
        return entry.value;
      }
    }
    
    return null;
  }

  /// 检查设备是否支持本地模型
  static Future<bool> isDeviceSupportedForLocalModel() async {
    if (!Platform.isIOS) return false;
    
    final deviceInfo = await getIosDeviceInfo();
    final estimatedMemory = estimateAvailableMemory(deviceInfo?.model);
    
    // 至少需要 4GB 内存才能运行 830MB 模型
    return (estimatedMemory ?? 0) >= 4096;
  }

  /// 获取内存建议
  static Future<String> getMemoryRecommendation() async {
    final deviceInfo = await getIosDeviceInfo();
    final model = deviceInfo?.model ?? 'Unknown';
    final estimatedMemory = estimateAvailableMemory(model);
    
    if (estimatedMemory == null) {
      return '无法识别设备型号，请确保设备至少有 4GB 内存';
    }
    
    if (estimatedMemory >= 6144) {
      return '设备内存充足（${estimatedMemory}MB），可以流畅运行本地模型';
    } else if (estimatedMemory >= 4096) {
      return '设备内存（${estimatedMemory}MB）可以运行本地模型，但建议关闭其他应用以获得更好体验';
    } else {
      return '设备内存（${estimatedMemory}MB）可能不足以运行本地模型，建议使用云端模型';
    }
  }

  /// 格式化内存大小
  static String formatMemory(int bytes) {
    if (bytes >= 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
    } else if (bytes >= 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(0)} MB';
    } else if (bytes >= 1024) {
      return '${(bytes / 1024).toStringAsFixed(0)} KB';
    } else {
      return '$bytes B';
    }
  }
}
