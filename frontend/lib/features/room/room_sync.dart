import 'dart:async';

import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:video_player/video_player.dart';

import '../../core/debug_log.dart';
import 'room_client.dart';

/// Keeps [vc] in step with [room], both ways.
///
/// Remote → local: every broadcast state is applied — play or pause to match
/// `shouldPlay`, and the position brought to the room's. A drift over 2 s is
/// seeked; under that, while playing, the playback rate is nudged (0.96 /
/// 1.04, inaudible) until it is back within a tenth of a second, because a
/// seek costs a fetch and a rebuffer and a nudge costs nothing.
///
/// Local → remote: the user's play, pause and seeks (a position jump over a
/// second between ticks) are sent to the room. Changes this hook made itself
/// are expected and not echoed back — the same event stream carries both, so
/// each applied change is remembered for a moment and matched when it shows up.
///
/// Readiness: an initialised, non-buffering player reports `ready`; buffering
/// for over 1.5 s reports `not ready`, which holds the room until it clears.
///
/// [initialPosition]: the position to send the room when this member joins as
/// its creator, so the room adopts where the host already was.
void useRoomSync({
  required VideoPlayerController? vc,
  required RoomClient? room,
  bool claimState = false,
}) {
  useEffect(() {
    if (vc == null || room == null) return null;

    // What this hook last did to the player, so the listener can tell the
    // user's actions from its own.
    bool? expectedPlaying;
    var expectedPlayingAt = DateTime(0);
    Duration? expectedPosition;
    var expectedAt = DateTime(0);
    void expect({bool? playing, Duration? position}) {
      if (playing != null) {
        expectedPlaying = playing;
        expectedPlayingAt = DateTime.now();
      }
      if (position != null) expectedPosition = position;
      expectedAt = DateTime.now();
    }

    bool recentlyExpected() =>
        DateTime.now().difference(expectedAt) < const Duration(seconds: 2);

    var seeking = false;
    var reportedReady = false;
    Timer? stallTimer;
    var lastPlaying = vc.value.isPlaying;
    var lastPosition = vc.value.position;
    var speed = 1.0;
    var claimed = !claimState;

    Future<void> setSpeed(double s) async {
      if (speed == s) return;
      speed = s;
      await vc.setPlaybackSpeed(s);
    }

    Future<void> seek(double seconds) async {
      final target = Duration(milliseconds: (seconds * 1000).round());
      expect(position: target);
      seeking = true;
      try {
        await vc.seekTo(target);
      } finally {
        seeking = false;
        lastPosition = vc.value.position;
      }
    }

    void reportReadiness() {
      final v = vc.value;
      final ready = v.isInitialized && !seeking && !v.isBuffering;
      if (ready) {
        stallTimer?.cancel();
        stallTimer = null;
        if (!reportedReady) {
          reportedReady = true;
          room.ready(true);
        }
      } else if (reportedReady && stallTimer == null) {
        stallTimer = Timer(const Duration(milliseconds: 1500), () {
          stallTimer = null;
          final v = vc.value;
          if (!v.isInitialized || seeking || v.isBuffering) {
            reportedReady = false;
            room.ready(false);
          }
        });
      }
    }

    /// Plays or pauses to match [s]. A pause is NOT issued while the player
    /// is buffering after a play: the browser would reject the still-pending
    /// play() with AbortError, which video_player treats as a fatal error
    /// (the controller resets to position 0, uninitialised, for good). The
    /// picture is not advancing while buffering anyway, so the pause waits
    /// until buffering ends — the listener calls back here then.
    Future<void> reconcilePlay(RoomState s) async {
      final v = vc.value;
      if (!v.isInitialized || s.shouldPlay == v.isPlaying) return;
      if (!s.shouldPlay && v.isBuffering) {
        DebugLog.log('ROOM', 'apply: pause deferred until buffering ends');
        return;
      }
      DebugLog.log('ROOM', 'apply: ${s.shouldPlay ? 'play' : 'pause'}');
      expect(playing: s.shouldPlay);
      if (s.shouldPlay) {
        await vc.play();
      } else {
        await vc.pause();
        await setSpeed(1.0);
      }
    }

    Future<void> apply(RoomState s) async {
      final v = vc.value;
      DebugLog.log(
        'ROOM',
        'apply: shouldPlay=${s.shouldPlay} target=${s.positionAt(room.serverNow()).toStringAsFixed(1)} '
            'local init=${v.isInitialized} err=${v.hasError} playing=${v.isPlaying} '
            'pos=${v.position.inMilliseconds / 1000.0} buf=${v.isBuffering} seeking=$seeking',
      );
      if (!v.isInitialized) return;
      final target = s.positionAt(room.serverNow());
      final drift = target - v.position.inMilliseconds / 1000.0;
      if (drift.abs() > 2) {
        DebugLog.log(
          'ROOM',
          'apply: seek ${drift.toStringAsFixed(1)}s → '
              '${target.toStringAsFixed(1)}s',
        );
        await seek(target);
      }
      await reconcilePlay(s);
      reportReadiness();
    }

    void onState() {
      final s = room.state.value;
      if (s == null) return;
      if (!claimed) {
        // The creator's player is the truth for a brand-new room.
        claimed = true;
        final v = vc.value;
        room.set(
          playing: v.isPlaying,
          position: v.position.inMilliseconds / 1000.0,
        );
        reportReadiness();
        return;
      }
      apply(s);
    }

    // Steady-state drift correction while playing.
    final tick = Timer.periodic(const Duration(seconds: 1), (_) {
      final s = room.state.value;
      final v = vc.value;
      if (s == null || !v.isInitialized) return;
      if (!s.shouldPlay || !v.isPlaying) {
        setSpeed(1.0);
        return;
      }
      final drift =
          s.positionAt(room.serverNow()) - v.position.inMilliseconds / 1000.0;
      if (drift.abs() > 2) {
        DebugLog.log('ROOM', 'drift ${drift.toStringAsFixed(2)}s → seek');
        seek(s.positionAt(room.serverNow()));
      } else if (drift.abs() > 0.3) {
        setSpeed(drift > 0 ? 1.04 : 0.96);
      } else if (drift.abs() < 0.1) {
        setSpeed(1.0);
      }
    });

    var lastInit = vc.value.isInitialized;
    var lastErr = vc.value.hasError;
    var lastBuffering = vc.value.isBuffering;
    void listener() {
      final v = vc.value;
      if (v.isBuffering != lastBuffering) {
        lastBuffering = v.isBuffering;
        final s = room.state.value;
        if (!v.isBuffering && s != null) reconcilePlay(s);
      }
      if (v.isInitialized != lastInit || v.hasError != lastErr) {
        lastInit = v.isInitialized;
        lastErr = v.hasError;
        DebugLog.log(
          'ROOM',
          'value: init=${v.isInitialized} err=${v.hasError} '
              '${v.errorDescription ?? ''} pos=${v.position.inMilliseconds / 1000.0}',
        );
      }
      if (!v.isInitialized) return;
      final seconds = v.position.inMilliseconds / 1000.0;
      if (v.isPlaying != lastPlaying) {
        lastPlaying = v.isPlaying;
        // Right after a play or pause this hook issued, every transition is
        // its own: the one it asked for, and the plugin's late "playing" for
        // a play() that a deferred pause overtook (it lands within
        // milliseconds). A user's click comes much later than 300 ms.
        final mine =
            expectedPlaying != null &&
            DateTime.now().difference(expectedPlayingAt) <
                const Duration(milliseconds: 300);
        if (mine) {
          DebugLog.log('ROOM', 'own ${v.isPlaying ? 'play' : 'pause'}');
        } else {
          DebugLog.log('ROOM', 'user ${v.isPlaying ? 'play' : 'pause'}');
          room.set(playing: v.isPlaying, position: seconds);
        }
      }
      final jump = (v.position - lastPosition).abs();
      if (jump > const Duration(seconds: 1) && !seeking) {
        final expected = expectedPosition;
        final mine =
            recentlyExpected() &&
            expected != null &&
            (v.position - expected).abs() < const Duration(milliseconds: 1500);
        if (mine) {
          expectedPosition = null;
        } else {
          DebugLog.log('ROOM', 'user seek → ${seconds.toStringAsFixed(1)}s');
          room.set(playing: v.isPlaying, position: seconds);
        }
      }
      lastPosition = v.position;
      reportReadiness();
    }

    vc.addListener(listener);
    room.state.addListener(onState);
    onState();
    reportReadiness();

    return () {
      tick.cancel();
      stallTimer?.cancel();
      vc.removeListener(listener);
      room.state.removeListener(onState);
      if (speed != 1.0 && vc.value.isInitialized) vc.setPlaybackSpeed(1.0);
    };
  }, [vc, room]);
}
