import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'remote_config_service.dart';

/// Android 应用内更新服务
///
/// 通过 [RemoteConfigService] 获取最新版本信息，
/// 下载 APK 并通过 Intent 调起系统安装器。
class AppUpdateService {
  AppUpdateService._();

  /// 检查更新并弹窗提示（应在首页 initState 后调用）
  static Future<void> checkAndPrompt(BuildContext context) async {
    if (kIsWeb || !Platform.isAndroid) return;
    if (!RemoteConfigService.hasUpdate) return;

    final force = RemoteConfigService.mustForceUpdate;
    final message = RemoteConfigService.updateMessage.isNotEmpty
        ? RemoteConfigService.updateMessage
        : '发现新版本 ${RemoteConfigService.latestVersion}，建议更新以获得更好的体验。';

    if (!context.mounted) return;

    await showDialog<void>(
      context: context,
      barrierDismissible: !force,
      builder: (ctx) => _UpdateDialog(
        message: message,
        force: force,
        downloadUrl: RemoteConfigService.updateUrl,
      ),
    );
  }
}

class _UpdateDialog extends StatefulWidget {
  final String message;
  final bool force;
  final String downloadUrl;

  const _UpdateDialog({
    required this.message,
    required this.force,
    required this.downloadUrl,
  });

  @override
  State<_UpdateDialog> createState() => _UpdateDialogState();
}

class _UpdateDialogState extends State<_UpdateDialog> {
  bool _downloading = false;
  double _progress = 0;
  String? _error;

  Future<void> _startDownload() async {
    if (_downloading) return;
    setState(() {
      _downloading = true;
      _progress = 0;
      _error = null;
    });

    try {
      final url = widget.downloadUrl.trim();
      if (url.isEmpty) {
        setState(() => _error = '更新地址未配置');
        return;
      }

      // 使用 url_launcher 打开浏览器下载（最简单可靠的方式）
      // 避免 FileProvider / REQUEST_INSTALL_PACKAGES 等复杂权限问题
      final uri = Uri.parse(url);
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
        // 用户会在浏览器/下载管理器中完成下载和安装
        if (mounted) Navigator.of(context).pop();
      } else {
        setState(() => _error = '无法打开下载链接');
      }
    } catch (e) {
      debugPrint('[AppUpdate] download error: $e');
      if (mounted) setState(() => _error = '下载失败：$e');
    } finally {
      if (mounted) setState(() => _downloading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: const Text('发现新版本'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(widget.message),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(_error!, style: const TextStyle(color: Colors.redAccent, fontSize: 13)),
          ],
        ],
      ),
      actions: [
        if (!widget.force)
          TextButton(
            onPressed: _downloading ? null : () => Navigator.of(context).pop(),
            child: const Text('稍后再说'),
          ),
        TextButton(
          onPressed: _downloading ? null : _startDownload,
          child: Text(_downloading ? '正在打开…' : '立即更新'),
        ),
      ],
    );
  }
}
