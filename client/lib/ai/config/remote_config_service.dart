import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

/// 远程配置服务
///
/// App 启动时从服务器拉取 JSON 配置，控制签到积分、广告开关、
/// 应用内更新等参数。拉取失败时使用本地缓存 / 默认值。
class RemoteConfigService {
  RemoteConfigService._();

  // ── 服务器地址（通过 --dart-define=AIRREAD_CONFIG_URL=... 编译时注入）──
  static const String _configUrl =
      String.fromEnvironment('AIRREAD_CONFIG_URL', defaultValue: '');

  static const String _kCachedConfig = 'remote_config_cache';
  static const Duration _timeout = Duration(seconds: 8);

  static Map<String, dynamic> _config = {};
  static bool _loaded = false;

  // ── 默认值 ──────────────────────────────────────────────
  static const Map<String, dynamic> _defaults = {
    // 签到
    'checkin_enabled': true,
    'checkin_points': 5000,
    // 首次赠送
    'initial_grant_points': 500000,
    // 广告
    'ad_enabled': false,
    'ad_reward_points': 2000,
    'ad_daily_limit': 10,
    // 购买
    'purchase_enabled': false,
    // 应用内更新（Android）
    'latest_version': '1.0.0',
    'min_version': '1.0.0',
    'update_url': '',
    'update_message': '',
    'force_update': false,
    // 公告
    'announcement': '',
  };

  /// 拉取远程配置（应用启动时调用一次）
  static Future<void> fetch() async {
    if (_loaded) return;
    final prefs = await SharedPreferences.getInstance();

    // 先加载本地缓存
    final cached = prefs.getString(_kCachedConfig);
    if (cached != null && cached.isNotEmpty) {
      try {
        _config = Map<String, dynamic>.from(jsonDecode(cached) as Map);
      } catch (_) {}
    }

    // 尝试从服务器拉取
    final url = _configUrl.trim();
    if (url.isNotEmpty) {
      try {
        final resp = await http
            .get(Uri.parse(url), headers: {'Accept': 'application/json'})
            .timeout(_timeout);
        if (resp.statusCode == 200) {
          final data = jsonDecode(utf8.decode(resp.bodyBytes));
          if (data is Map) {
            _config = Map<String, dynamic>.from(data);
            await prefs.setString(_kCachedConfig, jsonEncode(_config));
            debugPrint('[RemoteConfig] fetched ${_config.length} keys');
          }
        }
      } catch (e) {
        debugPrint('[RemoteConfig] fetch failed: $e');
      }
    }
    _loaded = true;
  }

  // ── 读取器 ──────────────────────────────────────────────

  static T _get<T>(String key) {
    if (_config.containsKey(key)) {
      final v = _config[key];
      if (v is T) return v;
    }
    return _defaults[key] as T;
  }

  static bool getBool(String key) => _get<bool>(key);
  static int getInt(String key) => _get<int>(key);
  static String getString(String key) => _get<String>(key);

  // ── 便捷属性 ────────────────────────────────────────────

  static bool get checkinEnabled => getBool('checkin_enabled');
  static int get checkinPoints => getInt('checkin_points');
  static int get initialGrantPoints => getInt('initial_grant_points');

  static bool get adEnabled => getBool('ad_enabled');
  static int get adRewardPoints => getInt('ad_reward_points');
  static int get adDailyLimit => getInt('ad_daily_limit');

  static bool get purchaseEnabled => getBool('purchase_enabled');

  static String get latestVersion => getString('latest_version');
  static String get minVersion => getString('min_version');
  static String get updateUrl => getString('update_url');
  static String get updateMessage => getString('update_message');
  static bool get forceUpdate => getBool('force_update');

  static String get announcement => getString('announcement');

  /// 比较版本号，返回 true 如果 a < b
  static bool isVersionLessThan(String a, String b) {
    final pa = a.split('.').map((s) => int.tryParse(s) ?? 0).toList();
    final pb = b.split('.').map((s) => int.tryParse(s) ?? 0).toList();
    for (int i = 0; i < 3; i++) {
      final va = i < pa.length ? pa[i] : 0;
      final vb = i < pb.length ? pb[i] : 0;
      if (va < vb) return true;
      if (va > vb) return false;
    }
    return false;
  }

  /// 当前 App 是否需要更新
  static bool get hasUpdate {
    if (!isPlatformSupported) return false;
    final current = _currentVersion;
    return isVersionLessThan(current, latestVersion);
  }

  /// 当前 App 是否必须强制更新（低于最低版本）
  static bool get mustForceUpdate {
    if (!isPlatformSupported) return false;
    final current = _currentVersion;
    return forceUpdate || isVersionLessThan(current, minVersion);
  }

  static bool get isPlatformSupported =>
      !kIsWeb && (Platform.isAndroid || Platform.isIOS);

  // pubspec.yaml 中的 version 会编译进 packageInfo，这里用编译常量
  static const String _currentVersion =
      String.fromEnvironment('APP_VERSION', defaultValue: '1.0.0');
}
