import 'dart:js_interop';
import 'dart:js_interop_unsafe';

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

class WebSpeechTtsWeb extends WebSpeechTts {
  int _activeSession = 0;

  JSObject? get _synth {
    final v = globalContext.getProperty('speechSynthesis'.toJS);
    return v is JSObject ? v : null;
  }

  @override
  bool get supported => _synth != null;

  @override
  Future<void> speak({
    required String text,
    required double rate,
    required int session,
    required void Function(int session) onDone,
    required void Function(int session, String message) onError,
  }) async {
    final synth = _synth;
    if (synth == null) {
      onError(session, '当前浏览器不支持本地朗读');
      return;
    }

    final ctor = globalContext.getProperty('SpeechSynthesisUtterance'.toJS);
    if (ctor is! JSFunction) {
      onError(session, '当前浏览器不支持本地朗读');
      return;
    }

    await stop();
    _activeSession = session;

    final u = ctor.callAsConstructor<JSObject>(text.toJS);
    u.setProperty('rate'.toJS, rate.clamp(0.1, 3.0).toJS);

    u.setProperty(
      'onend'.toJS,
      ((JSAny? _) {
        if (_activeSession != session) return;
        onDone(session);
      }).toJS,
    );
    u.setProperty(
      'onerror'.toJS,
      ((JSAny? _) {
        if (_activeSession != session) return;
        onError(session, '朗读失败');
      }).toJS,
    );

    try {
      try {
        synth.callMethod('resume'.toJS);
      } catch (_) {}
      synth.callMethodVarArgs('speak'.toJS, [u]);
    } catch (e) {
      onError(session, e.toString());
    }
  }

  @override
  Future<void> stop() async {
    final synth = _synth;
    if (synth == null) return;
    _activeSession++;
    try {
      synth.callMethod('cancel'.toJS);
    } catch (_) {}
  }
}

WebSpeechTts createWebSpeechTts() => WebSpeechTtsWeb();
