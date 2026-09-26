import 'dart:io';

/// Tiny verbose-mode logger. [d] is enabled once at startup from `Config.debug`
/// (`CINESEED_DEBUG=true`); when off it's a cheap no-op so call sites can stay
/// unconditional. [w] always prints — use it for failures that would otherwise
/// go unnoticed in production, where debug mode is off. Lines go to stderr with
/// a `[cineseed][<tag>]` prefix so they're easy to grep in `docker compose logs`.
class Log {
  static bool enabled = false;

  static void d(String tag, String msg) {
    if (!enabled) return;
    stderr.writeln('[cineseed][$tag] $msg');
  }

  static void w(String tag, String msg) {
    stderr.writeln('[cineseed][$tag] $msg');
  }
}
