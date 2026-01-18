import 'dart:io';

import 'package:airread/ai/hunyuan/hunyuan_text_client.dart';
import 'package:airread/ai/hunyuan/hunyuan_translation_engine.dart';
import 'package:airread/ai/tencentcloud/embedded_public_hunyuan_credentials.dart';

Future<void> main() async {
  final creds = getEmbeddedPublicHunyuanCredentials();
  if (!creds.isUsable) {
    stdout.writeln('embedded public credentials not usable');
    return;
  }
  stdout.writeln(
      'secretId startsWith AKID: ${creds.secretId.startsWith('AKID')}');

  final chat = HunyuanTextClient(credentials: creds);
  final chatBuffer = StringBuffer();
  await for (final chunk in chat.chatStream(userText: '你好，请回复一句“连接成功”。')) {
    chatBuffer.write(chunk.content);
    if (chunk.isComplete) break;
  }
  final out = chatBuffer.toString();
  final chatText = out.trim().replaceAll(RegExp(r'\s+'), ' ');
  stdout.writeln('chat ok: ${out.trim().isNotEmpty}');
  stdout.writeln(
      'chat preview: ${chatText.substring(0, chatText.length > 60 ? 60 : chatText.length)}');

  final tr = HunyuanTranslationEngine(credentials: creds);
  final t = await tr.translate(
    text: 'Hello world.',
    sourceLang: 'en',
    targetLang: 'zh',
    contextSources: const [],
  );
  final trText = t.trim().replaceAll(RegExp(r'\s+'), ' ');
  stdout.writeln('translation ok: ${t.trim().isNotEmpty}');
  stdout.writeln(
      'translation preview: ${trText.substring(0, trText.length > 60 ? 60 : trText.length)}');
}
