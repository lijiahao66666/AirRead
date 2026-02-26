import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../tencentcloud/tencent_api_client.dart';
import 'remote_config_service.dart';

/// 每日签到服务
///
/// 签到由服务端校验（防重装重复领取），本地缓存签到日期以避免重复请求。
class CheckinService {
  CheckinService._();

  static const String _kLastCheckinDate = 'checkin_last_date';
  static const String _kCheckinStreak = 'checkin_streak';

  static const String _proxyUrl =
      String.fromEnvironment('AIRREAD_API_PROXY_URL', defaultValue: '');
  static const String _apiKey =
      String.fromEnvironment('AIRREAD_API_KEY', defaultValue: '');

  /// 今天是否已签到（本地缓存）
  static Future<bool> hasCheckedInToday() async {
    final prefs = await SharedPreferences.getInstance();
    final last = prefs.getString(_kLastCheckinDate) ?? '';
    final today = _todayStr();
    return last == today;
  }

  /// 连续签到天数
  static Future<int> getStreak() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_kCheckinStreak) ?? 0;
  }

  /// 签到是否启用（由远程配置决定）
  static bool get isEnabled => RemoteConfigService.checkinEnabled;

  /// 本次签到可获得的积分（由远程配置决定）
  static int get rewardPoints => RemoteConfigService.checkinPoints;

  /// 执行签到（服务端校验），返回 { points, balance } 或 null
  static Future<CheckinResult> checkin() async {
    if (!isEnabled) return CheckinResult(points: 0);

    // 本地快速判断避免多余请求
    final prefs = await SharedPreferences.getInstance();
    final today = _todayStr();
    final last = prefs.getString(_kLastCheckinDate) ?? '';
    if (last == today) {
      debugPrint('[Checkin] already checked in today (local cache)');
      return CheckinResult(points: 0);
    }

    // 调用服务端
    final baseUrl = _proxyUrl.trim();
    if (baseUrl.isEmpty) {
      debugPrint('[Checkin] no proxy URL, skip server checkin');
      return CheckinResult(points: 0);
    }

    final deviceId = TencentApiClient.deviceId;
    if (deviceId.isEmpty) {
      debugPrint('[Checkin] no deviceId, skip server checkin');
      return CheckinResult(points: 0);
    }

    try {
      final uri = Uri.parse('$baseUrl/checkin');
      final headers = <String, String>{
        'Content-Type': 'application/json',
      };
      final key = _apiKey.trim();
      if (key.isNotEmpty) headers['X-Api-Key'] = key;
      headers['X-Device-Id'] = deviceId;

      final resp = await http
          .post(uri, headers: headers)
          .timeout(const Duration(seconds: 10));

      if (resp.statusCode == 200) {
        final json = jsonDecode(resp.body);
        final points = (json['points'] as num?)?.toInt() ?? 0;
        final streak = (json['streak'] as num?)?.toInt() ?? 0;
        final balance = (json['balance'] as num?)?.toInt();

        // 更新本地缓存
        await prefs.setString(_kLastCheckinDate, today);
        await prefs.setInt(_kCheckinStreak, streak);

        debugPrint('[Checkin] server: +$points points, streak=$streak, balance=$balance');
        return CheckinResult(points: points, balance: balance);
      } else {
        debugPrint('[Checkin] server error: ${resp.statusCode} ${resp.body}');
        return CheckinResult(points: 0);
      }
    } catch (e) {
      debugPrint('[Checkin] network error: $e');
      return CheckinResult(points: 0);
    }
  }

  /// 从服务端同步签到状态到本地缓存（启动时调用，防重装后本地缓存丢失）
  static Future<void> syncStatusFromServer() async {
    final baseUrl = _proxyUrl.trim();
    if (baseUrl.isEmpty) return;
    final deviceId = TencentApiClient.deviceId;
    if (deviceId.isEmpty) return;

    try {
      final headers = <String, String>{
        'Content-Type': 'application/json',
        'X-Device-Id': deviceId,
      };
      final key = _apiKey.trim();
      if (key.isNotEmpty) headers['X-Api-Key'] = key;

      final resp = await http
          .post(Uri.parse('$baseUrl/checkin/status'), headers: headers)
          .timeout(const Duration(seconds: 10));

      if (resp.statusCode == 200) {
        final json = jsonDecode(resp.body);
        final done = json['checkedInToday'] == true;
        final streak = (json['streak'] as num?)?.toInt() ?? 0;
        final prefs = await SharedPreferences.getInstance();
        if (done) {
          await prefs.setString(_kLastCheckinDate, _todayStr());
        }
        await prefs.setInt(_kCheckinStreak, streak);
        debugPrint('[Checkin] synced from server: done=$done streak=$streak');
      }
    } catch (e) {
      debugPrint('[Checkin] syncStatusFromServer error: $e');
    }
  }

  static String _todayStr() => _dateStr(DateTime.now());

  static String _dateStr(DateTime dt) => dt.toIso8601String().substring(0, 10);
}

class CheckinResult {
  final int points;
  final int? balance;
  CheckinResult({required this.points, this.balance});
}
