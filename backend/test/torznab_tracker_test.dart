import 'dart:convert';

import 'package:cineseed_backend/src/tracker/torznab_tracker.dart';
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
}
