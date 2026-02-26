/// 广告服务占位
///
/// 当前广告 SDK（flutter_tencentad）已暂时移除。
/// 日活达标后重新启用：取消 pubspec.yaml 中的注释，并恢复此文件的实现。
///
/// 接口保持不变，方便后续切回：
///   AdService.ensureInitialized()
///   AdService.showRewardedAd() → Future<bool>
class AdService {
  AdService._();

  static Future<void> ensureInitialized() async {}

  static Future<bool> showRewardedAd() async => false;
}
