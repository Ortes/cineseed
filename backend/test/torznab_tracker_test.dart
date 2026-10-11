import 'dart:convert';

import 'package:cineseed_backend/src/tracker/torznab_tracker.dart';
import 'package:cineseed_shared/cineseed_shared.dart';
import 'package:cineseed_backend/src/tracker/tracker_connector.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

TorznabTracker _tracker(http.Response res) => TorznabTracker(
  baseUrl: 'https://tracker.test',
  apiKey: 'k',
  client: MockClient((_) async => res),
);

void main() {
  test('an HTML page instead of RSS surfaces as TrackerException', () async {
    // C411's outage page: HTTP 200, `text/html` without a charset, UTF-8 body.
    const page =
        '<html><head><link rel="x"></head><body>Incident en cours : '
        'momentanément indisponibles</body></html>';
    final tracker = _tracker(
      http.Response.bytes(
        utf8.encode(page),
        200,
        headers: {'content-type': 'text/html'},
      ),
    );
    await expectLater(
      tracker.search('matrix'),
      throwsA(isA<TrackerException>().having((e) => e.body, 'body', page)),
    );
  });

  test('a Torznab <error/> surfaces its description', () async {
    final tracker = _tracker(
      http.Response('<error code="100" description="Bad key"/>', 200),
    );
    await expectLater(
      tracker.search('matrix'),
      throwsA(
        isA<TrackerException>().having(
          (e) => e.message,
          'message',
          'The tracker refused the search: Bad key',
        ),
      ),
    );
  });

  test('releases pages through every result of a TMDB id', () async {
    String feed(int from, int count) =>
        '<rss><channel>${[for (var i = from; i < from + count; i++) '<item><title>t$i</title><guid>h$i</guid></item>'].join()}</channel></rss>';
    final requested = <Map<String, String>>[];
    final tracker = TorznabTracker(
      baseUrl: 'https://tracker.test',
      apiKey: 'k',
      client: MockClient((req) async {
        requested.add(req.url.queryParameters);
        final offset = int.parse(req.url.queryParameters['offset']!);
        return http.Response(feed(offset, offset == 0 ? 100 : 12), 200);
      }),
    );
    final results = await tracker.releases(1399, MediaType.tv);
    expect(results, hasLength(112));
    expect(requested.map((q) => (q['t'], q['tmdbid'], q['offset'])), [
      ('tvsearch', '1399', '0'),
      ('tvsearch', '1399', '100'),
    ]);
  });
}
