import 'dart:convert';
import 'dart:io';

import 'package:cineseed_backend/src/database.dart';
import 'package:cineseed_backend/src/tracker/c411_catalog.dart';
import 'package:cineseed_backend/src/tracker/suggestions.dart';
import 'package:cineseed_shared/cineseed_shared.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

Map<String, Object?> _torrent(String name, String hash, String? poster) => {
  'name': name,
  'infoHash': hash,
  'posterUrl': poster,
  'seeders': 3,
  'completions': 40,
  'size': 1000,
  'createdAt': '2026-09-01T10:00:00Z',
};

/// A C411 site API: [byYear] torrents in pages of 2, and [tmdbByHash] ids.
C411Catalog _c411(
  Map<int, List<Map<String, Object?>>> byYear, {
  Map<String, int> tmdbByHash = const {},
  List<String>? log,
  List<String>? details,
}) => C411Catalog(
  baseUrl: 'https://c411.test',
  apiKey: 'k',
  requestInterval: Duration.zero,
  client: MockClient((req) async {
    expect(req.headers['Authorization'], 'Bearer k');
    final q = req.url.queryParameters;
    if (req.url.path == '/api/torrents') {
      log?.add(q['year']!);
      expect(q['subcat'], '6,1,4');
      final all = byYear[int.parse(q['year']!)] ?? [];
      final page = int.parse(q['page']!);
      return http.Response(
        jsonEncode({
          'data': all.skip((page - 1) * 2).take(2).toList(),
          'meta': {'totalPages': (all.length / 2).ceil()},
        }),
        200,
      );
    }
    final hash = req.url.pathSegments.last;
    details?.add(hash);
    return http.Response(
      jsonEncode({
        'externalIds': [
          if (tmdbByHash[hash] case final id?)
            {'kind': 'tmdb_movie', 'value': '$id'},
        ],
      }),
      200,
    );
  }),
);

void main() {
  final now = DateTime(2026, 9, 26);

  test('titleAndYear and normalizeTitle read release names', () {
    expect(titleAndYear('Le.Dernier.Refuge.2026.MULTi.1080p-GRP'), (
      'Le Dernier Refuge',
      2026,
    ));
    expect(titleAndYear('Blade.Runner.2049.2017.1080p').$2, 2017);
    expect(normalizeTitle('Don t Say Good Luck'), "don t say good luck");
    expect(
      normalizeTitle('La Venus Electrique'),
      normalizeTitle('La Vénus électrique'),
    );
  });

  test('C411Catalog pages through a year and reads TMDB ids', () async {
    final catalog = _c411(
      {
        2026: [for (var i = 0; i < 5; i++) _torrent('F.$i.2026', 'h$i', 'p$i')],
      },
      tmdbByHash: {'h1': 11},
    );
    final films = await catalog.films(2026);
    expect(films.map((t) => t.infoHash), ['h0', 'h1', 'h2', 'h3', 'h4']);
    expect(films.first.toRelease(7).grabs, 40);
    expect(await catalog.tmdbId('h1'), 11);
    expect(await catalog.tmdbId('h0'), isNull);
  });

  test('recentFilms: the years of the last 3 months, TMDB, C411', () async {
    final years = <String>[];
    final details = <String>[];
    final catalog = _c411(
      {
        2026: [
          _torrent('Film.A.2026.1080p', 'a1', 'pa'),
          _torrent('Film.A.2026.2160p', 'a2', 'pa'),
          _torrent(
            'Film.A.VFF.2026.720p',
            'a3',
            'pa2',
          ), // re-upload, new poster
          _torrent('Titre.Francais.2026.1080p', 'b1', 'pb'),
          _torrent('Old.Film.2026.1080p', 'c1', 'pc'),
          _torrent('Unknown.Everywhere.2026.1080p', 'e1', 'pe'),
        ],
        2025: [_torrent('Last.Year.2025.1080p', 'd1', 'pd')],
      },
      // Neither title is TMDB's (a French one, a tag before the year).
      tmdbByHash: {'b1': 2, 'a3': 1},
      log: years,
      details: details,
    );
    final searched = <String>[];
    Future<List<({int id, String title, String originalTitle})>> search(
      String q, {
      int? year,
    }) async {
      searched.add(q);
      return switch (q) {
        'Film A' => [(id: 1, title: 'Film A', originalTitle: 'Film A')],
        'Old Film' => [(id: 3, title: 'Old Film', originalTitle: 'Old Film')],
        'Last Year' => [
          (id: 4, title: 'Last Year', originalTitle: 'Last Year'),
        ],
        _ => [(id: 99, title: 'Something else', originalTitle: 'Else')],
      };
    }

    const movies = {
      1: TmdbMovie(id: 1, title: 'Film A', releaseDate: '2026-09-01'),
      2: TmdbMovie(id: 2, title: 'French title', releaseDate: '2026-07-10'),
      3: TmdbMovie(id: 3, title: 'Old Film', releaseDate: '2026-03-01'),
      4: TmdbMovie(id: 4, title: 'Last Year', releaseDate: '2025-12-20'),
    };
    final tmdbIds = <String, int?>{};
    Future<List<FilmSuggestion>> run(DateTime at) => recentFilms(
      catalog: catalog,
      search: search,
      movie: (id) async => movies[id],
      tmdbIds: tmdbIds,
      now: at,
    );

    final films = await run(now);
    expect(films.map((f) => f.movie.id), [1, 2, 3]); // all of this year's
    expect(films.first.releases.map((r) => r.infoHash), ['a1', 'a2', 'a3']);
    expect(details, ['a3', 'b1', 'e1']); // no TMDB match: asked C411
    expect(years.toSet(), {'2026'}); // September: this year only
    expect(tmdbIds, {'pa': 1, 'pa2': 1, 'pb': 2, 'pc': 3, 'pe': null});

    searched.clear();
    details.clear();
    await run(now);
    expect([...searched, ...details], isEmpty); // known films cost nothing

    years.clear();
    final february = await run(DateTime(2026, 2, 10)); // reaches into 2025
    expect(years.toSet(), {'2026', '2025'});
    expect(february.map((f) => f.movie.id), contains(4));
    expect(tmdbIds, contains('pd'));

    await run(now); // back to this year only: last year's film is forgotten
    expect(tmdbIds, isNot(contains('pd')));
  });

  test('SuggestionsCache serves the saved list after a restart', () async {
    final dir = await Directory.systemTemp.createTemp('suggestions');
    addTearDown(() => dir.delete(recursive: true));
    final path = '${dir.path}/cineseed.db';
    const film = FilmSuggestion(
      movie: TmdbMovie(id: 7, title: 'Film'),
      releases: [],
    );
    final db = CineseedDb.open(path);
    final first = SuggestionsCache(
      build: (ids) async => [film],
      allocineIds: (ids) async => {for (final id in ids) id: 'ac$id'},
      db: db,
    );
    await first.json();
    await Future<void>.delayed(Duration.zero); // the Wikidata lookup lands
    db.close();

    final reopened = CineseedDb.open(path);
    addTearDown(reopened.close);
    final restarted = SuggestionsCache(
      build: (ids) => throw StateError('must not rebuild'),
      allocineIds: (ids) => throw StateError('must not look up'),
      db: reopened,
    )..start();
    addTearDown(restarted.dispose);
    final served = jsonDecode(utf8.decode(await restarted.json()));
    expect(served, [containsPair('allocineId', 'ac7')]);
  });

  test('sortSuggestions: rating weighed by votes, recency, both', () {
    FilmSuggestion f(int id, double? rating, int votes, String date) =>
        FilmSuggestion(
          movie: TmdbMovie(
            id: id,
            title: '$id',
            voteAverage: rating,
            voteCount: votes,
            releaseDate: date,
          ),
          releases: const [],
        );
    final films = [
      f(1, 9.0, 3, '2026-09-01'), // barely voted
      f(2, 8.3, 2000, '2026-07-01'), // well rated, three months old
      f(3, 7.2, 400, '2026-09-20'), // decent, just out
      f(4, null, 0, '2026-09-25'), // unrated, newest
    ];
    List<int> ids(SuggestionSort s) => [
      for (final x in sortSuggestions(films, s, now)) x.movie.id,
    ];
    expect(ids(SuggestionSort.rating), [2, 3, 1, 4]);
    expect(ids(SuggestionSort.releaseDate), [4, 3, 1, 2]);
    expect(ids(SuggestionSort.recommended), [3, 2, 4, 1]);
  });
}
