import 'dart:async';
import 'dart:convert';

import 'package:cineseed_shared/cineseed_shared.dart';
import 'package:hls_remux/hls_remux.dart' show Log;

import '../database.dart';
import 'c411_catalog.dart';

/// The suggestions cover at least the last 3 months: every film of the years
/// they span.
const recentMonths = 3;

/// TMDB's `/search/movie`, as [recentFilms] uses it.
typedef TmdbSearch =
    Future<List<({int id, String title, String originalTitle})>> Function(
      String query, {
      int? year,
    });

/// Every film C411 files under the years of the last [recentMonths] (this
/// year, and last year too from January to March), each with all its torrents
/// there. C411 can't sort by release date, only file films by year, so all of
/// them go through TMDB, which supplies the release dates to sort by.
///
/// C411's lists carry no TMDB id. A film's is searched on TMDB by the title
/// and year of its release names, and kept only if TMDB's title (French or
/// original) is that very title; otherwise C411 is asked (one request per
/// film). [tmdbIds], keyed by C411 poster (one per film), keeps the answers
/// from one build to the next, so only new films cost a lookup; null records
/// a film neither knows (about one in eight), so it isn't asked again.
Future<List<FilmSuggestion>> recentFilms({
  required C411Catalog catalog,
  required TmdbSearch search,
  required Future<TmdbMovie?> Function(int id) movie,
  required Map<String, int?> tmdbIds,
  DateTime? now,
}) async {
  now ??= DateTime.now();
  final since = DateTime(now.year, now.month - recentMonths, now.day);
  final byPoster = <String, List<C411Torrent>>{};
  var torrents = 0;
  for (var year = since.year; year <= now.year; year++) {
    for (final t in await catalog.films(year)) {
      byPoster.putIfAbsent(t.posterUrl ?? t.infoHash, () => []).add(t);
      torrents++;
    }
  }
  Log.d('suggestions', 'C411: $torrents torrents, ${byPoster.length} posters');
  // Films no longer listed (a year that dropped out) are forgotten.
  tmdbIds.removeWhere((poster, _) => !byPoster.containsKey(poster));

  // TMDB a few at a time (it rate-limits per IP); C411 paces itself.
  final unknown = [
    for (final key in byPoster.keys)
      if (!tmdbIds.containsKey(key)) key,
  ];
  final unmatched = <String>[];
  for (var i = 0; i < unknown.length; i += 20) {
    await Future.wait(
      unknown.skip(i).take(20).map((key) async {
        final id = await _searchTmdb(search, byPoster[key]!);
        id == null ? unmatched.add(key) : tmdbIds[key] = id;
      }),
    );
  }
  var missing = 0;
  for (final key in unmatched) {
    final id = tmdbIds[key] = await catalog.tmdbId(
      byPoster[key]!.first.infoHash,
    );
    if (id == null) missing++;
  }
  Log.d(
    'suggestions',
    '${byPoster.length} films on C411, ${unknown.length} new: '
        '${unknown.length - unmatched.length} found on TMDB, '
        '${unmatched.length - missing} by C411, $missing without a TMDB id',
  );

  // Posters that turn out to be one film (a re-upload after TMDB changed its
  // poster) merge here.
  final byFilm = <int, List<C411Torrent>>{};
  for (final MapEntry(:key, value: torrents) in byPoster.entries) {
    final id = tmdbIds[key];
    if (id != null) byFilm.putIfAbsent(id, () => []).addAll(torrents);
  }
  final ids = byFilm.keys.toList();
  final movies = <TmdbMovie?>[];
  for (var i = 0; i < ids.length; i += 20) {
    movies.addAll(await Future.wait(ids.skip(i).take(20).map(movie)));
  }
  return [
    for (final (i, m) in movies.indexed)
      // Unknown release date: nowhere to place it, left out.
      if (m != null && DateTime.tryParse(m.releaseDate ?? '') != null)
        FilmSuggestion(
          // What a card shows. The film page loads the rest (synopsis, …);
          // the list is a third lighter without it.
          movie: TmdbMovie(
            id: m.id,
            title: m.title,
            originalTitle: m.originalTitle,
            posterUrl: m.posterUrl,
            releaseDate: m.releaseDate,
            voteAverage: m.voteAverage,
            voteCount: m.voteCount,
          ),
          releases: [for (final t in byFilm[ids[i]]!) t.toRelease(ids[i])],
        ),
  ];
}

// The TMDB id whose title is the one in [torrents]' names, trying up to three
// distinct names (a film's torrents may carry its French or original title).
Future<int?> _searchTmdb(TmdbSearch search, List<C411Torrent> torrents) async {
  final names = {for (final t in torrents) titleAndYear(t.name)}.take(3);
  for (final (title, year) in names) {
    final wanted = normalizeTitle(title);
    if (wanted.isEmpty) continue;
    for (final hit in (await search(title, year: year)).take(5)) {
      if (normalizeTitle(hit.title) == wanted ||
          normalizeTitle(hit.originalTitle) == wanted) {
        return hit.id;
      }
    }
  }
  return null;
}

// Every year-like number in a release name. The film's year is the last one
// before the tags: a title can hold another ("1917.2019…", "Blade.Runner.2049…").
final _yearRe = RegExp(r'(?<!\d)(?:19|20)\d{2}(?!\d)');

/// The title and year a release name starts with:
/// `Le.Dernier.Refuge.2026.MULTi.1080p…` → `('Le Dernier Refuge', 2026)`.
(String, int?) titleAndYear(String name) {
  final year = _yearRe.allMatches(name).lastOrNull;
  final head = year == null ? name : name.substring(0, year.start);
  return (
    head.replaceAll(RegExp(r'[._]+'), ' ').trim(),
    year == null ? null : int.parse(year[0]!),
  );
}

const _accented = 'àáâãäåçèéêëìíîïñòóôõöùúûüýÿ';
const _plain = 'aaaaaaceeeeiiiinooooouuuuyy';

/// [title] lowercased, without accents or punctuation, so that a release
/// name's `Don.t.Say.Good.Luck` and `La.Venus.Electrique` equal TMDB's
/// "Don't Say Good Luck" and "La Vénus électrique".
String normalizeTitle(String title) {
  final out = StringBuffer();
  for (final c in title.toLowerCase().split('')) {
    final i = _accented.indexOf(c);
    out.write(i < 0 ? c : _plain[i]);
  }
  return out
      .toString()
      .replaceAll('œ', 'oe')
      .replaceAll('æ', 'ae')
      .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
      .trim();
}

/// The suggestions, rebuilt in the background every day and kept in [db], so
/// that a restart serves the last list at once instead of waiting minutes for
/// a rebuild (and C411 isn't asked for a whole year again). AlloCiné ids arrive
/// after the films: Wikidata can take a minute to answer.
class SuggestionsCache {
  SuggestionsCache({
    required this.build,
    required this.allocineIds,
    required this.db,
  });

  /// Builds the list, reading and adding to the TMDB ids it is handed.
  final Future<List<FilmSuggestion>> Function(Map<String, int?> tmdbIds) build;

  /// AlloCiné ids by TMDB id, for the ids it knows.
  final Future<Map<int, String>> Function(Iterable<int> tmdbIds) allocineIds;
  final CineseedDb db;

  static const _day = Duration(days: 1);

  List<FilmSuggestion>? _films;
  late final _allocine = db.allocineIds(); // an AlloCiné id never changes
  List<int>? _body; // the response, encoded once per change
  Future<void>? _refreshing;
  Timer? _timer;

  /// Serves the saved list, and rebuilds once it is a day old.
  void start() {
    var age = _day;
    if (db.suggestions() case (:final films, :final builtAt)) {
      _films = films;
      age = DateTime.now().difference(builtAt);
      _encode();
      _lookUpAllocine();
    }
    _timer = Timer(age >= _day ? Duration.zero : _day - age, () {
      _background();
      _timer = Timer.periodic(_day, (_) => _background());
    });
  }

  void _background() => unawaited(
    refresh().catchError(
      (Object e) =>
          Log.w('suggestions', 'rebuild failed, keeping the last list: $e'),
    ),
  );

  /// The list as JSON. Only waits when there is none yet: the very first
  /// build, or every one so far failed (then it throws why).
  Future<List<int>> json() async {
    if (_body == null) await refresh();
    return _body!;
  }

  /// Rebuilds the list. Concurrent calls share the run in flight.
  Future<void> refresh() =>
      _refreshing ??= _refresh().whenComplete(() => _refreshing = null);

  Future<void> _refresh() async {
    final tmdbIds = db.filmIds();
    final List<FilmSuggestion> films;
    try {
      films = await build(tmdbIds);
    } finally {
      db.setFilmIds(tmdbIds); // what was found stays found, even on a failure
    }
    db.setSuggestions(films, DateTime.now());
    _films = films;
    _encode();
    Log.d('suggestions', 'rebuilt: ${films.length} films');
    _lookUpAllocine();
  }

  // Links fall back to an AlloCiné search without an id, so a Wikidata failure
  // costs direct links only, until the next rebuild or restart.
  void _lookUpAllocine() {
    final unknown = [
      for (final f in _films!)
        if (!_allocine.containsKey(f.movie.id)) f.movie.id,
    ];
    if (unknown.isEmpty) return;
    unawaited(
      allocineIds(unknown).then((ids) {
        db.addAllocineIds(ids);
        _allocine.addAll(ids);
        _encode();
      }, onError: (Object e) => Log.w('suggestions', 'Wikidata lookup: $e')),
    );
  }

  void _encode() => _body = utf8.encode(
    jsonEncode([
      for (final f in _films!)
        FilmSuggestion(
          movie: f.movie,
          releases: f.releases,
          allocineId: _allocine[f.movie.id],
        ).toJson(),
    ]),
  );

  void dispose() => _timer?.cancel();
}
