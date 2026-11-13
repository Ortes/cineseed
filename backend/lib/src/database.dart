import 'dart:convert';

import 'package:cineseed_shared/cineseed_shared.dart';
import 'package:sqlite3/sqlite3.dart';

/// The backend's own data, in one SQLite file: what the suggestions need to
/// survive a restart, and who added, saved or watched what. A schema change bumps [_version] and adds a step
/// to [_migrate].
class CineseedDb {
  /// The database at [path], created if missing.
  CineseedDb.open(String path) : _db = sqlite3.open(path) {
    _migrate();
  }

  /// A database that lives as long as the process: nothing survives a restart.
  CineseedDb.memory() : _db = sqlite3.openInMemory() {
    _migrate();
  }

  final Database _db;

  static const _version = 2;

  void _migrate() {
    if (_db.userVersion >= _version) return;
    _transaction(() {
      if (_db.userVersion < 1) {
        _db.execute('''
          -- C411 poster (one per film) → TMDB id; NULL when nobody knows it.
          CREATE TABLE film_ids (poster TEXT PRIMARY KEY, tmdb_id INTEGER);
          -- TMDB id → AlloCiné id, from Wikidata.
          CREATE TABLE allocine_ids (
            tmdb_id INTEGER PRIMARY KEY,
            allocine_id TEXT NOT NULL
          );
          -- The current suggestions, one FilmSuggestion (JSON) per film.
          CREATE TABLE suggestions (tmdb_id INTEGER PRIMARY KEY, film TEXT NOT NULL);
          CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
        ''');
      }
      if (_db.userVersion < 2) {
        _db.execute('''
          -- One row per visitor action on a film: added / downloaded / watched.
          CREATE TABLE activity (
            at TEXT NOT NULL, -- ISO 8601, UTC
            who TEXT NOT NULL,
            ip TEXT NOT NULL,
            action TEXT NOT NULL,
            hash TEXT NOT NULL,
            title TEXT NOT NULL
          );
        ''');
      }
      _db.userVersion = _version;
    });
  }

  void _transaction(void Function() body) {
    _db.execute('BEGIN');
    try {
      body();
      _db.execute('COMMIT');
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  Map<String, int?> filmIds() => {
    for (final r in _db.select('SELECT poster, tmdb_id FROM film_ids'))
      r['poster'] as String: r['tmdb_id'] as int?,
  };

  /// Replaces every film id with [ids].
  void setFilmIds(Map<String, int?> ids) => _transaction(() {
    _db.execute('DELETE FROM film_ids');
    final insert = _db.prepare('INSERT INTO film_ids VALUES (?, ?)');
    for (final MapEntry(:key, :value) in ids.entries) {
      insert.execute([key, value]);
    }
    insert.close();
  });

  Map<int, String> allocineIds() => {
    for (final r in _db.select('SELECT tmdb_id, allocine_id FROM allocine_ids'))
      r['tmdb_id'] as int: r['allocine_id'] as String,
  };

  void addAllocineIds(Map<int, String> ids) => _transaction(() {
    final insert = _db.prepare(
      'INSERT OR REPLACE INTO allocine_ids VALUES (?, ?)',
    );
    for (final MapEntry(:key, :value) in ids.entries) {
      insert.execute([key, value]);
    }
    insert.close();
  });

  /// The last suggestions saved, and when they were built; null if none.
  ({List<FilmSuggestion> films, DateTime builtAt})? suggestions() {
    final built = _db.select("SELECT value FROM meta WHERE key = 'built_at'");
    if (built.isEmpty) return null;
    return (
      films: [
        for (final r in _db.select('SELECT film FROM suggestions'))
          FilmSuggestion.fromJson(
            jsonDecode(r['film'] as String) as Map<String, dynamic>,
          ),
      ],
      builtAt: DateTime.parse(built.single['value'] as String),
    );
  }

  void setSuggestions(List<FilmSuggestion> films, DateTime builtAt) =>
      _transaction(() {
        _db.execute('DELETE FROM suggestions');
        final insert = _db.prepare('INSERT INTO suggestions VALUES (?, ?)');
        for (final f in films) {
          insert.execute([f.movie.id, jsonEncode(f.toJson())]);
        }
        insert.close();
        _db.execute("INSERT OR REPLACE INTO meta VALUES ('built_at', ?)", [
          builtAt.toIso8601String(),
        ]);
      });

  /// Records [action] on [hash] by [who], unless they already did it in the
  /// last 6 h: the player polls `/api/stream` for as long as it waits. True
  /// when recorded.
  bool logActivity({
    required String who,
    required String ip,
    required String action,
    required String hash,
    required String title,
    DateTime? at,
  }) {
    final now = (at ?? DateTime.now()).toUtc();
    final since = now.subtract(const Duration(hours: 6)).toIso8601String();
    final recent = _db.select(
      'SELECT 1 FROM activity WHERE who = ? AND action = ? AND hash = ? '
      'AND at > ? LIMIT 1',
      [who, action, hash, since],
    );
    if (recent.isNotEmpty) return false;
    _db.execute('INSERT INTO activity VALUES (?, ?, ?, ?, ?, ?)', [
      now.toIso8601String(),
      who,
      ip,
      action,
      hash,
      title,
    ]);
    return true;
  }

  /// The [limit] latest actions, newest first.
  List<Map<String, String>> activity({int limit = 500}) => [
    for (final r in _db.select(
      'SELECT at, who, ip, action, title FROM activity '
      'ORDER BY at DESC LIMIT ?',
      [limit],
    ))
      {for (final k in r.keys) k: r[k] as String},
  ];

  void close() => _db.close();
}
