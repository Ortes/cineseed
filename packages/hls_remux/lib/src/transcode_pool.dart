import 'dart:async';
import 'dart:collection';

/// Caps the number of concurrent ffmpeg processes. On a small server (think
/// 1 vCPU / 1 GB RAM / no swap) unbounded spawning would OOM or thrash.
class TranscodePool {
  final int maxConcurrent;
  int _active = 0;
  final Queue<Completer<void>> _waiters = Queue();

  TranscodePool(this.maxConcurrent);

  Future<T> run<T>(Future<T> Function() task) async {
    await _acquire();
    try {
      return await task();
    } finally {
      _release();
    }
  }

  Future<void> _acquire() {
    if (_active < maxConcurrent) {
      _active++;
      return Future.value();
    }
    final c = Completer<void>();
    _waiters.add(c);
    return c.future;
  }

  void _release() {
    if (_waiters.isNotEmpty) {
      _waiters.removeFirst().complete();
    } else {
      _active--;
    }
  }
}
