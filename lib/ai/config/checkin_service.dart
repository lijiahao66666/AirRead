import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'remote_config_service.dart';

/// 每日签到服务
///
/// 基于本地日期判断是否已签到，签到积分数量由 [RemoteConfigService] 控制。
/// 无需用户系统，使用设备本地存储。
class CheckinService {
  CheckinService._();

  static const String _kLastCheckinDate = 'checkin_last_date';
  static const String _kCheckinStreak = 'checkin_streak';

  /// 今天是否已签到
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

  /// 本次签到可获得的积分（由远程配置决定）
  static int get rewardPoints => RemoteConfigService.checkinPoints;

  /// 签到是否启用（由远程配置决定）
  static bool get isEnabled => RemoteConfigService.checkinEnabled;

  /// 执行签到，返回获得的积分数（0 表示今天已签到或未启用）
  static Future<int> checkin() async {
    if (!isEnabled) return 0;

    final prefs = await SharedPreferences.getInstance();
    final today = _todayStr();
    final last = prefs.getString(_kLastCheckinDate) ?? '';

    if (last == today) {
      debugPrint('[Checkin] already checked in today');
      return 0;
    }

    // 计算连续签到
    final yesterday = _dateStr(DateTime.now().subtract(const Duration(days: 1)));
    int streak = prefs.getInt(_kCheckinStreak) ?? 0;
    if (last == yesterday) {
      streak += 1;
    } else {
      streak = 1;
    }

    await prefs.setString(_kLastCheckinDate, today);
    await prefs.setInt(_kCheckinStreak, streak);

    final points = rewardPoints;
    debugPrint('[Checkin] +$points points, streak=$streak');
    return points;
  }

  static String _todayStr() => _dateStr(DateTime.now());

  static String _dateStr(DateTime dt) => dt.toIso8601String().substring(0, 10);
}
