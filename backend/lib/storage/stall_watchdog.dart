import 'dart:async';

/// Runs [run] and gives up on it once it has reported no progress for
/// [stallTimeout], throwing a [TimeoutException] naming [what].
///
/// [run] is handed the progress sink it must call as bytes move. Every call
/// rearms the watchdog, so a slow-but-moving transfer is never cut off — only a
/// silent one is. Pick [stallTimeout] against the longest legitimate gap
/// *between* progress reports, not against the total transfer time.
///
/// This exists for transfers that can neither be cancelled nor time out on
/// their own, where the future [run] returns may simply never complete. Failing
/// lets the caller release whatever in-flight state it holds and start over;
/// the abandoned work keeps whatever resources it holds until the process ends.
/// Progress arriving after we've given up is dropped, so an abandoned transfer
/// that wakes up later can't drive [onProgress] backwards behind its successor.
Future<void> awaitProgress({
  required Duration stallTimeout,
  required String what,
  required Future<void> Function(void Function(int) progress) run,
  void Function(int)? onProgress,
}) async {
  final stalled = Completer<void>();
  Timer? watchdog;
  void rearm() {
    watchdog?.cancel();
    watchdog = Timer(stallTimeout, () {
      if (stalled.isCompleted) return;
      stalled.completeError(
          TimeoutException('$what stalled', stallTimeout));
    });
  }

  rearm();
  final work = run((sent) {
    if (stalled.isCompleted) return;
    rearm();
    onProgress?.call(sent);
  });
  try {
    // Whichever settles first wins. Future.any leaves an error handler on the
    // loser, so an abandoned transfer that fails later stays handled instead of
    // surfacing as an unhandled async error.
    await Future.any([work, stalled.future]);
  } finally {
    watchdog?.cancel();
  }
}
