import 'dart:async';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:uuid/uuid.dart';

import '../../ai/licensing/license_codec.dart';
import '../../ai/tencentcloud/tencent_api_client.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_tokens.dart';
import '../providers/ai_model_provider.dart';

class PointsWallet extends StatefulWidget {
  final bool isDark;
  final Color textColor;
  final Color cardBg;
  final String? hintText;

  const PointsWallet({
    super.key,
    required this.isDark,
    required this.textColor,
    required this.cardBg,
    this.hintText,
  });

  @override
  State<PointsWallet> createState() => _PointsWalletState();
}

class _PurchaseSku {
  final String label;
  final String url;
  const _PurchaseSku(this.label, this.url);
}

class _PointsWalletState extends State<PointsWallet> {
  static const String _scfUrl =
      String.fromEnvironment('AIRREAD_TENCENT_SCF_URL', defaultValue: '');
  static const String _scfToken =
      String.fromEnvironment('AIRREAD_TENCENT_SCF_TOKEN', defaultValue: '');
  static const Duration _redeemTimeout = Duration(seconds: 20);
  static const String _kRedeemDeviceFingerprint = 'redeem_device_fingerprint_v1';
  static const String _kRedeemedPayloadV2 = 'redeemed_code_payload_v2';
  static const String _kRedeemedCodeHashes = 'redeemed_code_hashes';

  static const List<_PurchaseSku> _purchaseSkus = <_PurchaseSku>[
    _PurchaseSku('5万积分', 'https://pay.ldxp.cn/item/ajnlvp'),
    _PurchaseSku('10万积分', 'https://pay.ldxp.cn/item/b5p0id'),
    _PurchaseSku('20万积分', 'https://pay.ldxp.cn/item/f2ezmi'),
    _PurchaseSku('50万积分', 'https://pay.ldxp.cn/item/pwaixm'),
    _PurchaseSku('100万积分', 'https://pay.ldxp.cn/item/4dp4xf'),
  ];

  static final Cipher _redeemCipher = AesGcm.with256bits();

  bool _redeemBusy = false;

  String _fingerprintHash(String fingerprint) {
    return sha256.convert(utf8.encode(fingerprint)).toString();
  }

  SecretKey _deriveRedeemKey(String fingerprint) {
    final bytes = sha256.convert(utf8.encode('airread|$fingerprint')).bytes;
    return SecretKey(bytes);
  }

  Future<String?> _encryptRedeemPayload(String payload, String fingerprint) async {
    try {
      final box = await _redeemCipher.encrypt(
        utf8.encode(payload),
        secretKey: _deriveRedeemKey(fingerprint),
      );
      final cipherRaw = base64UrlEncode(box.cipherText);
      final nonceRaw = base64UrlEncode(box.nonce);
      final macRaw = base64UrlEncode(box.mac.bytes);
      return '$cipherRaw.$nonceRaw.$macRaw';
    } catch (_) {
      return null;
    }
  }

  Future<String?> _decryptRedeemPayload(String payload, String fingerprint) async {
    try {
      final parts = payload.split('.');
      if (parts.length != 3) return null;
      final cipherRaw = parts[0];
      final nonceRaw = parts[1];
      final macRaw = parts[2];
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
      throw const LicenseException('兑换服务未配置，请检查网络连接或联系客服');
    }
    return Uri.parse(raw);
  }

  Uri _fallbackRedeemScfUri(Uri primary) {
    final host = primary.host.trim();
    if (host.endsWith('.apigw.tencentcs.com')) {
      final nextHost =
          host.replaceFirst('.apigw.tencentcs.com', '.apigateway.myqcloud.com');
      return primary.replace(host: nextHost);
    }
    return primary;
  }

  bool _looksLikeDnsFailure(Object e) {
    final s = e.toString();
    return s.contains('Failed host lookup') ||
        s.contains('nodename nor servname provided') ||
        s.contains('No address associated with hostname');
  }

  Future<http.Response> _postRedeem(
    Uri uri, {
    required Map<String, String> headers,
    required String body,
  }) async {
    return http
        .post(uri, headers: headers, body: body)
        .timeout(_redeemTimeout);
  }

  Future<String?> _redeemOnCloud({
    required String licenseCode,
    required String deviceId,
  }) async {
    final uri = _resolveRedeemScfUri();
    final headers = <String, String>{
      'Content-Type': 'application/json; charset=utf-8',
    };
    final prefs = await SharedPreferences.getInstance();
    final token = _scfToken.trim().isNotEmpty
        ? _scfToken.trim()
        : (prefs.getString('tencent_scf_jwt') ?? '').trim();
    if (token.isNotEmpty) {
      headers['X-Airread-Token'] = token;
    }
    final body = jsonEncode(<String, dynamic>{
      'license_code': licenseCode,
      'device_id': deviceId,
    });
    late http.Response resp;
    try {
      resp = await _postRedeem(uri, headers: headers, body: body);
    } on TimeoutException {
      throw const LicenseException('网络超时，请稍后重试');
    } catch (e) {
      final fallback = _fallbackRedeemScfUri(uri);
      if (fallback != uri && _looksLikeDnsFailure(e)) {
        try {
          resp = await _postRedeem(fallback, headers: headers, body: body);
        } on TimeoutException {
          throw const LicenseException('网络超时，请稍后重试');
        } catch (e2) {
          throw LicenseException(_looksLikeDnsFailure(e2)
              ? '兑换服务域名解析失败，请切换网络后重试'
              : '兑换服务连接失败：${e2.toString()}');
        }
      } else {
        throw LicenseException(_looksLikeDnsFailure(e)
            ? '兑换服务域名解析失败，请切换网络后重试'
            : '兑换服务连接失败：${e.toString()}');
      }
    }
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

    try {
      final decoded = jsonDecode(utf8.decode(resp.bodyBytes));
      if (decoded is Map) {
        return decoded['token']?.toString();
      }
    } catch (_) {}
    return null;
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

  Future<void> _openExternalUrl(String url) async {
    final uri = Uri.parse(url);
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  Future<void> _showPurchaseDialog({List<_PurchaseSku>? skus}) async {
    final dialogBg = widget.isDark ? const Color(0xFF262626) : Colors.white;
    final items = skus ?? _purchaseSkus;
    await showDialog<void>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          backgroundColor: dialogBg,
          surfaceTintColor: Colors.transparent,
          title:
              Text('购买积分', style: TextStyle(color: widget.textColor, fontSize: 14)),
          content: SizedBox(
            width: 320,
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final sku in items)
                  ListTile(
                    dense: true,
                    textColor: widget.textColor,
                    iconColor: widget.textColor.withOpacityCompat(0.75),
                    title: Text(
                      sku.label,
                      style: const TextStyle(fontSize: 13),
                    ),
                    trailing: const Icon(Icons.open_in_new_rounded, size: 18),
                    onTap: () async {
                      Navigator.of(ctx).pop();
                      await _openExternalUrl(sku.url);
                    },
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              style: TextButton.styleFrom(
                foregroundColor: widget.textColor.withOpacityCompat(0.75),
              ),
              child: const Text('关闭'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _showRedeemDialog(AiModelProvider aiModel) async {
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
              if (mounted) setState(() => _redeemBusy = true);

              try {
                final payload = await LicenseCodec.verifyAndParse(trimmed);
                final token = await _redeemOnCloud(
                  licenseCode: trimmed,
                  deviceId: fpHash,
                );
                if (token != null && token.isNotEmpty) {
                  final prefs = await SharedPreferences.getInstance();
                  await prefs.setString('tencent_scf_jwt', token);
                  TencentApiClient.setToken(token);
                }
                if (payload.points > 0) {
                  await aiModel.addPoints(payload.points);
                }

                final nowMs2 = DateTime.now().millisecondsSinceEpoch;
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
                setDialogState(() => dialogHint = e.toString());
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
                        filled: true,
                        fillColor: fieldBg,
                        isDense: true,
                        contentPadding:
                            const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide.none,
                        ),
                      ),
                      onSubmitted: (_) async {
                        final ok = await submit();
                        if (!ok) return;
                        if (dialogContext.mounted) {
                          Navigator.of(dialogContext).pop();
                        }
                      },
                    ),
                    if (hint.isNotEmpty) ...[
                      const SizedBox(height: 10),
                      Text(
                        hint,
                        style: const TextStyle(
                          color: Colors.red,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: dialogBusy ? null : () => Navigator.of(dialogContext).pop(),
                  child: Text('取消', style: TextStyle(color: widget.textColor)),
                ),
                TextButton(
                  onPressed: dialogBusy
                      ? null
                      : () async {
                          final ok = await submit();
                          if (!ok) return;
                          if (dialogContext.mounted) {
                            Navigator.of(dialogContext).pop();
                          }
                        },
                  child: Text('兑换', style: TextStyle(color: widget.textColor)),
                ),
              ],
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final aiModel = context.watch<AiModelProvider>();
    final hint = (widget.hintText ?? '').trim();
    return Container(
      decoration: BoxDecoration(
        color: widget.cardBg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: widget.textColor.withOpacityCompat(0.08),
          width: AppTokens.stroke,
        ),
      ),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '剩余积分：${aiModel.pointsBalance}',
                  style: TextStyle(
                    color: widget.textColor.withOpacityCompat(0.9),
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              TextButton(
                onPressed: () => _showPurchaseDialog(),
                style: TextButton.styleFrom(
                  padding: EdgeInsets.zero,
                  minimumSize: const Size(0, 0),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  foregroundColor: AppColors.techBlue,
                ),
                child: const Text('购买', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
              ),
              const SizedBox(width: 10),
              TextButton(
                onPressed: _redeemBusy ? null : () => _showRedeemDialog(aiModel),
                style: TextButton.styleFrom(
                  padding: EdgeInsets.zero,
                  minimumSize: const Size(0, 0),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  foregroundColor: AppColors.techBlue,
                ),
                child: Text(
                  _redeemBusy ? '兑换中' : '兑换',
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
                ),
              ),
            ],
          ),
          if (hint.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              hint,
              style: TextStyle(
                color: widget.isDark ? const Color(0xFFE6A23C) : const Color(0xFFF57C00),
                fontSize: 12,
                height: 1.35,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
