import 'dart:async';
import 'dart:io';

import 'tts_ws.dart';

class _IoTtsWebSocket implements TtsWebSocket {
  final WebSocket _ws;

  _IoTtsWebSocket(this._ws);

  @override
  Stream<Object> get stream => _ws.cast<Object>();

  @override
  void add(String text) {
    _ws.add(text);
  }

  @override
  Future<void> close() => _ws.close();
}

Future<TtsWebSocket> connectTtsWebSocketImpl(String url) async {
  final ws = await WebSocket.connect(url);
  return _IoTtsWebSocket(ws);
}
