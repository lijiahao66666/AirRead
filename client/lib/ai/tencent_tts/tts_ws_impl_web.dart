import 'package:web_socket_channel/html.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'tts_ws.dart';

class _WebTtsWebSocket implements TtsWebSocket {
  final WebSocketChannel _channel;

  _WebTtsWebSocket(this._channel);

  @override
  Stream<Object> get stream => _channel.stream.cast<Object>();

  @override
  void add(String text) {
    _channel.sink.add(text);
  }

  @override
  Future<void> close() async {
    await _channel.sink.close();
  }
}

Future<TtsWebSocket> connectTtsWebSocketImpl(String url) async {
  final channel = HtmlWebSocketChannel.connect(
    Uri.parse(url),
    binaryType: BinaryType.list,
  );
  return _WebTtsWebSocket(channel);
}
