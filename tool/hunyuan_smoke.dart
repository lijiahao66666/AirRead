import 'package:airread/ai/hunyuan/hunyuan_text_client.dart';
import 'package:airread/ai/hunyuan/hunyuan_translation_engine.dart';
import 'package:airread/ai/tencentcloud/embedded_public_hunyuan_credentials.dart';

Future<void> main() async {
  final creds = getEmbeddedPublicHunyuanCredentials();
  if (!creds.isUsable) {
    print('embedded public credentials not usable');
    return;
  }
  print('secretId startsWith AKID: ${creds.secretId.startsWith('AKID')}');
  print('secretId length: ${creds.secretId.length}');
  print('secretKey length: ${creds.secretKey.length}');

  final chat = HunyuanTextClient(credentials: creds);
  final out = await chat.chatOnce(userText: '你好，请回复一句“连接成功”。');
  final chatText = out.trim().replaceAll(RegExp(r'\s+'), ' ');
  print('chat ok: ${out.trim().isNotEmpty}');
  print(
      'chat preview: ${chatText.substring(0, chatText.length > 60 ? 60 : chatText.length)}');

  final tr = HunyuanTranslationEngine(credentials: creds);
  final t = await tr.translate(
    text: 'Hello world.',
    sourceLang: 'en',
    targetLang: 'zh',
    contextSources: const [],
    glossaryPlaceholders: const {},
  );
  final trText = t.trim().replaceAll(RegExp(r'\s+'), ' ');
  print('translation ok: ${t.trim().isNotEmpty}');
  print(
      'translation preview: ${trText.substring(0, trText.length > 60 ? 60 : trText.length)}');
}
