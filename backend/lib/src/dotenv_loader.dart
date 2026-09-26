import 'dart:io';

/// Reads a `.env` file (KEY=VALUE per line, `#` comments, optional quotes) and
/// returns the merged env: real process env wins, file values fill the rest.
/// Walks up from CWD looking for `.env` so the backend can be launched from
/// either the repo root or `backend/`. Silently returns the unchanged process
/// env if no file is found.
Map<String, String> loadDotenv([String name = '.env']) {
  final base = Map<String, String>.from(Platform.environment);
  var dir = Directory.current;
  File? f;
  for (var i = 0; i < 4; i++) {
    final candidate = File('${dir.path}/$name');
    if (candidate.existsSync()) {
      f = candidate;
      break;
    }
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  if (f == null) return base;

  for (final raw in f.readAsLinesSync()) {
    final line = raw.trim();
    if (line.isEmpty || line.startsWith('#')) continue;
    final eq = line.indexOf('=');
    if (eq <= 0) continue;
    final key = line.substring(0, eq).trim();
    var value = line.substring(eq + 1).trim();
    if (value.length >= 2 &&
        ((value.startsWith('"') && value.endsWith('"')) ||
            (value.startsWith("'") && value.endsWith("'")))) {
      value = value.substring(1, value.length - 1);
    }
    base.putIfAbsent(key, () => value);
  }
  return base;
}
