import 'dart:convert';
import 'dart:io' show HttpDate;

import 'package:http/http.dart' as http;
import 'package:xml/xml.dart';
import 'package:cineseed_shared/cineseed_shared.dart';

import 'tracker_connector.dart';

/// Generic Torznab connector. Works with Prowlarr, Jackett, or any tracker
/// exposing a Torznab feed directly.
///
/// - search:   `GET {base}/api?t=search&q=<q>&apikey=<key>` → RSS
/// - download: `GET {base}/api?t=get&id=<infoHash>&apikey=<key>` → .torrent bytes
///   (`t=get` returns a ready-to-add .torrent — no cookie, no CAPTCHA, fully
///   automatable.)
class TorznabTracker implements TrackerConnector {
  final String baseUrl;
  final String apiKey;
  final http.Client _http;

  TorznabTracker({
    required this.baseUrl,
    required this.apiKey,
    http.Client? client,
  }) : _http = client ?? http.Client();

  Uri _api(Map<String, String> params) => Uri.parse(
    '$baseUrl/api',
  ).replace(queryParameters: {...params, 'apikey': apiKey});

  @override
  Future<List<TorrentResult>> search(String query, {String? type}) async {
    final res = await _http.get(_api({'t': 'search', 'q': query}));
    if (res.statusCode != 200) {
      throw TrackerException(
        _unavailable,
        'HTTP ${res.statusCode}',
        _page(res),
      );
    }
    return _parseRss(res);
  }

  static const _unavailable =
      "The tracker isn't answering searches right now. Here's what it says:";

  /// The body as the user should read it. `res.body` falls back to Latin-1
  /// when Content-Type has no charset (C411's outage page is `text/html`,
  /// UTF-8 per its `<meta charset>`), which garbles every accent.
  static String _page(http.Response res) =>
      utf8.decode(res.bodyBytes, allowMalformed: true);

  @override
  Future<List<int>> fetchTorrent(String infoHash) async {
    final res = await _http.get(_api({'t': 'get', 'id': infoHash}));
    if (res.statusCode != 200) {
      throw Exception('Tracker fetchTorrent failed: HTTP ${res.statusCode}');
    }
    return res.bodyBytes;
  }

  List<TorrentResult> _parseRss(http.Response res) {
    final XmlDocument doc;
    try {
      doc = XmlDocument.parse(res.body);
    } on XmlException catch (e) {
      throw TrackerException(
        _unavailable,
        'not a Torznab feed: $e',
        _page(res),
      );
    }
    // Torznab reports failures as <error code=".." description=".."/>.
    final error = doc.rootElement;
    if (error.localName == 'error') {
      throw TrackerException(
        'The tracker refused the search: ${error.getAttribute('description')}',
        'Torznab error ${error.getAttribute('code')}',
        _page(res),
      );
    }
    final results = <TorrentResult>[];

    for (final item in doc.findAllElements('item')) {
      // Torznab attributes: <torznab:attr name="seeders" value="10"/>
      final attrs = <String, String>{};
      for (final a in item.descendants.whereType<XmlElement>()) {
        if (a.localName != 'attr') continue;
        final name = a.getAttribute('name');
        final value = a.getAttribute('value');
        if (name != null && value != null) attrs[name] = value;
      }

      // infoHash: torznab attr → enclosure ?id= → guid
      var infoHash = attrs['infohash'] ?? '';
      final enclosureUrl = _firstOrNull(
        item.findElements('enclosure'),
      )?.getAttribute('url');
      if (infoHash.isEmpty && enclosureUrl != null) {
        infoHash = Uri.tryParse(enclosureUrl)?.queryParameters['id'] ?? '';
      }
      if (infoHash.isEmpty) infoHash = _childText(item, 'guid');
      if (infoHash.isEmpty) continue;

      // Torznab "peers" is total swarm (seeders + leechers); some indexers
      // expose "leechers" directly. Prefer the explicit one.
      final seeders = int.tryParse(attrs['seeders'] ?? '') ?? 0;
      final leechers =
          int.tryParse(attrs['leechers'] ?? '') ??
          (() {
            final peers = int.tryParse(attrs['peers'] ?? '');
            return peers == null ? 0 : (peers - seeders).clamp(0, peers);
          })();

      // RFC 822/2822 (Torznab uses HTTP-date). Some indexers emit a numeric
      // tz offset like `+0000`, which `HttpDate.parse` rejects (it only
      // accepts `GMT`). Try strict HTTP-date first, then a small RFC 2822
      // fallback with numeric offsets, then ISO 8601 as last resort.
      final pubDateRaw = _childText(item, 'pubDate');
      DateTime? pubDate;
      if (pubDateRaw.isNotEmpty) {
        try {
          pubDate = HttpDate.parse(pubDateRaw);
        } catch (_) {
          pubDate = _parseRfc2822(pubDateRaw) ?? DateTime.tryParse(pubDateRaw);
        }
      }

      results.add(
        TorrentResult(
          title: _childText(item, 'title'),
          infoHash: infoHash,
          tmdbId: int.tryParse(attrs['tmdbid'] ?? ''),
          mediaType: MediaType.fromTorznabCategory(
            int.tryParse(attrs['category'] ?? ''),
          ),
          seeders: seeders,
          leechers: leechers,
          grabs: int.tryParse(attrs['grabs'] ?? '') ?? 0,
          size: int.tryParse(attrs['size'] ?? _childText(item, 'size')) ?? 0,
          pubDate: pubDate,
        ),
      );
    }
    return results;
  }

  String _childText(XmlElement parent, String name) =>
      _firstOrNull(parent.findElements(name))?.innerText.trim() ?? '';

  static T? _firstOrNull<T>(Iterable<T> it) => it.isEmpty ? null : it.first;
}

/// Parses an RFC 2822-style date with a numeric timezone offset, e.g.
/// `Tue, 10 Mar 2026 23:55:42 +0000`. Returns a UTC `DateTime` or `null` if
/// the input doesn't match. The day-name prefix is optional.
DateTime? _parseRfc2822(String raw) {
  final m = RegExp(
    r'^(?:\w{3},\s+)?(\d{1,2})\s+(\w{3})\s+(\d{4})\s+'
    r'(\d{2}):(\d{2}):(\d{2})\s+([+-]\d{4}|GMT|UTC)\s*$',
  ).firstMatch(raw.trim());
  if (m == null) return null;
  const months = {
    'Jan': 1,
    'Feb': 2,
    'Mar': 3,
    'Apr': 4,
    'May': 5,
    'Jun': 6,
    'Jul': 7,
    'Aug': 8,
    'Sep': 9,
    'Oct': 10,
    'Nov': 11,
    'Dec': 12,
  };
  final mon = months[m.group(2)!];
  if (mon == null) return null;
  final tz = m.group(7)!;
  int offsetMin = 0;
  if (tz.startsWith('+') || tz.startsWith('-')) {
    final sign = tz[0] == '-' ? -1 : 1;
    offsetMin =
        sign *
        (int.parse(tz.substring(1, 3)) * 60 + int.parse(tz.substring(3, 5)));
  }
  // Build the wall-clock as UTC, then subtract the offset to get true UTC.
  final wall = DateTime.utc(
    int.parse(m.group(3)!),
    mon,
    int.parse(m.group(1)!),
    int.parse(m.group(4)!),
    int.parse(m.group(5)!),
    int.parse(m.group(6)!),
  );
  return wall.subtract(Duration(minutes: offsetMin));
}
