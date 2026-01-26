import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'ai/tencentcloud/embedded_public_hunyuan_credentials.dart';
import 'ai/tencentcloud/tencent_credentials.dart';
import 'core/theme/app_theme.dart';
import 'presentation/pages/bookshelf/bookshelf_page.dart';
import 'presentation/providers/ai_model_provider.dart';
import 'presentation/providers/books_provider.dart';
import 'presentation/providers/translation_provider.dart';
import 'presentation/providers/qa_stream_provider.dart';

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
      home: const BookshelfPage(),
    );
  }
}
