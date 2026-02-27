import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:http/http.dart' as http;
import 'ai/tencentcloud/embedded_public_hunyuan_credentials.dart';
import 'ai/tencentcloud/tencent_credentials.dart';
import 'ai/config/auth_service.dart';
import 'ai/config/checkin_service.dart';
import 'ai/config/remote_config_service.dart';
import 'ai/tencentcloud/tencent_api_client.dart';
import 'core/theme/app_theme.dart';
import 'presentation/pages/bookshelf/bookshelf_page.dart';
import 'presentation/providers/ai_model_provider.dart';
import 'presentation/providers/books_provider.dart';
import 'presentation/providers/read_aloud_provider.dart';
import 'presentation/providers/translation_provider.dart';
import 'presentation/providers/qa_stream_provider.dart';
import 'presentation/providers/illustration_provider.dart';

import 'package:flutter/services.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Set global system UI mode to edge-to-edge for modern Android experience
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    systemNavigationBarColor: Colors.transparent,
    systemNavigationBarDividerColor: Colors.transparent,
    statusBarColor: Colors.transparent,
    systemNavigationBarContrastEnforced:
        false, // Prevent system from enforcing contrast with scrim
    statusBarIconBrightness: Brightness.dark,
    systemNavigationBarIconBrightness: Brightness.dark,
  ));

  if (!kIsWeb && (Platform.isWindows || Platform.isLinux)) {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  }

  final prefs = await SharedPreferences.getInstance();
  bool enabled = prefs.getBool('user_tencent_keys_enabled') ?? false;
  String secretId = (prefs.getString('user_tencent_secret_id') ?? '').trim();
  String secretKey = (prefs.getString('user_tencent_secret_key') ?? '').trim();

  if (secretId.isEmpty && secretKey.isEmpty) {
    final legacyId = (prefs.getString('dev_tencent_secret_id') ?? '').trim();
    final legacyKey = (prefs.getString('dev_tencent_secret_key') ?? '').trim();
    if (legacyId.isNotEmpty && legacyKey.isNotEmpty) {
      secretId = legacyId;
      secretKey = legacyKey;
      await prefs.setString('user_tencent_secret_id', secretId);
      await prefs.setString('user_tencent_secret_key', secretKey);
      await prefs.setBool('user_tencent_keys_enabled', true);
      enabled = true;
    }
  }

  if (enabled && secretId.isNotEmpty && secretKey.isNotEmpty) {
    setTencentCredentialsOverride(
      TencentCredentials(appId: '', secretId: secretId, secretKey: secretKey),
    );
  }
  setUserTencentKeysEnabledOverride(enabled);

  // 生成/加载设备唯一标识（用于积分计费）
  await TencentApiClient.initDeviceId();

  // 恢复登录态（从本地缓存读取 token，验证有效性）
  await AuthService.init();

  // 拉取远程配置（签到积分、广告开关、应用更新等）
  await RemoteConfigService.fetch();

  // 从服务端同步签到状态（防重装后本地缓存丢失导致按钮可重复点击）
  unawaited(CheckinService.syncStatusFromServer());

  // 提前触发网络权限请求（iOS）- 在后台执行，不阻塞启动
  if (!kIsWeb && Platform.isIOS) {
    Future.delayed(const Duration(seconds: 2), () {
      unawaited(_requestNetworkPermission());
    });
  }

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => BooksProvider()),
        ChangeNotifierProvider(create: (_) => AiModelProvider()),
        ChangeNotifierProvider(create: (_) => QaStreamProvider()),
        ChangeNotifierProxyProvider<AiModelProvider, TranslationProvider>(
          create: (_) => TranslationProvider(),
          update: (_, aiModel, provider) {
            final p = provider ?? TranslationProvider(aiModel: aiModel);
            p.updateAiModel(aiModel);
            return p;
          },
        ),
        ChangeNotifierProvider(create: (_) => IllustrationProvider()),
        ChangeNotifierProxyProvider<TranslationProvider, ReadAloudProvider>(
          create: (_) => ReadAloudProvider(),
          update: (_, tp, provider) {
            final p = provider ?? ReadAloudProvider();
            p.updateTranslationProvider(tp);
            return p;
          },
        ),
      ],
      child: const AirReadApp(),
    ),
  );
}

class AirReadApp extends StatelessWidget {
  const AirReadApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '灵阅',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.lightTheme,
      darkTheme: AppTheme.darkTheme,
      themeMode: ThemeMode.system,
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: const [
        Locale('zh', 'CN'),
        Locale('en', 'US'),
      ],
      home: const BookshelfPage(),
    );
  }
}

/// 请求网络权限（iOS）
Future<void> _requestNetworkPermission() async {
  try {
    // 发送一个简单的网络请求来触发权限弹窗
    await http
        .get(Uri.parse('https://www.baidu.com'))
        .timeout(const Duration(seconds: 5));
  } catch (e) {
    // 忽略错误，只需要触发权限请求
  }
}
