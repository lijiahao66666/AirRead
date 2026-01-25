import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../ai/licensing/license_codec.dart';
import '../../ai/local_llm/local_llm_client.dart';
import '../../ai/reading/reading_context_service.dart';
import '../../ai/reading/qa_service.dart';
export '../../ai/reading/qa_service.dart' show QAStreamChunk, QAType;
import '../../ai/tencentcloud/embedded_public_hunyuan_credentials.dart';
import '../../ai/tencentcloud/tencent_credentials.dart';
import '../../ai/translation/translation_types.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_tokens.dart';
import '../providers/ai_model_provider.dart';
import '../providers/translation_provider.dart';
import '../providers/qa_stream_provider.dart';
import 'glass_panel.dart';

enum AiHudRoute {
  main,
  qa,
  tencentSettings,
}

class _PurchaseSku {
  final String label;
  final String url;
  const _PurchaseSku(this.label, this.url);
}

/// AI companion bottom sheet with in-panel navigation.
///
/// Design goals:
/// - Continuous features use unified Switch toggles.
/// - Remove the top-right close icon; sheet dismissal is handled by outside tap / drag.
/// - Each row has its own settings entry (chevron) and row-tap navigation.
class AiHud extends StatefulWidget {
  final Color bgColor;
  final Color textColor;
  final AiHudRoute initialRoute;
  final String? initialQaText;
  final bool autoSendInitialQa;

  /// Feature enabled state (controls whether quick actions should appear).
  final bool translateEnabled;

  /// Active state (controls whether translation is applied to the reader content).
  final bool translateActive;

  final ValueChanged<bool>? onTranslateChanged;

  final bool readAloudEnabled;
  final ValueChanged<bool>? onReadAloudChanged;

  /// QA scope data (per-book)
  final String bookId;

  /// Reading context for AI QA (use effective/plain text, not raw HTML)
  final Map<int, String> chapterTextCache;
  final int currentChapterIndex;
  final int currentPageInChapter;
  final Map<int, List<TextRange>> chapterPageRanges;

  final void Function(String, {bool isError})? onShowTopMessage;

  const AiHud({
    super.key,
    this.bgColor = Colors.white,
    this.textColor = AppColors.deepSpace,
    this.initialRoute = AiHudRoute.main,
    this.initialQaText,
    this.autoSendInitialQa = false,
    required this.translateEnabled,
    this.translateActive = false,
    this.onTranslateChanged,
    required this.readAloudEnabled,
    this.onReadAloudChanged,
    required this.bookId,
    required this.chapterTextCache,
    required this.currentChapterIndex,
    required this.currentPageInChapter,
    required this.chapterPageRanges,
    this.onShowTopMessage,
  });

  @override
  State<AiHud> createState() => _AiHudState();
}

class _AiHudState extends State<AiHud> with TickerProviderStateMixin {
  final List<AiHudRoute> _stack = [AiHudRoute.main];
  bool _initialQaConsumed = false;

  AiHudRoute get _route => _stack.isEmpty ? AiHudRoute.main : _stack.last;

  void _push(AiHudRoute next) {
    if (next == _route) return;
    setState(() {
      _stack.add(next);
    });
  }

  void _pop() {
    if (_stack.length <= 1) return;
    setState(() {
      _stack.removeLast();
    });
  }

  @override
  void initState() {
    super.initState();
    if (widget.initialRoute != AiHudRoute.main) {
      _stack.add(widget.initialRoute);
    }
  }

  @override
  Widget build(BuildContext context) {
    final bool isDark = widget.bgColor.computeLuminance() < 0.5;

    return PopScope(
      canPop: _stack.length <= 1,
      onPopInvoked: (didPop) {
        if (didPop) return;
        if (_stack.length > 1) _pop();
      },
      child: LayoutBuilder(
        builder: (context, constraints) {
          final media = MediaQuery.of(context);
          final mediaH = media.size.height;
          final availableH =
              constraints.maxHeight.isFinite ? constraints.maxHeight : mediaH;
          if (availableH <= 0) {
            return const SizedBox.shrink();
          }

          final bool reduceMotion =
              (media.disableAnimations) || media.accessibleNavigation;
          final bool isQa = _route == AiHudRoute.qa;

          // QA keeps the existing fixed tier: ~72% of screen height with clamp.
          final qaMinHeight = availableH < 420.0 ? availableH : 420.0;
          final qaHeight = (availableH * 0.72).clamp(qaMinHeight, availableH);

          // Non-QA adapts to content, but should not grow beyond this cap.
          final nonQaMinHeight = availableH < 320.0 ? availableH : 320.0;
          final nonQaMaxHeight =
              (availableH * 0.72).clamp(nonQaMinHeight, availableH);

          final body = AnimatedSwitcher(
            duration: reduceMotion
                ? Duration.zero
                : const Duration(milliseconds: 240),
            switchInCurve: Curves.easeOutCubic,
            switchOutCurve: Curves.easeInCubic,
            transitionBuilder: (child, anim) {
              return FadeTransition(
                opacity: anim,
                child: SlideTransition(
                  position: Tween<Offset>(
                    begin: const Offset(0.04, 0),
                    end: Offset.zero,
                  ).animate(anim),
                  child: child,
                ),
              );
            },
            layoutBuilder: (currentChild, previousChildren) {
              return Stack(
                children: [
                  ...previousChildren.map(
                      (w) => Positioned.fill(child: IgnorePointer(child: w))),
                  if (currentChild != null) currentChild,
                ],
              );
            },
            child: _buildBody(isDark: isDark),
          );

          final panel = GlassPanel.sheet(
            surfaceColor: widget.bgColor,
            opacity: AppTokens.glassOpacityDense,
            child: SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 10, 20, 18),
                child: Column(
                  mainAxisSize: isQa ? MainAxisSize.max : MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _header(),
                    const SizedBox(height: 2),
                    if (isQa)
                      Expanded(child: body)
                    else
                      Flexible(
                        fit: FlexFit.loose,
                        child: body,
                      ),
                  ],
                ),
              ),
            ),
          );

          final sizedPanel = isQa
              ? SizedBox(height: qaHeight, child: panel)
              : ConstrainedBox(
                  constraints: BoxConstraints(maxHeight: nonQaMaxHeight),
                  child: panel,
                );

          return ClipRect(
            child: AnimatedSize(
              duration: reduceMotion
                  ? Duration.zero
                  : const Duration(milliseconds: 240),
              curve: Curves.easeOutCubic,
              alignment: Alignment.bottomCenter,
              child: sizedPanel,
            ),
          );
        },
      ),
    );
  }

  Widget _header() {
    final title = switch (_route) {
      AiHudRoute.main => 'AI伴读',
      AiHudRoute.qa => '问答',
      AiHudRoute.tencentSettings => 'AI设置',
    };

    return Row(
      children: [
        if (_route != AiHudRoute.main)
          IconButton(
            icon: Icon(Icons.arrow_back,
                color: widget.textColor.withOpacity(0.8)),
            onPressed: _pop,
            tooltip: '返回',
          )
        else
          const Icon(Icons.auto_awesome, color: AppColors.techBlue),
        if (_route == AiHudRoute.main) const SizedBox(width: 8),
        Text(
          title,
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.bold,
            color: widget.textColor,
          ),
        ),
        const Spacer(),
        if (_route == AiHudRoute.main)
          IconButton(
            tooltip: 'AI设置',
            icon: Icon(Icons.tune_rounded,
                color: widget.textColor.withOpacity(0.75)),
            onPressed: () => _push(AiHudRoute.tencentSettings),
          ),
      ],
    );
  }

  Widget _buildBody({required bool isDark}) {
    return switch (_route) {
      AiHudRoute.main => _MainPanel(
          key: const ValueKey('main'),
          isDark: isDark,
          bgColor: widget.bgColor,
          textColor: widget.textColor,
          translateEnabled: widget.translateEnabled,
          translateActive: widget.translateActive,
          onTranslateChanged: widget.onTranslateChanged,
          readAloudEnabled: widget.readAloudEnabled,
          onReadAloudChanged: widget.onReadAloudChanged,
          onOpenQa: () => _push(AiHudRoute.qa),
          onShowTopMessage: widget.onShowTopMessage,
        ),
      AiHudRoute.qa => _QaPanel(
          key: const ValueKey('qa'),
          isDark: isDark,
          bgColor: widget.bgColor,
          textColor: widget.textColor,
          initialQaText: _initialQaConsumed ? null : widget.initialQaText,
          autoSendInitialQa:
              _initialQaConsumed ? false : widget.autoSendInitialQa,
          onInitialQaConsumed: () {
            if (_initialQaConsumed) return;
            setState(() {
              _initialQaConsumed = true;
            });
          },
          bookId: widget.bookId,
          chapterTextCache: widget.chapterTextCache,
          currentChapterIndex: widget.currentChapterIndex,
          currentPageInChapter: widget.currentPageInChapter,
          chapterPageRanges: widget.chapterPageRanges,
          onShowTopMessage: widget.onShowTopMessage,
        ),
      AiHudRoute.tencentSettings => _TencentHunyuanSettingsPanel(
          key: const ValueKey('tencentSettings'),
          isDark: isDark,
          bgColor: widget.bgColor,
          textColor: widget.textColor,
          onShowTopMessage: widget.onShowTopMessage,
        ),
    };
  }
}

class _TencentHunyuanSettingsPanel extends StatefulWidget {
  final bool isDark;
  final Color bgColor;
  final Color textColor;
  final void Function(String, {bool isError})? onShowTopMessage;

  const _TencentHunyuanSettingsPanel({
    super.key,
    required this.isDark,
    required this.bgColor,
    required this.textColor,
    this.onShowTopMessage,
  });

  @override
  State<_TencentHunyuanSettingsPanel> createState() =>
      _TencentHunyuanSettingsPanelState();
}

class _TencentHunyuanSettingsPanelState
    extends State<_TencentHunyuanSettingsPanel> {
  static const String _kUserTencentKeysEnabled = 'user_tencent_keys_enabled';
  static const String _kUserTencentSecretId = 'user_tencent_secret_id';
  static const String _kUserTencentSecretKey = 'user_tencent_secret_key';
  static const String _kLegacyDevTencentSecretId = 'dev_tencent_secret_id';
  static const String _kLegacyDevTencentSecretKey = 'dev_tencent_secret_key';
  static const String _kRedeemedCodeHashes = 'redeemed_code_hashes_v1';
  static const String _kRedeemedPayloadV2 = 'redeemed_code_payload_v2';
  static const String _kRedeemDeviceFingerprint =
      'redeem_device_fingerprint_v1';
  static const String _redeemKeySalt = 'airread_redeem_v2';
  static final AesGcm _redeemCipher = AesGcm.with256bits();
  static const String _scfUrl =
      String.fromEnvironment('AIRREAD_TENCENT_SCF_URL', defaultValue: '');
  static const String _scfToken =
      String.fromEnvironment('AIRREAD_TENCENT_SCF_TOKEN', defaultValue: '');

  bool _showSaveSuccessPrompt = false;
  int? _voiceType;
  double? _speed;
  final TextEditingController _userSecretIdController = TextEditingController();
  final TextEditingController _userSecretKeyController =
      TextEditingController();
  bool _userKeysEnabled = false;
  bool _redeemBusy = false;
  String? _userKeysHint;
  Timer? _userKeysHintTimer;

  static const List<_PurchaseSku> _purchaseSkus = <_PurchaseSku>[
    _PurchaseSku('1天', 'https://pay.ldxp.cn/item/es3yrx'),
    _PurchaseSku('7天', 'https://pay.ldxp.cn/item/sd6rjp'),
    _PurchaseSku('15天', 'https://pay.ldxp.cn/item/kwzsqc'),
    _PurchaseSku('30天', 'https://pay.ldxp.cn/item/ndqypa'),
    _PurchaseSku('60天', 'https://pay.ldxp.cn/item/5mewh7'),
    _PurchaseSku('180天', 'https://pay.ldxp.cn/item/5mewh7'),
    _PurchaseSku('360天', 'https://pay.ldxp.cn/item/9le79z'),
  ];

  static const Map<int, String> _ttsLargeModelVoices = {
    501000: '智斌（阅读男声）',
    501001: '智兰（资讯女声）',
    501002: '智菊（阅读女声）',
    501003: '智宇（阅读男声）',
    501004: '月华（聊天女声）',
    501005: '飞镜（聊天男声）',
    501006: '千嶂（聊天男声）',
    501007: '浅草（聊天男声）',
    501008: 'WeJames（外语男声）',
    501009: 'WeWinny（外语女声）',
    601000: '爱小溪（聊天女声）',
    601001: '爱小洛（阅读女声）',
    601002: '爱小辰（聊天男声）',
    601003: '爱小荷（阅读女声）',
    601004: '爱小树（资讯男声）',
    601005: '爱小静（聊天女声）',
    601006: '爱小耀（阅读男声）',
    601007: '爱小叶（聊天女声）',
    601008: '爱小豪（聊天男声）',
    601009: '爱小芊（聊天女声）',
    601010: '爱小娇（聊天女声）',
    601011: '爱小川（聊天男声）',
    601012: '爱小璟（特色女声）',
    601013: '爱小伊（阅读女声）',
    601014: '爱小简（聊天男声）',
    601015: '爱小童（男童声）',
    502001: '智小柔（聊天女声）',
    502003: '智小敏（聊天女声）',
    502004: '智小满（营销女声）',
    502005: '智小解（解说男声）',
    502006: '智小悟（聊天男声）',
    502007: '智小虎（聊天童声）',
    602003: '爱小悠（聊天女声）',
    602004: '暖心阿灿（聊天男声）',
    602005: '专业梓欣（聊天女声）',
    603000: '懂事少年（特色男声）',
    603001: '潇湘妹妹（特色女声）',
    603002: '软萌心心（特色男童声）',
    603003: '随和老李（聊天男声）',
    603004: '温柔小柠（聊天女声）',
    603005: '知心大林（聊天男声）',
  };

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final provider = context.read<TranslationProvider>();
    _voiceType ??= provider.ttsVoiceType;
    _speed ??= provider.ttsSpeed;
  }

  @override
  void initState() {
    super.initState();
    _loadUserTencentCredentials();
  }

  @override
  void dispose() {
    _userKeysHintTimer?.cancel();
    _userSecretIdController.dispose();
    _userSecretKeyController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final Color cardBg =
        widget.isDark ? Colors.white.withOpacity(0.07) : AppColors.mistWhite;

    return SingleChildScrollView(
      padding: const EdgeInsets.only(bottom: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _translationSettings(context, cardBg: cardBg),
          const SizedBox(height: 10),
          _readAloudSettings(cardBg: cardBg),
          const SizedBox(height: 10),
          _qaContentScopeSettings(cardBg: cardBg),
          const SizedBox(height: 10),
          _userTencentCredentialsSettings(cardBg: cardBg),
        ],
      ),
    );
  }

  Future<void> _loadUserTencentCredentials() async {
    final prefs = await SharedPreferences.getInstance();
    bool enabled = prefs.getBool(_kUserTencentKeysEnabled) ?? false;
    String secretId = (prefs.getString(_kUserTencentSecretId) ?? '').trim();
    String secretKey = (prefs.getString(_kUserTencentSecretKey) ?? '').trim();

    if (secretId.isEmpty && secretKey.isEmpty) {
      final legacyId =
          (prefs.getString(_kLegacyDevTencentSecretId) ?? '').trim();
      final legacyKey =
          (prefs.getString(_kLegacyDevTencentSecretKey) ?? '').trim();
      if (legacyId.isNotEmpty && legacyKey.isNotEmpty) {
        secretId = legacyId;
        secretKey = legacyKey;
        await prefs.setString(_kUserTencentSecretId, secretId);
        await prefs.setString(_kUserTencentSecretKey, secretKey);
        enabled = true;
        await prefs.setBool(_kUserTencentKeysEnabled, true);
      }
    }

    if (!mounted) return;
    setState(() {
      _userKeysEnabled = enabled;
      _userSecretIdController.text = secretId;
      _userSecretKeyController.text = secretKey;
    });
    setUserTencentKeysEnabledOverride(enabled);

    if (enabled && secretId.isNotEmpty && secretKey.isNotEmpty) {
      setTencentCredentialsOverride(
        TencentCredentials(appId: '', secretId: secretId, secretKey: secretKey),
      );
      await context.read<TranslationProvider>().reloadTencentCredentials();
    }
  }

  String _fingerprintHash(String fingerprint) {
    return sha256.convert(utf8.encode(fingerprint)).toString();
  }

  SecretKey _deriveRedeemKey(String fingerprint) {
    final bytes =
        sha256.convert(utf8.encode('$_redeemKeySalt|$fingerprint')).bytes;
    return SecretKey(bytes);
  }

  Future<String?> _encryptRedeemPayload(
    String payload,
    String fingerprint,
  ) async {
    try {
      final nonce = _redeemCipher.newNonce();
      final secretBox = await _redeemCipher.encrypt(
        utf8.encode(payload),
        secretKey: _deriveRedeemKey(fingerprint),
        nonce: nonce,
      );
      final obj = <String, String>{
        'nonce': base64UrlEncode(nonce),
        'cipher': base64UrlEncode(secretBox.cipherText),
        'mac': base64UrlEncode(secretBox.mac.bytes),
      };
      return jsonEncode(obj);
    } catch (_) {
      return null;
    }
  }

  Future<String?> _decryptRedeemPayload(
    String payload,
    String fingerprint,
  ) async {
    try {
      final decoded = jsonDecode(payload);
      if (decoded is! Map) return null;
      final nonceRaw = decoded['nonce']?.toString() ?? '';
      final cipherRaw = decoded['cipher']?.toString() ?? '';
      final macRaw = decoded['mac']?.toString() ?? '';
      if (nonceRaw.isEmpty || cipherRaw.isEmpty || macRaw.isEmpty) return null;
      final secretBox = SecretBox(
        base64Url.decode(cipherRaw),
        nonce: base64Url.decode(nonceRaw),
        mac: Mac(base64Url.decode(macRaw)),
      );
      final clear = await _redeemCipher.decrypt(
        secretBox,
        secretKey: _deriveRedeemKey(fingerprint),
      );
      return utf8.decode(clear);
    } catch (_) {
      return null;
    }
  }

  Future<String> _getDeviceFingerprint(SharedPreferences prefs) async {
    final existing = prefs.getString(_kRedeemDeviceFingerprint);
    if (existing != null && existing.trim().isNotEmpty) return existing;
    final uuid = const Uuid().v4();
    final fp =
        '$uuid|${defaultTargetPlatform.toString()}|${kIsWeb ? 'web' : 'app'}';
    await prefs.setString(_kRedeemDeviceFingerprint, fp);
    return fp;
  }

  Uri _resolveRedeemScfUri() {
    final raw = _scfUrl.trim();
    if (raw.isEmpty) {
      throw const LicenseException('兑换服务未配置');
    }
    return Uri.parse(raw);
  }

  Future<void> _redeemOnCloud({
    required String licenseCode,
    required String deviceId,
  }) async {
    final uri = _resolveRedeemScfUri();
    final headers = <String, String>{
      'Content-Type': 'application/json; charset=utf-8',
    };
    final token = _scfToken.trim();
    if (token.isNotEmpty) {
      headers['X-Airread-Token'] = token;
    }
    final resp = await http.post(
      uri,
      headers: headers,
      body: jsonEncode(<String, dynamic>{
        'license_code': licenseCode,
        'device_id': deviceId,
      }),
    );
    if (resp.statusCode == 409) {
      throw const LicenseException('重复兑换');
    }
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      String message = '兑换失败';
      try {
        final decoded = jsonDecode(utf8.decode(resp.bodyBytes));
        if (decoded is Map) {
          message = decoded['message']?.toString() ??
              decoded['error']?.toString() ??
              message;
        }
      } catch (_) {}
      throw LicenseException(message);
    }
  }

  Future<List<Map<String, dynamic>>> _loadRedeemedEntries({
    required SharedPreferences prefs,
    required String fingerprint,
  }) async {
    final payload = prefs.getString(_kRedeemedPayloadV2);
    if (payload != null && payload.trim().isNotEmpty) {
      final decrypted = await _decryptRedeemPayload(payload, fingerprint);
      if (decrypted != null && decrypted.trim().isNotEmpty) {
        final obj = jsonDecode(decrypted);
        if (obj is List) {
          final entries = <Map<String, dynamic>>[];
          for (final item in obj) {
            if (item is Map) {
              final hash = item['hash']?.toString() ?? '';
              if (hash.trim().isEmpty) continue;
              final fp = item['fp']?.toString() ?? '';
              final t = int.tryParse(item['t']?.toString() ?? '') ?? 0;
              entries.add(<String, dynamic>{'hash': hash, 'fp': fp, 't': t});
            }
          }
          return entries;
        }
      }
    }

    final legacy = prefs.getStringList(_kRedeemedCodeHashes);
    if (legacy != null && legacy.isNotEmpty) {
      final fpHash = _fingerprintHash(fingerprint);
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      final entries = legacy
          .map((hash) => <String, dynamic>{
                'hash': hash,
                'fp': fpHash,
                't': nowMs,
              })
          .toList();
      await _saveRedeemedEntries(
        prefs: prefs,
        fingerprint: fingerprint,
        entries: entries,
      );
      await prefs.remove(_kRedeemedCodeHashes);
      return entries;
    }

    return [];
  }

  Future<void> _saveRedeemedEntries({
    required SharedPreferences prefs,
    required String fingerprint,
    required List<Map<String, dynamic>> entries,
  }) async {
    final encoded = jsonEncode(entries);
    final encrypted = await _encryptRedeemPayload(encoded, fingerprint);
    if (encrypted == null) return;
    await prefs.setString(_kRedeemedPayloadV2, encrypted);
  }

  Future<void> _setUserTencentKeysEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kUserTencentKeysEnabled, enabled);
    setUserTencentKeysEnabledOverride(enabled);

    if (!mounted) return;
    setState(() => _userKeysEnabled = enabled);

    if (enabled) {
      final secretId = _userSecretIdController.text.trim();
      final secretKey = _userSecretKeyController.text.trim();
      if (secretId.isNotEmpty && secretKey.isNotEmpty) {
        setTencentCredentialsOverride(
          TencentCredentials(
              appId: '', secretId: secretId, secretKey: secretKey),
        );
      }
    } else {
      setTencentCredentialsOverride(null);
    }

    if (!mounted) return;
    await context.read<TranslationProvider>().reloadTencentCredentials();
  }

  Future<void> _saveUserTencentCredentials() async {
    final secretId = _userSecretIdController.text.trim();
    final secretKey = _userSecretKeyController.text.trim();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kUserTencentKeysEnabled, true);
    await prefs.setString(_kUserTencentSecretId, secretId);
    await prefs.setString(_kUserTencentSecretKey, secretKey);
    setUserTencentKeysEnabledOverride(true);
    setTencentCredentialsOverride(
      TencentCredentials(appId: '', secretId: secretId, secretKey: secretKey),
    );
    if (!mounted) return;
    setState(() => _userKeysEnabled = true);
    await context.read<TranslationProvider>().reloadTencentCredentials();
    if (!mounted) return;

    setState(() {
      _showSaveSuccessPrompt = true;
    });
    Future.delayed(const Duration(seconds: 3), () {
      if (mounted) {
        setState(() {
          _showSaveSuccessPrompt = false;
        });
      }
    });
  }

  Future<void> _clearUserTencentCredentials() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kUserTencentKeysEnabled, false);
    await prefs.remove(_kUserTencentSecretId);
    await prefs.remove(_kUserTencentSecretKey);
    setUserTencentKeysEnabledOverride(false);
    setTencentCredentialsOverride(null);
    if (!mounted) return;
    setState(() {
      _userKeysEnabled = false;
      _userSecretIdController.clear();
      _userSecretKeyController.clear();
    });
    await context.read<TranslationProvider>().reloadTencentCredentials();
    if (!mounted) return;
    if (widget.onShowTopMessage != null) {
      widget.onShowTopMessage!('已清除个人密钥', isError: false);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已清除个人密钥')),
      );
    }
  }

  Widget _userTencentCredentialsSettings({required Color cardBg}) {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: cardBg,
        borderRadius: BorderRadius.circular(AppTokens.radiusMd),
        border: Border.all(
            color: widget.textColor.withOpacity(0.08), width: AppTokens.stroke),
      ),
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                '个人密钥',
                style: TextStyle(
                  color: widget.textColor,
                  fontWeight: FontWeight.w900,
                  fontSize: 14,
                ),
              ),
              const Spacer(),
              SizedBox(
                height: 44,
                child: Center(
                  child: Transform.scale(
                    scale: 0.9,
                    child: Switch(
                      value: _userKeysEnabled,
                      activeColor: AppColors.techBlue,
                      onChanged: _setUserTencentKeysEnabled,
                    ),
                  ),
                ),
              ),
            ],
          ),
          if (_userKeysEnabled) ...[
            Text(
              '可填写腾讯个人开发者的SecretId,SecretKey，会操作的看官自己操作，请放心，app内部不会盗用和泄露此信息，可自己通过控制台查看用量，需要开通混元大模型，机器翻译，语音合成完整使用AI伴读功能，无需购买时长。',
              style: TextStyle(
                color: widget.textColor.withOpacity(0.65),
                fontSize: 13,
                height: 1.35,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _userSecretIdController,
              decoration: InputDecoration(
                hintText: 'SecretId',
                isDense: true,
                filled: true,
                fillColor: cardBg,
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(
                    color: widget.textColor.withOpacity(0.18),
                    width: AppTokens.stroke,
                  ),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(
                    color: widget.textColor.withOpacity(0.18),
                    width: AppTokens.stroke,
                  ),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(
                    color: AppColors.techBlue.withOpacity(0.6),
                    width: AppTokens.stroke,
                  ),
                ),
              ),
              style: const TextStyle(fontSize: 13),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _userSecretKeyController,
              obscureText: true,
              decoration: InputDecoration(
                hintText: 'SecretKey',
                isDense: true,
                filled: true,
                fillColor: cardBg,
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(
                    color: widget.textColor.withOpacity(0.18),
                    width: AppTokens.stroke,
                  ),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(
                    color: widget.textColor.withOpacity(0.18),
                    width: AppTokens.stroke,
                  ),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(
                    color: AppColors.techBlue.withOpacity(0.6),
                    width: AppTokens.stroke,
                  ),
                ),
              ),
              style: const TextStyle(fontSize: 13),
            ),
            if (_showSaveSuccessPrompt) ...[
              const SizedBox(height: 8),
              const Row(
                children: [
                  Icon(Icons.check_circle, color: Colors.green, size: 16),
                  SizedBox(width: 4),
                  Text(
                    '已保存个人密钥',
                    style: TextStyle(
                      color: Colors.green,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerRight,
              child: Wrap(
                spacing: 16,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  InkWell(
                    onTap: _saveUserTencentCredentials,
                    child: const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 4, vertical: 6),
                      child: Text(
                        '保存',
                        style: TextStyle(
                          color: AppColors.techBlue,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                  InkWell(
                    onTap: _clearUserTencentCredentials,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 4, vertical: 6),
                      child: Text(
                        '清除',
                        style: TextStyle(
                          color: widget.textColor.withOpacity(0.7),
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            if (_userKeysHint != null && _userKeysHint!.trim().isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                _userKeysHint!,
                style: const TextStyle(
                  color: AppColors.techBlue,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ],
        ],
      ),
    );
  }

  String _formatYmd(DateTime dt) {
    final y = dt.year.toString().padLeft(4, '0');
    final m = dt.month.toString().padLeft(2, '0');
    final d = dt.day.toString().padLeft(2, '0');
    final hh = dt.hour.toString().padLeft(2, '0');
    final mm = dt.minute.toString().padLeft(2, '0');
    final ss = dt.second.toString().padLeft(2, '0');
    return '$y-$m-$d $hh:$mm:$ss';
  }

  Widget _redeemRow(AiModelProvider aiModel, {required Color cardBg}) {
    final expiresAt = aiModel.onlineEntitlementExpiresAt;
    final active = aiModel.onlineEntitlementActive;
    final expiryText =
        active && expiresAt != null ? '到期时间：${_formatYmd(expiresAt)}' : '';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            TextButton(
              onPressed: () => _showPurchaseDialog(cardBg: cardBg),
              style: TextButton.styleFrom(
                padding: EdgeInsets.zero,
                minimumSize: const Size(0, 0),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                foregroundColor: AppColors.techBlue,
              ),
              child: const Text(
                '购买',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
              ),
            ),
            const SizedBox(width: 14),
            TextButton(
              onPressed: _redeemBusy
                  ? null
                  : () => _showRedeemDialog(aiModel, cardBg: cardBg),
              style: TextButton.styleFrom(
                padding: EdgeInsets.zero,
                minimumSize: const Size(0, 0),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                foregroundColor: AppColors.techBlue,
              ),
              child: Text(
                _redeemBusy ? '处理中…' : '兑换',
                style:
                    const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
              ),
            ),
            if (expiryText.isNotEmpty) ...[
              const SizedBox(width: 14),
              Text(
                expiryText,
                style: TextStyle(
                  color: widget.textColor.withOpacity(0.65),
                  fontSize: 13,
                  height: 1.2,
                ),
              ),
            ],
          ],
        ),
      ],
    );
  }

  Future<void> _openExternalUrl(String url) async {
    final uri = Uri.parse(url);
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  Future<void> _showRedeemDialog(
    AiModelProvider aiModel, {
    required Color cardBg,
  }) async {
    final controller = TextEditingController();
    final dialogBg = widget.isDark ? const Color(0xFF262626) : Colors.white;
    final fieldBg =
        widget.isDark ? const Color(0xFF1E1E1E) : const Color(0xFFF2F2F2);
    bool dialogBusy = _redeemBusy;
    String dialogHint = '';
    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (dialogContext, setDialogState) {
            Future<bool> submit() async {
              final trimmed = controller.text.trim();
              if (trimmed.isEmpty) {
                setDialogState(() => dialogHint = '请输入卡密');
                return false;
              }
              if (dialogBusy) return false;

              final codeHash = sha256.convert(utf8.encode(trimmed)).toString();
              final prefs = await SharedPreferences.getInstance();
              final fingerprint = await _getDeviceFingerprint(prefs);

              final fpHash = _fingerprintHash(fingerprint);
              final redeemed = await _loadRedeemedEntries(
                prefs: prefs,
                fingerprint: fingerprint,
              );
              final alreadyRedeemed = redeemed.any((e) =>
                  (e['hash']?.toString() ?? '') == codeHash &&
                  (e['fp']?.toString() ?? '') == fpHash);
              if (alreadyRedeemed) {
                setDialogState(() => dialogHint = '重复兑换');
                return false;
              }

              setDialogState(() {
                dialogBusy = true;
                dialogHint = '';
              });
              if (mounted) {
                setState(() {
                  _redeemBusy = true;
                });
              }

              try {
                final payload = await LicenseCodec.verifyAndParse(trimmed);
                await _redeemOnCloud(
                  licenseCode: trimmed,
                  deviceId: fpHash,
                );
                final nowMs2 = DateTime.now().millisecondsSinceEpoch;
                final baseMs = aiModel.onlineEntitlementExpiryMs > nowMs2
                    ? aiModel.onlineEntitlementExpiryMs
                    : nowMs2;
                final merged =
                    baseMs + Duration(days: payload.days).inMilliseconds;
                await aiModel.setOnlineEntitlementExpiryMs(merged);

                final updated =
                    List<Map<String, dynamic>>.from(redeemed, growable: true);
                updated.add(<String, dynamic>{
                  'hash': codeHash,
                  'fp': fpHash,
                  't': nowMs2,
                });
                if (updated.length > 2000) {
                  updated.removeRange(0, updated.length - 2000);
                }
                await _saveRedeemedEntries(
                  prefs: prefs,
                  fingerprint: fingerprint,
                  entries: updated,
                );

                setDialogState(() => dialogHint = '');
                return true;
              } catch (e) {
                final msg = e.toString();
                setDialogState(() => dialogHint = msg);
                return false;
              } finally {
                setDialogState(() => dialogBusy = false);
                if (mounted) setState(() => _redeemBusy = false);
              }
            }

            final hint = dialogHint.trim();

            return AlertDialog(
              backgroundColor: dialogBg,
              surfaceTintColor: Colors.transparent,
              title: Text(
                '兑换卡密',
                style: TextStyle(color: widget.textColor, fontSize: 14),
              ),
              content: SizedBox(
                width: 320,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    TextField(
                      controller: controller,
                      autofocus: true,
                      enabled: !dialogBusy,
                      decoration: InputDecoration(
                        hintText: '输入卡密',
                        isDense: true,
                        filled: true,
                        fillColor: fieldBg,
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 12),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide(
                            color: widget.textColor.withOpacity(0.18),
                            width: AppTokens.stroke,
                          ),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide(
                            color: widget.textColor.withOpacity(0.18),
                            width: AppTokens.stroke,
                          ),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide(
                            color: AppColors.techBlue.withOpacity(0.6),
                            width: AppTokens.stroke,
                          ),
                        ),
                        hintStyle: TextStyle(
                            color: widget.textColor.withOpacity(0.45)),
                      ),
                      style: TextStyle(color: widget.textColor, fontSize: 13),
                      onSubmitted: (_) async {
                        final navigator = Navigator.of(dialogContext);
                        final ok = await submit();
                        if (!mounted) return;
                        if (ok) {
                          if (navigator.canPop()) navigator.pop();
                        }
                      },
                    ),
                    if (hint.isNotEmpty) ...[
                      const SizedBox(height: 10),
                      Text(
                        hint,
                        style: const TextStyle(
                          color: Colors.redAccent,
                          fontSize: 13,
                          height: 1.35,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: dialogBusy
                      ? null
                      : () => Navigator.of(dialogContext).pop(),
                  style: TextButton.styleFrom(
                    foregroundColor: widget.textColor.withOpacity(0.75),
                  ),
                  child: const Text('取消'),
                ),
                TextButton(
                  onPressed: dialogBusy
                      ? null
                      : () async {
                          final navigator = Navigator.of(dialogContext);
                          final ok = await submit();
                          if (!mounted) return;
                          if (ok) {
                            if (navigator.canPop()) navigator.pop();
                          }
                        },
                  style: TextButton.styleFrom(
                    foregroundColor: AppColors.techBlue,
                  ),
                  child: Text(dialogBusy ? '处理中…' : '确认'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Future<void> _showPurchaseDialog({required Color cardBg}) async {
    final dialogBg = widget.isDark ? const Color(0xFF262626) : Colors.white;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          backgroundColor: dialogBg,
          surfaceTintColor: Colors.transparent,
          title: Text(
            '购买时长',
            style: TextStyle(color: widget.textColor, fontSize: 14),
          ),
          content: SizedBox(
            width: 320,
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final sku in _purchaseSkus)
                  ListTile(
                    dense: true,
                    textColor: widget.textColor,
                    iconColor: widget.textColor.withOpacity(0.75),
                    title: Text(
                      sku.label,
                      style: const TextStyle(fontSize: 13),
                    ),
                    trailing: const Icon(Icons.open_in_new_rounded, size: 18),
                    onTap: () async {
                      Navigator.of(dialogContext).pop();
                      await _openExternalUrl(sku.url);
                    },
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              style: TextButton.styleFrom(
                foregroundColor: widget.textColor.withOpacity(0.75),
              ),
              child: const Text('关闭'),
            ),
          ],
        );
      },
    );
  }

  static const _bigModelSourceLangs = <String, String>{
    '': '自动',
    'zh': '简体中文',
    'zh-TR': '繁体中文',
    'yue': '粤语',
    'en': '英语',
    'fr': '法语',
    'pt': '葡萄牙语',
    'es': '西班牙语',
    'ja': '日语',
    'tr': '土耳其语',
    'ru': '俄语',
    'ar': '阿拉伯语',
    'ko': '韩语',
    'th': '泰语',
    'it': '意大利语',
    'de': '德语',
    'vi': '越南语',
    'ms': '马来语',
    'id': '印尼语',
  };

  static const _bigModelTargetLangs = <String, String>{
    'zh': '简体中文',
    'zh-TR': '繁体中文',
    'yue': '粤语',
    'en': '英语',
    'fr': '法语',
    'pt': '葡萄牙语',
    'es': '西班牙语',
    'ja': '日语',
    'tr': '土耳其语',
    'ru': '俄语',
    'ar': '阿拉伯语',
    'ko': '韩语',
    'th': '泰语',
    'it': '意大利语',
    'de': '德语',
    'vi': '越南语',
    'ms': '马来语',
    'id': '印尼语',
  };

  static const _machineSourceLangs = <String, String>{
    '': '自动',
    'zh': '简体中文',
    'zh-TW': '繁体中文',
    'en': '英语',
    'ja': '日语',
    'ko': '韩语',
    'fr': '法语',
    'es': '西班牙语',
    'it': '意大利语',
    'de': '德语',
    'tr': '土耳其语',
    'ru': '俄语',
    'pt': '葡萄牙语',
    'vi': '越南语',
    'id': '印尼语',
    'th': '泰语',
    'ms': '马来语',
    'ar': '阿拉伯语',
    'hi': '印地语',
  };

  static const _machineLangLabels = <String, String>{
    'zh': '简体中文',
    'zh-TW': '繁体中文',
    'en': '英语',
    'ja': '日语',
    'ko': '韩语',
    'fr': '法语',
    'es': '西班牙语',
    'it': '意大利语',
    'de': '德语',
    'tr': '土耳其语',
    'ru': '俄语',
    'pt': '葡萄牙语',
    'vi': '越南语',
    'id': '印尼语',
    'th': '泰语',
    'ms': '马来语',
    'ar': '阿拉伯语',
    'hi': '印地语',
  };

  static const _machineTargetsBySource = <String, List<String>>{
    'zh': [
      'zh-TW',
      'en',
      'ja',
      'ko',
      'fr',
      'es',
      'it',
      'de',
      'tr',
      'ru',
      'pt',
      'vi',
      'id',
      'th',
      'ms',
      'ar',
    ],
    'zh-TW': [
      'zh',
      'en',
      'ja',
      'ko',
      'fr',
      'es',
      'it',
      'de',
      'tr',
      'ru',
      'pt',
      'vi',
      'id',
      'th',
      'ms',
      'ar',
    ],
    'en': [
      'zh',
      'zh-TW',
      'ja',
      'ko',
      'fr',
      'es',
      'it',
      'de',
      'tr',
      'ru',
      'pt',
      'vi',
      'id',
      'th',
      'ms',
      'ar',
      'hi',
    ],
    'ja': ['zh', 'zh-TW', 'en', 'ko'],
    'ko': ['zh', 'zh-TW', 'en', 'ja'],
    'fr': ['zh', 'zh-TW', 'en', 'es', 'it', 'de', 'tr', 'ru', 'pt'],
    'es': ['zh', 'zh-TW', 'en', 'fr', 'it', 'de', 'tr', 'ru', 'pt'],
    'it': ['zh', 'zh-TW', 'en', 'fr', 'es', 'de', 'tr', 'ru', 'pt'],
    'de': ['zh', 'zh-TW', 'en', 'fr', 'es', 'it', 'tr', 'ru', 'pt'],
    'tr': ['zh', 'zh-TW', 'en', 'fr', 'es', 'it', 'de', 'ru', 'pt'],
    'ru': ['zh', 'zh-TW', 'en', 'fr', 'es', 'it', 'de', 'tr', 'pt'],
    'pt': ['zh', 'zh-TW', 'en', 'fr', 'es', 'it', 'de', 'tr', 'ru'],
    'vi': ['zh', 'zh-TW', 'en'],
    'id': ['zh', 'zh-TW', 'en'],
    'th': ['zh', 'zh-TW', 'en'],
    'ms': ['zh', 'zh-TW', 'en'],
    'ar': ['zh', 'zh-TW', 'en'],
    'hi': ['en'],
    '': [
      'zh',
      'zh-TW',
      'en',
      'ja',
      'ko',
      'fr',
      'es',
      'it',
      'de',
      'tr',
      'ru',
      'pt',
      'vi',
      'id',
      'th',
      'ms',
      'ar',
      'hi',
    ],
  };

  Map<String, String> _machineTargetItems(String sourceLang) {
    final src = sourceLang.trim().isEmpty ? '' : sourceLang.trim();
    final allow = _machineTargetsBySource[src] ?? _machineTargetsBySource['']!;
    final out = <String, String>{};
    for (final code in allow) {
      out[code] = _machineLangLabels[code] ?? code;
    }
    return out;
  }

  Widget _itemBox(Widget child) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: Colors.transparent,
          width: AppTokens.stroke,
        ),
      ),
      child: child,
    );
  }

  Widget _translationSettings(
    BuildContext context, {
    required Color cardBg,
  }) {
    final provider = context.watch<TranslationProvider>();
    final aiModel = context.watch<AiModelProvider>();
    final cfg = provider.config;

    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: cardBg,
        borderRadius: BorderRadius.circular(AppTokens.radiusMd),
        border: Border.all(
            color: widget.textColor.withOpacity(0.08), width: AppTokens.stroke),
      ),
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '翻译设置',
            style: TextStyle(
              color: widget.textColor,
              fontWeight: FontWeight.w900,
              fontSize: 14,
            ),
          ),
          const SizedBox(height: 12),
          _itemBox(
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '翻译引擎',
                  style: TextStyle(
                    color: widget.textColor,
                    fontSize: 13,
                    fontWeight: FontWeight.normal,
                  ),
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 12,
                  runSpacing: 10,
                  children: [
                    _chip(
                      label: '机器',
                      active:
                          provider.translationMode == TranslationMode.machine,
                      onTap: () =>
                          provider.setTranslationMode(TranslationMode.machine),
                      textColor: widget.textColor,
                    ),
                    _chip(
                      label: '大模型',
                      active:
                          provider.translationMode == TranslationMode.bigModel,
                      onTap: () =>
                          provider.setTranslationMode(TranslationMode.bigModel),
                      textColor: widget.textColor,
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                if (provider.translationMode == TranslationMode.machine)
                  Text(
                    '使用腾讯机器翻译',
                    style: TextStyle(
                      color: widget.textColor.withOpacity(0.65),
                      fontSize: 13,
                      height: 1.35,
                    ),
                  )
                else ...[
                  if (provider.usingPersonalTencentKeys) ...[
                    Text(
                      '使用腾讯混元翻译大模型（个人密钥）',
                      style: TextStyle(
                        color: widget.textColor.withOpacity(0.65),
                        fontSize: 13,
                        height: 1.35,
                      ),
                    ),
                  ] else ...[
                    Text(
                      '使用腾讯混元翻译大模型'
                      '${aiModel.onlineEntitlementActive ? '' : '，需要购买时长后使用'}',
                      style: TextStyle(
                        color: widget.textColor.withOpacity(0.65),
                        fontSize: 13,
                        height: 1.35,
                      ),
                    ),
                    const SizedBox(height: 10),
                    _redeemRow(aiModel, cardBg: cardBg),
                  ],
                ],
              ],
            ),
          ),
          const SizedBox(height: 10),
          _itemBox(
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: _dropdown(
                    label: '源语言（可选）',
                    value: cfg.sourceLang,
                    items: provider.translationMode == TranslationMode.machine
                        ? _machineSourceLangs
                        : _bigModelSourceLangs,
                    onChanged: (v) => provider.setSourceLang(v ?? ''),
                    textColor: widget.textColor,
                    dropdownColor: cardBg,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _dropdown(
                    label: '目标语言（必选）',
                    value: cfg.targetLang,
                    items: provider.translationMode == TranslationMode.machine
                        ? _machineTargetItems(cfg.sourceLang)
                        : _bigModelTargetLangs,
                    onChanged: (v) => provider.setTargetLang(v ?? 'en'),
                    textColor: widget.textColor,
                    dropdownColor: cardBg,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          _itemBox(
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '显示模式',
                  style: TextStyle(
                    color: widget.textColor,
                    fontSize: 13,
                    fontWeight: FontWeight.normal,
                  ),
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 12,
                  runSpacing: 10,
                  children: [
                    _chip(
                      label: '仅显示译文',
                      active: cfg.displayMode ==
                          TranslationDisplayMode.translationOnly,
                      onTap: () => provider.setDisplayMode(
                          TranslationDisplayMode.translationOnly),
                      textColor: widget.textColor,
                    ),
                    _chip(
                      label: '双语对照',
                      active:
                          cfg.displayMode == TranslationDisplayMode.bilingual,
                      onTap: () => provider
                          .setDisplayMode(TranslationDisplayMode.bilingual),
                      textColor: widget.textColor,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _getSpeedLabel(double level) {
    if (level == -2) return '0.6x';
    if (level == -1) return '0.8x';
    if (level == 0) return '1.0x';
    if (level == 1) return '1.2x';
    if (level == 2) return '1.5x';
    if (level == 6) return '2.5x';
    return '${level}x';
  }

  Widget _speedBar({
    required List<double> levels,
    required double value,
    required ValueChanged<double> onChanged,
    required Color textColor,
  }) {
    const Color activeColor = AppColors.techBlue;
    final inactiveColor = textColor.withOpacity(0.4);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        LayoutBuilder(
          builder: (context, constraints) {
            return SizedBox(
              height: 28,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  Positioned(
                    left: 0,
                    right: 0,
                    child: Container(
                      height: 2,
                      decoration: BoxDecoration(
                        color: textColor.withOpacity(0.18),
                        borderRadius: BorderRadius.circular(999),
                      ),
                    ),
                  ),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      for (final level in levels)
                        GestureDetector(
                          onTap: () => onChanged(level),
                          behavior: HitTestBehavior.translucent,
                          child: SizedBox(
                            width: 28,
                            height: 28,
                            child: Center(
                              child: Container(
                                width: (value - level).abs() < 0.1 ? 12 : 9,
                                height: (value - level).abs() < 0.1 ? 12 : 9,
                                decoration: BoxDecoration(
                                  color: (value - level).abs() < 0.1
                                      ? activeColor
                                      : inactiveColor,
                                  shape: BoxShape.circle,
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            );
          },
        ),
        const SizedBox(height: 8),
        Text(
          '当前：${_getSpeedLabel(value)}',
          style: TextStyle(
            color: textColor.withOpacity(0.65),
            fontSize: 12,
          ),
        ),
      ],
    );
  }

  Widget _readAloudSettings({required Color cardBg}) {
    final provider = context.watch<TranslationProvider>();
    final aiModel = context.watch<AiModelProvider>();
    final engine = provider.readAloudEngine;
    final localAvailable = provider.localReadAloudAvailable;
    final isLocal = engine == ReadAloudEngine.local;
    final voiceItems = <String, String>{
      for (final e in _ttsLargeModelVoices.entries) e.key.toString(): e.value,
    };
    final voiceValue = (_voiceType ?? provider.ttsVoiceType).toString();
    final speedValue = _speed ?? provider.ttsSpeed;
    final displayedVoiceItems =
        isLocal ? const <String, String>{'0': '无'} : voiceItems;
    final displayedVoiceValue = isLocal
        ? '0'
        : (voiceItems.containsKey(voiceValue)
            ? voiceValue
            : voiceItems.keys.first);

    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: cardBg,
        borderRadius: BorderRadius.circular(AppTokens.radiusMd),
        border: Border.all(
            color: widget.textColor.withOpacity(0.08), width: AppTokens.stroke),
      ),
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '朗读设置',
            style: TextStyle(
              color: widget.textColor,
              fontWeight: FontWeight.w900,
              fontSize: 15,
            ),
          ),
          const SizedBox(height: 12),
          _itemBox(
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '朗读引擎',
                  style: TextStyle(
                    color: widget.textColor,
                    fontSize: 13,
                    fontWeight: FontWeight.normal,
                  ),
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 12,
                  runSpacing: 10,
                  children: [
                    _chip(
                      label: '本地',
                      active: engine == ReadAloudEngine.local,
                      onTap: () =>
                          provider.setReadAloudEngine(ReadAloudEngine.local),
                      textColor: widget.textColor,
                    ),
                    _chip(
                      label: '在线',
                      active: engine == ReadAloudEngine.online,
                      onTap: () =>
                          provider.setReadAloudEngine(ReadAloudEngine.online),
                      textColor: widget.textColor,
                    ),
                  ],
                ),
                if (isLocal && !localAvailable) ...[
                  const SizedBox(height: 10),
                  Text(
                    '本地朗读不可用',
                    style: TextStyle(
                      color: widget.textColor.withOpacity(0.65),
                      fontSize: 13,
                      height: 1.35,
                    ),
                  ),
                ],
                if (!isLocal) ...[
                  const SizedBox(height: 12),
                  if (provider.usingPersonalTencentKeys) ...[
                    Text(
                      '使用腾讯大模型朗读（个人密钥）',
                      style: TextStyle(
                        color: widget.textColor.withOpacity(0.65),
                        fontSize: 13,
                        height: 1.35,
                      ),
                    ),
                  ] else ...[
                    Text(
                      '使用腾讯大模型朗读'
                      '${aiModel.onlineEntitlementActive ? '' : '，需要购买时长后使用'}',
                      style: TextStyle(
                        color: widget.textColor.withOpacity(0.65),
                        fontSize: 13,
                        height: 1.35,
                      ),
                    ),
                    const SizedBox(height: 10),
                    _redeemRow(aiModel, cardBg: cardBg),
                  ],
                ],
              ],
            ),
          ),
          const SizedBox(height: 10),
          _itemBox(
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '朗读内容',
                  style: TextStyle(
                    color: widget.textColor,
                    fontSize: 13,
                    fontWeight: FontWeight.normal,
                  ),
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 12,
                  runSpacing: 10,
                  children: [
                    _chip(
                      label: '不读译文',
                      active: !provider.readTranslationEnabled,
                      onTap: () => provider.setReadTranslationEnabled(false),
                      textColor: widget.textColor,
                    ),
                    _chip(
                      label: '读译文',
                      active: provider.readTranslationEnabled,
                      onTap: () => provider.setReadTranslationEnabled(true),
                      textColor: widget.textColor,
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          _itemBox(
            Opacity(
              opacity: isLocal ? 0.45 : 1,
              child: IgnorePointer(
                ignoring: isLocal,
                child: _dropdown(
                  label: '音色选择',
                  value: displayedVoiceValue,
                  items: displayedVoiceItems,
                  onChanged: (v) async {
                    if (isLocal) return;
                    final parsed = int.tryParse(v ?? '');
                    if (parsed == null) return;
                    setState(() {
                      _voiceType = parsed;
                    });
                    await provider.setTtsVoiceType(parsed);
                  },
                  textColor: widget.textColor,
                  dropdownColor: cardBg,
                ),
              ),
            ),
          ),
          const SizedBox(height: 10),
          _itemBox(
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '语速',
                  style: TextStyle(
                    color: widget.textColor,
                    fontSize: 13,
                    fontWeight: FontWeight.normal,
                  ),
                ),
                const SizedBox(height: 10),
                _speedBar(
                  levels: const [-2.0, -1.0, 0.0, 1.0, 2.0, 6.0],
                  value: speedValue,
                  onChanged: (level) {
                    setState(() => _speed = level);
                    provider.setTtsSpeed(level);
                  },
                  textColor: widget.textColor,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _chip({
    required String label,
    required bool active,
    required VoidCallback onTap,
    required Color textColor,
  }) {
    const double chipHeight = 32;
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: active
              ? AppColors.techBlue.withOpacity(0.12)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: active ? AppColors.techBlue : textColor.withOpacity(0.18),
            width: AppTokens.stroke,
          ),
        ),
        child: SizedBox(
          height: chipHeight,
          child: Center(
            widthFactor: 1,
            child: Text(
              label,
              style: TextStyle(
                fontSize: 13,
                color:
                    active ? AppColors.techBlue : textColor.withOpacity(0.75),
                fontWeight: active ? FontWeight.w600 : FontWeight.w500,
                height: 1.1,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _dropdown({
    required String label,
    required String value,
    required Map<String, String> items,
    required ValueChanged<String?> onChanged,
    required Color textColor,
    required Color dropdownColor,
  }) {
    final bg = widget.isDark ? const Color(0xFF2A2A2A) : Colors.white;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style: TextStyle(
                color: textColor, fontWeight: FontWeight.normal, fontSize: 13)),
        const SizedBox(height: 6),
        SizedBox(
          height: 32,
          child: DropdownButtonFormField<String>(
            value: items.containsKey(value) ? value : items.keys.first,
            dropdownColor: bg,
            style: TextStyle(color: textColor, fontSize: 13),
            iconEnabledColor: textColor.withOpacity(0.75),
            decoration: InputDecoration(
              isDense: true,
              filled: true,
              fillColor: bg,
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              border:
                  OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(
                  color: textColor.withOpacity(0.18),
                  width: AppTokens.stroke,
                ),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(
                  color: textColor.withOpacity(0.18),
                  width: AppTokens.stroke,
                ),
              ),
            ),
            items: items.entries
                .map(
                  (e) => DropdownMenuItem<String>(
                    value: e.key,
                    child: Text(e.value,
                        style: TextStyle(fontSize: 13, color: textColor)),
                  ),
                )
                .toList(),
            onChanged: onChanged,
          ),
        ),
      ],
    );
  }

  Widget _qaContentScopeSettings({
    required Color cardBg,
  }) {
    return Consumer<AiModelProvider>(
      builder: (context, aiModel, child) {
        final tp = context.watch<TranslationProvider>();
        return Container(
          width: double.infinity,
          decoration: BoxDecoration(
            color: cardBg,
            borderRadius: BorderRadius.circular(AppTokens.radiusMd),
            border: Border.all(
                color: widget.textColor.withOpacity(0.08),
                width: AppTokens.stroke),
          ),
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '问答设置',
                style: TextStyle(
                  color: widget.textColor,
                  fontWeight: FontWeight.w900,
                  fontSize: 14,
                ),
              ),
              const SizedBox(height: 12),
              _itemBox(
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '问答大模型',
                      style: TextStyle(
                        color: widget.textColor,
                        fontSize: 13,
                        fontWeight: FontWeight.normal,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 12,
                      runSpacing: 10,
                      children: [
                        _chip(
                          label: '本地',
                          active: aiModel.source == AiModelSource.local,
                          onTap: () {
                            final next = aiModel.source == AiModelSource.local
                                ? AiModelSource.none
                                : AiModelSource.local;
                            unawaited(aiModel.setSource(next));
                          },
                          textColor: widget.textColor,
                        ),
                        _chip(
                          label: '在线',
                          active: aiModel.source == AiModelSource.online,
                          onTap: () {
                            final next = aiModel.source == AiModelSource.online
                                ? AiModelSource.none
                                : AiModelSource.online;
                            unawaited(aiModel.setSource(next));
                          },
                          textColor: widget.textColor,
                        ),
                      ],
                    ),
                    if (aiModel.source == AiModelSource.online) ...[
                      const SizedBox(height: 12),
                      if (tp.usingPersonalTencentKeys) ...[
                        Text(
                          '使用腾讯混元大模型（个人密钥）',
                          style: TextStyle(
                            color: widget.textColor.withOpacity(0.65),
                            fontSize: 13,
                            height: 1.35,
                          ),
                        ),
                      ] else ...[
                        Text(
                          '使用腾讯混元大模型'
                          '${aiModel.onlineEntitlementActive ? '' : '，需要购买时长后使用'}',
                          style: TextStyle(
                            color: widget.textColor.withOpacity(0.65),
                            fontSize: 13,
                            height: 1.35,
                          ),
                        ),
                        const SizedBox(height: 10),
                        _redeemRow(aiModel, cardBg: cardBg),
                      ],
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 10),
              if (aiModel.source == AiModelSource.local) ...[
                _localModelStatusRow(
                  aiModel,
                  type: LocalLlmModelType.qa,
                  title: 'Hunyuan-1.8B-Instruct',
                  sizeText: '830M',
                  capabilityText: '问答',
                ),
                if (!aiModel.localModelDownloading &&
                    !aiModel.localModelInstalling &&
                    aiModel.localModelError.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  Text(
                    aiModel.localModelError,
                    style: const TextStyle(
                      color: Colors.redAccent,
                      fontSize: 13,
                      height: 1.35,
                    ),
                  ),
                ],
              ],
              const SizedBox(height: 10),
              _itemBox(
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '问答内容范围',
                      style: TextStyle(
                        color: widget.textColor,
                        fontSize: 13,
                        fontWeight: FontWeight.normal,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 10,
                      runSpacing: 10,
                      children: [
                        _scopeChip(
                          label: '当前页',
                          value: QAContentScope.currentPage,
                          groupValue: aiModel.qaContentScope,
                          onChanged: (scope) =>
                              aiModel.setQAContentScope(scope),
                        ),
                        _scopeChip(
                          label: '本章至当前',
                          value: QAContentScope.currentChapterToPage,
                          groupValue: aiModel.qaContentScope,
                          onChanged: (scope) =>
                              aiModel.setQAContentScope(scope),
                        ),
                        _scopeChip(
                          label: '前后5页',
                          value: QAContentScope.slidingWindow,
                          groupValue: aiModel.qaContentScope,
                          onChanged: (scope) =>
                              aiModel.setQAContentScope(scope),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _scopeChip({
    required String label,
    required QAContentScope value,
    required QAContentScope groupValue,
    required ValueChanged<QAContentScope> onChanged,
  }) {
    final bool active = value == groupValue;
    const double chipHeight = 32;
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () => onChanged(value),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: active
              ? AppColors.techBlue.withOpacity(0.12)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: active
                ? AppColors.techBlue
                : widget.textColor.withOpacity(0.18),
            width: AppTokens.stroke,
          ),
        ),
        child: SizedBox(
          height: chipHeight,
          child: Center(
            widthFactor: 1,
            child: Text(
              label,
              style: TextStyle(
                fontSize: 13,
                color: active
                    ? AppColors.techBlue
                    : widget.textColor.withOpacity(0.75),
                fontWeight: active ? FontWeight.w600 : FontWeight.w500,
                height: 1.1,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _localModelStatusRow(
    AiModelProvider aiModel, {
    required LocalLlmModelType type,
    required String title,
    required String sizeText,
    required String capabilityText,
  }) {
    String text = '$title未下载($sizeText)，下载后可在无网环境使用$capabilityText';
    Widget? action;

    if (aiModel.isLocalModelInstallingByType(type)) {
      text = '$title安装中…';
      action = const SizedBox(
        width: 16,
        height: 16,
        child: CircularProgressIndicator(
          strokeWidth: 2,
          value: null,
          color: AppColors.techBlue,
        ),
      );
    } else if (aiModel.isLocalModelDownloadingByType(type)) {
      text = '$title下载中，下载后可在无网环境使用$capabilityText';
      String pctText = '';
      final total = aiModel.localModelTotalBytesByType(type);
      final double progress =
          aiModel.localModelProgressByType(type).clamp(0.0, 1.0);
      if (total > 0) {
        final pct = (progress * 100).round();
        pctText = '$pct%';
      }
      action = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              value: total > 0 ? progress : null,
              color: AppColors.techBlue,
            ),
          ),
          if (pctText.isNotEmpty) ...[
            const SizedBox(width: 8),
            Text(
              pctText,
              style: const TextStyle(
                color: AppColors.techBlue,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
          const SizedBox(width: 12),
          InkWell(
            onTap: aiModel.pauseLocalModelDownload,
            child: Text(
              '暂停',
              style: TextStyle(
                color: widget.textColor.withOpacity(0.6),
                fontSize: 13,
              ),
            ),
          ),
        ],
      );
    } else if (aiModel.isLocalModelQueuedByType(type)) {
      text = '$title已加入队列，等待下载…';
      action = Text(
        '队列中',
        style: TextStyle(
          color: widget.textColor.withOpacity(0.6),
          fontSize: 13,
        ),
      );
    } else if (aiModel.isLocalModelPausedByType(type)) {
      text = '$title下载已暂停，点击下载继续';
      String pctText = '';
      final total = aiModel.localModelTotalBytesByType(type);
      final double progress =
          aiModel.localModelProgressByType(type).clamp(0.0, 1.0);
      if (total > 0) {
        final pct = (progress * 100).round();
        pctText = '$pct%';
      }
      action = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (pctText.isNotEmpty) ...[
            Text(
              pctText,
              style: TextStyle(
                color: widget.textColor.withOpacity(0.6),
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(width: 12),
          ],
          InkWell(
            onTap: () => aiModel.startLocalModelDownloadForType(type),
            child: const Text(
              '下载',
              style: TextStyle(
                color: AppColors.techBlue,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      );
    } else if (aiModel.localModelExistsByType(type)) {
      text = '可在无网环境使用$capabilityText';
      action = null;
    } else {
      action = InkWell(
        onTap: () => aiModel.startLocalModelDownloadForType(type),
        child: const Text(
          '下载',
          style: TextStyle(
            color: AppColors.techBlue,
            fontSize: 13,
            fontWeight: FontWeight.w600,
          ),
        ),
      );
    }

    return Row(
      children: [
        Expanded(
          child: Text(
            text,
            style: TextStyle(
              color: widget.textColor.withOpacity(0.65),
              fontSize: 13,
              height: 1.35,
            ),
          ),
        ),
        if (action != null) ...[
          const SizedBox(width: 12),
          action,
        ],
      ],
    );
  }
}

class _MainPanel extends StatelessWidget {
  final bool isDark;
  final Color bgColor;
  final Color textColor;

  final bool translateEnabled;
  final bool translateActive;
  final ValueChanged<bool>? onTranslateChanged;

  final bool readAloudEnabled;
  final ValueChanged<bool>? onReadAloudChanged;

  final VoidCallback onOpenQa;
  final void Function(String, {bool isError})? onShowTopMessage;

  const _MainPanel({
    super.key,
    required this.isDark,
    required this.bgColor,
    required this.textColor,
    required this.translateEnabled,
    required this.translateActive,
    required this.onTranslateChanged,
    required this.readAloudEnabled,
    required this.onReadAloudChanged,
    required this.onOpenQa,
    this.onShowTopMessage,
  });

  @override
  Widget build(BuildContext context) {
    final aiModel = context.watch<AiModelProvider>();
    final translationProvider = context.watch<TranslationProvider>();
    final source = aiModel.source;
    final onlineEntitled = aiModel.onlineEntitlementActive;
    final usingPersonalKeys = translationProvider.usingPersonalTencentKeys;
    final personalKeysUsable = getEmbeddedPublicHunyuanCredentials().isUsable;
    final personalKeysMissing = usingPersonalKeys && !personalKeysUsable;

    final bool qaReady = switch (source) {
      AiModelSource.none => false,
      AiModelSource.online =>
        onlineEntitled || (usingPersonalKeys && personalKeysUsable),
      AiModelSource.local => aiModel.isLocalQaModelReady,
    };

    final String localQaSubtitle = switch (source) {
      AiModelSource.local when !qaReady =>
        aiModel.isLocalModelInstallingByType(LocalLlmModelType.qa)
            ? '模型安装中，安装后可使用'
            : (aiModel.isLocalModelDownloadingByType(LocalLlmModelType.qa) ||
                    aiModel.isLocalModelQueuedByType(LocalLlmModelType.qa))
                ? '模型下载中，下载后可使用'
                : aiModel.isLocalModelPausedByType(LocalLlmModelType.qa)
                    ? '模型下载已暂停，继续后可使用'
                    : !aiModel.localModelExistsByType(LocalLlmModelType.qa)
                        ? '模型未下载，下载后可使用'
                        : '模型准备中，稍后可使用',
      _ => '',
    };

    final bool translationBlockedByKeys = personalKeysMissing;
    final bool translationBlockedByEntitlement =
        translationProvider.translationMode == TranslationMode.bigModel &&
            !onlineEntitled &&
            !usingPersonalKeys;
    final bool translationBlocked =
        translationBlockedByKeys || translationBlockedByEntitlement;
    final bool translateValue = translationBlocked ? false : translateEnabled;
    final ValueChanged<bool>? translateOnChanged =
        translationBlocked ? null : onTranslateChanged;

    String translateSubtitle;
    if (translationBlockedByKeys) {
      translateSubtitle = '已开启使用个人密钥，但未正确设置个人密钥';
    } else if (translationBlockedByEntitlement) {
      translateSubtitle = '大模型翻译需购买时长后使用';
    } else if (!translateValue) {
      translateSubtitle = '打开后将实时对内容进行翻译';
    } else {
      translateSubtitle = '翻译中...';
    }

    final localReadAloudBlocked =
        translationProvider.readAloudEngine == ReadAloudEngine.local &&
            !translationProvider.localReadAloudAvailable;
    final onlineReadAloudBlocked =
        translationProvider.readAloudEngine == ReadAloudEngine.online &&
            !onlineEntitled &&
            !usingPersonalKeys;
    final onlineReadAloudKeysMissing =
        translationProvider.readAloudEngine == ReadAloudEngine.online &&
            personalKeysMissing;
    final readAloudBlocked = localReadAloudBlocked ||
        onlineReadAloudBlocked ||
        onlineReadAloudKeysMissing;
    final readAloudSubtitle = localReadAloudBlocked
        ? '本地朗读不可用，可切换在线'
        : (onlineReadAloudKeysMissing
            ? '已开启使用个人密钥，但未正确设置个人密钥'
            : (onlineReadAloudBlocked
                ? '在线朗读需要购买时长后使用'
                : (readAloudEnabled ? '已开启，点击页面小喇叭朗读或暂停' : '开启后，可朗读当前页')));
    final bool readAloudValue =
        localReadAloudBlocked ? false : readAloudEnabled;

    return SingleChildScrollView(
      key: const PageStorageKey('ai_hud_main_scroll'),
      padding: const EdgeInsets.only(bottom: 6),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _featureRow(
            context,
            icon: Icons.translate,
            title: '翻译',
            subtitle: translateSubtitle,
            value: translateValue,
            onChanged: translateOnChanged,
          ),
          const SizedBox(height: 10),
          _featureRow(
            context,
            icon: Icons.volume_up,
            title: '朗读',
            subtitle: readAloudSubtitle,
            value: readAloudValue,
            onChanged: readAloudBlocked ? null : onReadAloudChanged,
          ),
          const SizedBox(height: 14),
          _qaEntry(
            enabled: qaReady,
            subtitle: source == AiModelSource.none
                ? '需要选择问答大模型后使用'
                : (source == AiModelSource.local && !qaReady)
                    ? localQaSubtitle
                    : (source == AiModelSource.online && personalKeysMissing)
                        ? '已开启使用个人密钥，但未正确设置个人密钥'
                        : (source == AiModelSource.online &&
                                !onlineEntitled &&
                                !usingPersonalKeys)
                            ? '在线大模型需要购买时长后使用'
                            : '支持问答/总结/提取要点',
            onTap: onOpenQa,
          ),
        ],
      ),
    );
  }

  Widget _featureRow(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String subtitle,
    required bool value,
    required ValueChanged<bool>? onChanged,
  }) {
    final Color cardBg =
        isDark ? Colors.white.withOpacity(0.07) : AppColors.mistWhite;
    final Color borderColor = value
        ? AppColors.techBlue.withOpacity(0.55)
        : textColor.withOpacity(0.08);

    final bool disabled = onChanged == null;

    return Container(
      decoration: BoxDecoration(
        color: cardBg,
        borderRadius: BorderRadius.circular(AppTokens.radiusMd),
        border: Border.all(color: borderColor, width: AppTokens.stroke),
      ),
      padding: const EdgeInsets.fromLTRB(10, 10, 6, 10),
      child: Row(
        children: [
          Expanded(
            child: InkWell(
              onTap: () {
                if (disabled) return;
                onChanged(!value);
              },
              borderRadius: BorderRadius.circular(AppTokens.radiusMd),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(4, 2, 6, 2),
                child: Row(
                  children: [
                    Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        color: value
                            ? AppColors.techBlue.withOpacity(0.12)
                            : textColor.withOpacity(0.06),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Icon(
                        icon,
                        color: value
                            ? AppColors.techBlue
                            : textColor.withOpacity(0.8),
                        size: 20,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            title,
                            style: TextStyle(
                              color: textColor,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            subtitle,
                            style: TextStyle(
                              color: textColor.withOpacity(0.65),
                              fontSize: 12,
                              height: 1.35,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(width: 6),
          Switch(
            value: value,
            activeColor: AppColors.techBlue,
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }

  Widget _qaEntry({
    required bool enabled,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    final Color cardBg =
        isDark ? Colors.white.withOpacity(0.07) : AppColors.mistWhite;

    return InkWell(
      onTap: enabled ? onTap : null,
      borderRadius: BorderRadius.circular(AppTokens.radiusMd),
      child: Container(
        decoration: BoxDecoration(
          color: cardBg,
          borderRadius: BorderRadius.circular(AppTokens.radiusMd),
          border: Border.all(
              color: textColor.withOpacity(0.08), width: AppTokens.stroke),
        ),
        padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: enabled
                    ? AppColors.techBlue.withOpacity(0.12)
                    : textColor.withOpacity(0.06),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(
                Icons.question_answer,
                color:
                    enabled ? AppColors.techBlue : textColor.withOpacity(0.7),
                size: 20,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        '问答',
                        style: TextStyle(
                          color: textColor,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    subtitle,
                    style: TextStyle(
                      color: textColor.withOpacity(0.65),
                      fontSize: 12,
                      height: 1.35,
                    ),
                  ),
                ],
              ),
            ),
            Icon(Icons.chevron_right, color: textColor.withOpacity(0.6)),
          ],
        ),
      ),
    );
  }
}

enum _QaRole { user, assistant, divider }

class _QaMsg {
  final _QaRole role;
  final String text;
  final String reasoning;
  final bool reasoningCollapsed;
  const _QaMsg(
    this.role,
    this.text, {
    this.reasoning = '',
    this.reasoningCollapsed = true,
  });

  Map<String, dynamic> toJson() => {
        'role': role.name,
        'text': text,
        'reasoning': reasoning,
        'reasoningCollapsed': reasoningCollapsed,
      };

  static _QaMsg fromJson(Map<String, dynamic> json) {
    final rawRole = (json['role'] ?? '').toString();
    final role = _QaRole.values.firstWhere(
      (e) => e.name == rawRole,
      orElse: () => _QaRole.assistant,
    );
    return _QaMsg(
      role,
      (json['text'] ?? '').toString(),
      reasoning: (json['reasoning'] ?? '').toString(),
      reasoningCollapsed: (json['reasoningCollapsed'] is bool)
          ? (json['reasoningCollapsed'] as bool)
          : true,
    );
  }
}

enum _MessageState {
  idle,
  thinking,
  answering,
}

class _QaPanel extends StatefulWidget {
  final bool isDark;
  final Color bgColor;
  final Color textColor;
  final String? initialQaText;
  final bool autoSendInitialQa;
  final VoidCallback? onInitialQaConsumed;
  final String bookId;
  final Map<int, String> chapterTextCache;
  final int currentChapterIndex;
  final int currentPageInChapter;
  final Map<int, List<TextRange>> chapterPageRanges;
  final void Function(String, {bool isError})? onShowTopMessage;

  const _QaPanel({
    super.key,
    required this.isDark,
    required this.bgColor,
    required this.textColor,
    this.initialQaText,
    this.autoSendInitialQa = false,
    this.onInitialQaConsumed,
    required this.bookId,
    required this.chapterTextCache,
    required this.currentChapterIndex,
    required this.currentPageInChapter,
    required this.chapterPageRanges,
    this.onShowTopMessage,
  });

  @override
  State<_QaPanel> createState() => _QaPanelState();
}

class _QaPanelState extends State<_QaPanel> {
  static const String _kWelcomeMessage =
      '你好，我是Air！你的AI伴读助手。\n我可以帮你总结章节要点、解释复杂概念，或者回答任何关于这本书的问题。\n快来问我吧！';
  final TextEditingController _inputCtl = TextEditingController();
  final ScrollController _scrollCtl = ScrollController();
  final List<_QaMsg> _messages = [];
  Timer? _persistTimer;
  int? _activeReplyIndex;
  _MessageState _messageState = _MessageState.idle;
  bool _initialQaHandled = false;

  // Throttling for web setState
  Timer? _updateTimer;
  bool _needsUiUpdate = false;
  bool _shouldScrollToBottom = false;

  QaStreamProvider? _qaStream;
  VoidCallback? _qaStreamListener;
  int? _activeStreamId;
  int? _activeStreamReplyIndex;
  String? _lastErrorMessage;

  String get _historyKey => 'qa_history_${widget.bookId}';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      _qaStream = context.read<QaStreamProvider>();
      _qaStreamListener = _onQaStreamUpdated;
      _qaStream?.addListener(_qaStreamListener!);

      await _loadHistory();
      if (!mounted) return;
      _attachActiveStreamIfAny();
    });
  }

  void _applyInitialQaIfNeeded() {
    if (_initialQaHandled) return;
    final t = (widget.initialQaText ?? '').trim();
    if (t.isEmpty) return;
    _initialQaHandled = true;
    widget.onInitialQaConsumed?.call();
    _inputCtl.text = t;
    if (widget.autoSendInitialQa) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _send();
      });
    } else {
      if (mounted) setState(() {});
    }
  }

  Future<void> _loadHistory() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_historyKey) ?? '';
    if (raw.trim().isNotEmpty) {
      final decoded = await Future.value(raw)
          .then((v) => jsonDecode(v))
          .catchError((_) => null);
      if (decoded is List) {
        _messages
          ..clear()
          ..addAll(decoded
              .whereType<Map>()
              .map((e) => _QaMsg.fromJson(e.cast<String, dynamic>())));
        // Reset stream attachment since list was replaced
        _activeStreamReplyIndex = null;
        _activeReplyIndex = null;
      }
    }

    if (_messages.isEmpty) {
      _messages.add(const _QaMsg(
        _QaRole.assistant,
        _kWelcomeMessage,
      ));
    }

    if (!mounted) return;
    setState(() {});
    _applyInitialQaIfNeeded();
  }

  void _schedulePersist() {
    _persistTimer?.cancel();
    _persistTimer = Timer(const Duration(milliseconds: 400), _persistNow);
  }

  Future<void> _persistNow() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = jsonEncode(_messages.map((e) => e.toJson()).toList());
    await prefs.setString(_historyKey, raw);
  }

  bool _isWelcomeMessage(_QaMsg msg) {
    return msg.role == _QaRole.assistant && msg.text.startsWith('你好，我是Air！');
  }

  String _buildHistoryText({int maxTurns = 6}) {
    final int lastDividerIndex =
        _messages.lastIndexWhere((m) => m.role == _QaRole.divider);

    final items = _messages
        .asMap()
        .entries
        .where((e) => e.key > lastDividerIndex)
        .map((e) => e.value)
        .where((m) => m.text.trim().isNotEmpty && !_isWelcomeMessage(m))
        .toList();

    if (items.isEmpty) return '';
    final start = (items.length - maxTurns).clamp(0, items.length);
    final recent = items.sublist(start);
    final buffer = StringBuffer();
    for (final m in recent) {
      final prefix = m.role == _QaRole.user ? '用户' : '助手';
      buffer.writeln('$prefix: ${m.text.trim()}');
    }
    return buffer.toString().trim();
  }

  void _startNewTopic() {
    if (_messageState != _MessageState.idle) return;
    setState(() {
      _messages.add(const _QaMsg(
        _QaRole.divider,
        '已开启新话题',
      ));
      _messageState = _MessageState.idle;
      _activeReplyIndex = null;
    });
    _qaStream?.cancel(widget.bookId);
    _schedulePersist();
    _scrollToBottom();
  }

  void _throttledUpdate() {
    if (!mounted) return;
    if (_needsUiUpdate) {
      setState(() {});
      _needsUiUpdate = false;
    }
    if (_shouldScrollToBottom) {
      _scrollToBottom();
      _shouldScrollToBottom = false;
    }
  }

  /// 更新消息列表
  void _updateMessage(int index, _QaMsg message) {
    if (!mounted) return;
    _messages[index] = message;
    _needsUiUpdate = true;
    _shouldScrollToBottom = true;

    if (kIsWeb) {
      if (_updateTimer == null || !_updateTimer!.isActive) {
        _updateTimer =
            Timer(const Duration(milliseconds: 30), _throttledUpdate);
      }
    } else {
      _throttledUpdate();
    }
  }

  @override
  void dispose() {
    _persistTimer?.cancel();
    _inputCtl.dispose();
    _scrollCtl.dispose();
    if (_qaStreamListener != null) {
      _qaStream?.removeListener(_qaStreamListener!);
    }
    super.dispose();
  }

  void _attachActiveStreamIfAny() {
    final s = _qaStream?.stateFor(widget.bookId);
    if (s == null) return;
    final hasAny = s.think.trim().isNotEmpty || s.answer.trim().isNotEmpty;
    if (!s.isStreaming && !hasAny && !s.hasError) return;

    final lastUserText =
        _messages.lastIndexWhere((m) => m.role == _QaRole.user);

    int replyIndex = -1;

    if (lastUserText < 0 || _messages[lastUserText].text.trim() != s.question) {
      _messages.add(_QaMsg(_QaRole.user, s.question));
      replyIndex = _messages.length;
      _messages.add(_QaMsg(
        _QaRole.assistant,
        s.answer,
        reasoning: s.think,
        reasoningCollapsed: s.answer.trim().isNotEmpty,
      ));
    } else {
      // User question found. Check if next message is assistant.
      if (lastUserText + 1 < _messages.length &&
          _messages[lastUserText + 1].role == _QaRole.assistant) {
        replyIndex = lastUserText + 1;
        // Reuse and update
        final old = _messages[replyIndex];
        _messages[replyIndex] = _QaMsg(
          _QaRole.assistant,
          s.answer,
          reasoning: s.think,
          reasoningCollapsed: old.reasoningCollapsed,
        );
      } else {
        replyIndex = _messages.length;
        _messages.add(_QaMsg(
          _QaRole.assistant,
          s.answer,
          reasoning: s.think,
          reasoningCollapsed: s.answer.trim().isNotEmpty,
        ));
      }
    }

    _activeStreamId = s.streamId;
    _activeStreamReplyIndex = replyIndex;
    _activeReplyIndex = s.isStreaming ? replyIndex : null;
    _messageState = s.isStreaming
        ? (s.answer.trim().isNotEmpty
            ? _MessageState.answering
            : _MessageState.thinking)
        : _MessageState.idle;
    _needsUiUpdate = true;
    _shouldScrollToBottom = true;
    _throttledUpdate();
  }

  void _onQaStreamUpdated() {
    if (!mounted) return;
    final s = _qaStream?.stateFor(widget.bookId);
    if (s == null) return;
    if (!s.hasError) {
      _lastErrorMessage = null;
    }

    if (_activeStreamId != s.streamId || _activeStreamReplyIndex == null) {
      _attachActiveStreamIfAny();
      return;
    }

    final hasAny = s.think.trim().isNotEmpty || s.answer.trim().isNotEmpty;

    if (_activeStreamReplyIndex == null) {
      if (s.hasError) {
        _showTopError(s.error);
        setState(() {
          _messages.add(_QaMsg(_QaRole.assistant, '错误: ${s.error}'));
          _messageState = _MessageState.idle;
          _activeReplyIndex = null;
        });
        _schedulePersist();
        _scrollToBottom();
        return;
      }

      if (!hasAny) {
        if (!s.isStreaming) {
          setState(() {
            _messageState = _MessageState.idle;
            _activeReplyIndex = null;
          });
        }
        return;
      }

      final idx = _messages.length;
      setState(() {
        _messages.add(_QaMsg(
          _QaRole.assistant,
          s.answer,
          reasoning: s.think,
          reasoningCollapsed: s.answer.trim().isNotEmpty,
        ));
        _activeStreamReplyIndex = idx;
        _activeReplyIndex = s.isStreaming ? idx : null;
        _messageState = s.isStreaming
            ? (s.answer.trim().isNotEmpty
                ? _MessageState.answering
                : _MessageState.thinking)
            : _MessageState.idle;
      });
      _schedulePersist();
      _scrollToBottom();
      return;
    }

    final idx = _activeStreamReplyIndex!;
    if (idx < 0 || idx >= _messages.length) {
      _activeStreamReplyIndex = null;
      _onQaStreamUpdated();
      return;
    }

    if (s.hasError) {
      _showTopError(s.error);
      _updateMessage(idx, _QaMsg(_QaRole.assistant, '错误: ${s.error}'));
      _messageState = _MessageState.idle;
      _activeReplyIndex = null;
      _schedulePersist();
      return;
    }

    final cur = _messages[idx];
    var collapsed = cur.reasoningCollapsed;
    if (cur.reasoning.trim().isNotEmpty &&
        !collapsed &&
        s.answer.trim().isNotEmpty) {
      collapsed = true;
    }
    _updateMessage(
      idx,
      _QaMsg(
        _QaRole.assistant,
        s.answer,
        reasoning: s.think,
        reasoningCollapsed: collapsed,
      ),
    );

    if (s.isStreaming) {
      _activeReplyIndex = idx;
      _messageState = s.answer.trim().isNotEmpty
          ? _MessageState.answering
          : _MessageState.thinking;
      return;
    }

    _activeReplyIndex = null;
    _messageState = _MessageState.idle;
    _schedulePersist();
  }

  void _sendQuickAction(QAType qaType) async {
    if (_messageState != _MessageState.idle) return;

    final String quickText;
    switch (qaType) {
      case QAType.summary:
        quickText = '总结当前章节';
        break;
      case QAType.keyPoints:
        quickText = '提取本章要点';
        break;
      default:
        return;
    }

    setState(() {
      _messages.add(_QaMsg(_QaRole.user, quickText));
      _messageState = _MessageState.thinking;
    });
    _schedulePersist();
    _scrollToBottom();

    _performQa(quickText, qaType, '');
  }

  Future<void> _send() async {
    final text = _inputCtl.text.trim();
    if (text.isEmpty || _messageState != _MessageState.idle) return;

    if (text == '总结本章') {
      _inputCtl.clear();
      _sendQuickAction(QAType.summary);
      return;
    }
    if (text == '提取要点') {
      _inputCtl.clear();
      _sendQuickAction(QAType.keyPoints);
      return;
    }

    final historyText = _buildHistoryText();

    setState(() {
      _messages.add(_QaMsg(_QaRole.user, text));
      _messageState = _MessageState.thinking;
      _inputCtl.text = '';
    });
    _schedulePersist();
    _scrollToBottom();

    _performQa(text, QAType.general, historyText);
  }

  Future<void> _cancelActive() async {
    await (_qaStream ?? context.read<QaStreamProvider>()).cancel(widget.bookId);
    if (!mounted) return;
    setState(() {
      _messageState = _MessageState.idle;
      _activeReplyIndex = null;
      _activeStreamReplyIndex = null;
    });
    _schedulePersist();
  }

  Future<void> _performQa(
      String question, QAType qaType, String history) async {
    final qaStream = _qaStream ?? context.read<QaStreamProvider>();
    _qaStream ??= qaStream;

    setState(() {
      _activeReplyIndex = null;
      _activeStreamReplyIndex = null;
      _messageState = _MessageState.thinking;
    });
    _schedulePersist();
    _scrollToBottom();

    final aiModel = context.read<AiModelProvider>();
    final contextService = ReadingContextService(
      chapterContentCache: widget.chapterTextCache,
      currentChapterIndex: widget.currentChapterIndex,
      currentPageInChapter: widget.currentPageInChapter,
      chapterPageRanges: widget.chapterPageRanges,
    );

    final streamId = await qaStream.start(
      bookId: widget.bookId,
      question: question,
      qaType: qaType,
      aiModel: aiModel,
      contextService: contextService,
      history: history,
    );
    _activeStreamId = streamId;
    _onQaStreamUpdated();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollCtl.hasClients) return;
      _scrollCtl.animateTo(
        _scrollCtl.position.maxScrollExtent,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
      );
    });
  }

  void _showTopError(String message) {
    if (message.trim().isEmpty) return;
    if (_lastErrorMessage == message) return;
    _lastErrorMessage = message;

    if (widget.onShowTopMessage != null) {
      widget.onShowTopMessage!(message, isError: true);
      return;
    }

    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentMaterialBanner();
    messenger.showMaterialBanner(
      MaterialBanner(
        backgroundColor: Colors.red.withOpacity(0.95),
        content: Text(
          message,
          style: const TextStyle(color: Colors.white),
        ),
        actions: [
          TextButton(
            onPressed: () => messenger.hideCurrentMaterialBanner(),
            child: const Text('关闭', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
    Future.delayed(const Duration(seconds: 3), () {
      if (!mounted) return;
      messenger.hideCurrentMaterialBanner();
    });
  }

  @override
  Widget build(BuildContext context) {
    final Color cardBg =
        widget.isDark ? Colors.white.withOpacity(0.07) : AppColors.mistWhite;

    Widget actionChip({
      required String label,
      required VoidCallback? onTap,
    }) {
      final bool disabled = onTap == null;
      return InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(999),
        child: Container(
          height: 28,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: disabled
                ? AppColors.techBlue.withOpacity(0.05)
                : AppColors.techBlue.withOpacity(0.12),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
              color: disabled
                  ? AppColors.techBlue.withOpacity(0.2)
                  : AppColors.techBlue.withOpacity(0.35),
              width: AppTokens.stroke,
            ),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                label,
                style: TextStyle(
                  fontSize: 13,
                  color: disabled
                      ? AppColors.techBlue.withOpacity(0.4)
                      : AppColors.techBlue,
                  fontWeight: FontWeight.w600,
                  height: 1.2,
                ),
              ),
            ],
          ),
        ),
      );
    }

    final panelContent = SizedBox.expand(
      key: widget.key,
      child: Container(
        decoration: BoxDecoration(
          color: cardBg,
          borderRadius: BorderRadius.circular(AppTokens.radiusMd),
          border: Border.all(
              color: widget.textColor.withOpacity(0.08),
              width: AppTokens.stroke),
        ),
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: ListView.builder(
                key: const PageStorageKey('ai_hud_qa_list'),
                controller: _scrollCtl,
                itemCount: _messages.length,
                itemBuilder: (context, i) {
                  final m = _messages[i];

                  if (m.role == _QaRole.divider) {
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      child: Row(
                        children: [
                          Expanded(
                              child: Divider(
                                  color: widget.textColor.withOpacity(0.1))),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                            child: Text(
                              m.text,
                              style: TextStyle(
                                fontSize: 13,
                                color: widget.textColor.withOpacity(0.4),
                              ),
                            ),
                          ),
                          Expanded(
                              child: Divider(
                                  color: widget.textColor.withOpacity(0.1))),
                        ],
                      ),
                    );
                  }

                  final bool isUser = m.role == _QaRole.user;
                  final Color bubbleBg = isUser
                      ? AppColors.techBlue.withOpacity(0.18)
                      : widget.textColor.withOpacity(0.06);
                  final Alignment align =
                      isUser ? Alignment.centerRight : Alignment.centerLeft;
                  return Align(
                    key: ValueKey('qa_msg_${i}_${m.text.hashCode}'),
                    alignment: align,
                    child: Container(
                      margin: const EdgeInsets.symmetric(vertical: 6),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 10),
                      constraints: const BoxConstraints(maxWidth: 340),
                      decoration: BoxDecoration(
                        color: bubbleBg,
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                          color: widget.textColor.withOpacity(0.08),
                          width: AppTokens.stroke,
                        ),
                      ),
                      child: isUser
                          ? Text(
                              m.text,
                              style: TextStyle(
                                color: widget.textColor,
                                height: 1.35,
                                fontSize: 15,
                              ),
                            )
                          : Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                if (m.reasoning.trim().isNotEmpty) ...[
                                  InkWell(
                                    onTap: () {
                                      setState(() {
                                        final cur = _messages[i];
                                        _messages[i] = _QaMsg(
                                          cur.role,
                                          cur.text,
                                          reasoning: cur.reasoning,
                                          reasoningCollapsed:
                                              !cur.reasoningCollapsed,
                                        );
                                      });
                                      _schedulePersist();
                                    },
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Text(
                                          '深度思考',
                                          style: TextStyle(
                                            color: widget.textColor
                                                .withOpacity(0.72),
                                            fontSize: 15,
                                          ),
                                        ),
                                        const SizedBox(width: 6),
                                        Icon(
                                          m.reasoningCollapsed
                                              ? Icons.expand_more
                                              : Icons.expand_less,
                                          size: 18,
                                          color: widget.textColor
                                              .withOpacity(0.55),
                                        ),
                                      ],
                                    ),
                                  ),
                                  if (!m.reasoningCollapsed) ...[
                                    const SizedBox(height: 8),
                                    Container(
                                      width: double.infinity,
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 10, vertical: 10),
                                      decoration: BoxDecoration(
                                        color: widget.textColor.withOpacity(
                                            widget.isDark ? 0.06 : 0.035),
                                        borderRadius: BorderRadius.circular(12),
                                      ),
                                      child: ConstrainedBox(
                                        constraints: const BoxConstraints(
                                            maxHeight: 140),
                                        child: SingleChildScrollView(
                                          reverse: true,
                                          child: Text(
                                            m.reasoning.trim(),
                                            style: TextStyle(
                                              color: widget.textColor
                                                  .withOpacity(0.78),
                                              height: 1.35,
                                              fontSize: 13,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                    const SizedBox(height: 10),
                                  ],
                                ],
                                Text(
                                  m.text.isEmpty &&
                                          _activeReplyIndex == i &&
                                          m.reasoning.trim().isEmpty
                                      ? '...'
                                      : m.text,
                                  style: TextStyle(
                                    color: widget.textColor,
                                    height: 1.35,
                                    fontSize: 15,
                                  ),
                                ),
                              ],
                            ),
                    ),
                  );
                },
              ),
            ),
            if (_messageState == _MessageState.thinking &&
                (_activeReplyIndex == null ||
                    (_activeReplyIndex! >= 0 &&
                        _activeReplyIndex! < _messages.length &&
                        _messages[_activeReplyIndex!].text.trim().isEmpty &&
                        _messages[_activeReplyIndex!]
                            .reasoning
                            .trim()
                            .isEmpty)))
              Align(
                alignment: Alignment.centerLeft,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8.0),
                  child: Text('思考中...',
                      style: TextStyle(
                          color: widget.textColor.withOpacity(0.6),
                          fontSize: 15)),
                ),
              ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                actionChip(
                  label: '新话题',
                  onTap: _messageState != _MessageState.idle
                      ? null
                      : _startNewTopic,
                ),
                actionChip(
                  label: '总结本章',
                  onTap: _messageState != _MessageState.idle
                      ? null
                      : () => _sendQuickAction(QAType.summary),
                ),
                actionChip(
                  label: '提取要点',
                  onTap: _messageState != _MessageState.idle
                      ? null
                      : () => _sendQuickAction(QAType.keyPoints),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: Focus(
                    onKeyEvent: (node, event) {
                      if (event is KeyDownEvent &&
                          event.logicalKey == LogicalKeyboardKey.enter &&
                          !ServicesBinding.instance.keyboard.logicalKeysPressed
                              .contains(LogicalKeyboardKey.shiftLeft) &&
                          !ServicesBinding.instance.keyboard.logicalKeysPressed
                              .contains(LogicalKeyboardKey.shiftRight)) {
                        if (_messageState == _MessageState.idle) {
                          _send();
                        } else {
                          _cancelActive();
                        }
                        return KeyEventResult.handled;
                      }
                      return KeyEventResult.ignored;
                    },
                    child: TextField(
                      controller: _inputCtl,
                      minLines: 1,
                      maxLines: 4,
                      textInputAction: TextInputAction.send,
                      style: const TextStyle(fontSize: 14),
                      decoration: InputDecoration(
                        isDense: true,
                        filled: true,
                        fillColor: Colors.white,
                        hintText: '输入你的问题…',
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 12),
                        border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12)),
                      ),
                      onSubmitted: (_) {
                        if (_messageState == _MessageState.idle) {
                          _send();
                        } else {
                          _cancelActive();
                        }
                      },
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                ElevatedButton(
                  onPressed: _messageState == _MessageState.idle
                      ? _send
                      : _cancelActive,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.techBlue,
                    foregroundColor: Colors.white,
                    elevation: 0,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 12),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  child:
                      Text(_messageState == _MessageState.idle ? '发送' : '取消'),
                ),
              ],
            ),
          ],
        ),
      ),
    );

    return Padding(
      padding:
          EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: panelContent,
    );
  }
}
