import 'dart:async';

import 'tts_ws_impl.dart' if (dart.library.js_interop) 'tts_ws_impl_web.dart';

abstract class TtsWebSocket {
  Stream<Object> get stream;
  void add(String text);
  Future<void> close();
}

Future<TtsWebSocket> connectTtsWebSocket(String url) {
  return connectTtsWebSocketImpl(url);
}

