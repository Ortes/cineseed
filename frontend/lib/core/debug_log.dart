import 'package:flutter/foundation.dart';

/// Frontend verbose-mode logger. Enabled at startup either by `?debug=1` in the
/// URL or by the backend reporting `debugMode: true` from `GET /api/config`
/// (which mirrors the server's `CINESEED_DEBUG`). When off, [log] is a cheap
/// no-op.
///
/// Lines go to the browser console via [debugPrint] (which still prints in a
/// `--release` web build) with a `[cineseed][<category>]` prefix so they
/// interleave with the player's `[cineseed][HLS]` lines from the
/// `video_player_web_hls` fork. Categories used: `NET`, `PLAYER`, `ACTION`.
class DebugLog {
  static bool enabled = false;

  static void log(String category, String message) {
    if (!enabled) return;
    debugPrint('[cineseed][$category] $message');
  }
}
