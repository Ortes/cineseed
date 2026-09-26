import 'dart:io';

/// Tiny verbose-mode logger. [d] is enabled once at startup by the app (e.g. a
/// debug flag); when off it's a cheap no-op so call sites can stay
/// unconditional. [w] always prints — use it for failures that would otherwise
/// go unnoticed in production, where debug mode is off. Lines go to stderr as
/// `[<prefix>][<tag>] …`, easy to grep in container logs; the app sets [prefix].
class Log {
  static bool enabled = false;
  static String prefix = 'hls_remux';

  static void d(String tag, String msg) {
    if (!enabled) return;
    stderr.writeln('[$prefix][$tag] $msg');
  }

  static void w(String tag, String msg) {
    stderr.writeln('[$prefix][$tag] $msg');
  }
}
