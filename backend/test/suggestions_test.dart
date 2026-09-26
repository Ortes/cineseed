import 'package:cineseed_backend/src/tracker/suggestions.dart';
import 'package:cineseed_backend/src/tracker/torznab_tracker.dart';
import 'package:cineseed_backend/src/tracker/tracker_connector.dart';
import 'package:cineseed_shared/cineseed_shared.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

String _rss(Iterable<int> ids) =>
    '<rss xmlns:torznab="http://torznab.com/schemas/2015/feed"><channel>'
    '${ids.map((i) => '<item><title>Film.$i</title>'
        '<torznab:attr name="infohash" value="h$i"/>'
        '<torznab:attr name="category" value="2000"/></item>').join()}'
    '</channel></rss>';

class _FakeTracker implements TrackerConnector {
  _FakeTracker(this.releases);
  final List<TorrentResult> releases;

  @override
  Future<List<TorrentResult>> latestMovies(int count) async => releases;

  @override
  Future<List<TorrentResult>> search(String query, {String? type}) =>
      throw UnimplementedError();

  @override
  Future<List<int>> fetchTorrent(String infoHash) => throw UnimplementedError();
}

TorrentResult _release(String hash, int? tmdbId) => TorrentResult(
  title: hash,
  infoHash: hash,
  tmdbId: tmdbId,
  mediaType: MediaType.movie,
);

void main() {
  test('latestMovies pages past the indexer page size', () async {
    final offsets = <String?>[];
    final tracker = TorznabTracker(
      baseUrl: 'http://tracker',
      apiKey: 'k',
      client: MockClient((req) async {
        final q = req.url.queryParameters;
        expect(q['cat'], '2000');
        expect(q.containsKey('q'), isFalse);
        offsets.add(q['offset']);
        // A 40-per-page indexer holding 90 releases.
        final start = int.parse(q['offset']!);
        final end = (start + 40).clamp(0, 90);
        return http.Response(_rss([for (var i = start; i < end; i++) i]), 200);
      }),
    );
    final latest = await tracker.latestMovies(100);
    expect(latest.map((r) => r.infoHash), [for (var i = 0; i < 90; i++) 'h$i']);
    expect(offsets, ['0', '40', '80', '90']);
  });

  test('latestMovies stops on an indexer that ignores offset', () async {
    final tracker = TorznabTracker(
      baseUrl: 'http://tracker',
      apiKey: 'k',
      client: MockClient(
        (_) async => http.Response(_rss([for (var i = 0; i < 40; i++) i]), 200),
      ),
    );
    expect(await tracker.latestMovies(100), hasLength(40));
  });

  test('latestByRating groups releases by film, best rated first', () async {
    const movies = {
      1: TmdbMovie(id: 1, title: 'Fine', voteAverage: 6.1, voteCount: 50),
      2: TmdbMovie(id: 2, title: 'Great', voteAverage: 8.4, voteCount: 900),
      3: TmdbMovie(id: 3, title: 'Unrated', voteAverage: 0, voteCount: 0),
    };
    final films = await latestByRating(
      _FakeTracker([
        _release('a', 1),
        _release('b', 3),
        _release('c', 2),
        _release('d', 1),
        _release('e', null), // no TMDB id: nothing to rank by
        _release('f', 404), // unknown to TMDB
      ]),
      (id) async => movies[id],
    );
    expect(films.map((f) => f.movie.title), ['Great', 'Fine', 'Unrated']);
    expect(films[1].releases.map((r) => r.infoHash), ['a', 'd']);
  });
}
