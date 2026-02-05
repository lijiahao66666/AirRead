class WebSpeechTts {
  const WebSpeechTts();

  bool get supported => false;

  Future<void> speak({
    required String text,
    required double rate,
    required int session,
    required void Function(int session) onDone,
    required void Function(int session, String message) onError,
  }) async {
    throw UnsupportedError('WebSpeechTts is only available on web.');
  }

  Future<void> stop() async {}
}

WebSpeechTts createWebSpeechTts() => const WebSpeechTts();
