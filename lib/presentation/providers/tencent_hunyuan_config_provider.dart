import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../ai/tencentcloud/embedded_public_hunyuan_credentials.dart';
import '../../ai/tencentcloud/tencent_credentials.dart';

class TencentHunyuanConfigProvider extends ChangeNotifier {
  static const _kUsePublic = 'tx_hy_use_public';
  static const _kUseCustom = 'tx_hy_use_custom';
  static const _kAppId = 'tx_hy_app_id';
  static const _kSecretId = 'tx_hy_secret_id';
  static const _kSecretKey = 'tx_hy_secret_key';

  bool _loaded = false;
  bool _usePublic = false;
  bool _useCustom = false;
  String _appId = '';
  String _secretId = '';
  String _secretKey = '';

  TencentHunyuanConfigProvider() {
    _load();
  }

  bool get loaded => _loaded;
  bool get usePublic => _usePublic;
  bool get useCustom => _useCustom;

  String get appId => _appId;
  String get secretId => _secretId;
  String get secretKey => _secretKey;

  TencentCredentials get customCredentials => TencentCredentials(
        appId: _appId,
        secretId: _secretId,
        secretKey: _secretKey,
      );

  TencentCredentials get embeddedPublicCredentials =>
      getEmbeddedPublicHunyuanCredentials();

  TencentCredentials get effectiveCredentials {
    if (_useCustom) return customCredentials;
    if (_usePublic) return embeddedPublicCredentials;
    return const TencentCredentials(appId: '', secretId: '', secretKey: '');
  }

  bool get hasUsableCredentials => effectiveCredentials.isUsable;

  Future<void> setUsePublic(bool value) async {
    _usePublic = value;
    if (value) _useCustom = false;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kUsePublic, _usePublic);
    await prefs.setBool(_kUseCustom, _useCustom);
  }

  Future<void> setUseCustom(bool value) async {
    _useCustom = value;
    if (value) _usePublic = false;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kUsePublic, _usePublic);
    await prefs.setBool(_kUseCustom, value);
  }

  Future<void> setAppId(String value) async {
    _appId = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kAppId, value);
  }

  Future<void> setSecretId(String value) async {
    _secretId = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kSecretId, value);
  }

  Future<void> setSecretKey(String value) async {
    _secretKey = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kSecretKey, value);
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    _usePublic = prefs.getBool(_kUsePublic) ?? true;
    _useCustom = prefs.getBool(_kUseCustom) ?? false;
    if (_usePublic && _useCustom) {
      _useCustom = false;
      await prefs.setBool(_kUseCustom, false);
    }
    _appId = prefs.getString(_kAppId) ?? '';
    _secretId = prefs.getString(_kSecretId) ?? '';
    _secretKey = prefs.getString(_kSecretKey) ?? '';
    _loaded = true;
    notifyListeners();
  }
}
