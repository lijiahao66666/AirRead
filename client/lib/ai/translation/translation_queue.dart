import 'dart:async';
import 'dart:collection';

/// Simple FIFO task queue with bounded concurrency.
class TranslationTaskQueue {
  final int maxConcurrent;
  final Queue<_QueuedTask<dynamic>> _pending = Queue();
  int _active = 0;

  TranslationTaskQueue({required this.maxConcurrent})
      : assert(maxConcurrent >= 1);

  int get pendingCount => _pending.length;
  int get activeCount => _active;

  Future<T> submit<T>(Future<T> Function() task) {
    final completer = Completer<T>();
    _pending.add(_QueuedTask<T>(task: task, completer: completer));
    _drain();
    return completer.future;
  }

  void _drain() {
    while (_active < maxConcurrent && _pending.isNotEmpty) {
      final next = _pending.removeFirst();
      _active++;
      () async {
        try {
          final result = await next.task();
          next.completer.complete(result);
        } catch (e, st) {
          next.completer.completeError(e, st);
        } finally {
          _active--;
          // Continue draining.
          scheduleMicrotask(_drain);
        }
      }();
    }
  }
}

class _QueuedTask<T> {
  final Future<T> Function() task;
  final Completer<T> completer;

  _QueuedTask({required this.task, required this.completer});
}
