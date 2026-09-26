import 'dart:convert';

import 'package:cineseed_shared/cineseed_shared.dart';
import 'package:http/http.dart' as http;

/// C411's own site API (`/api/torrents`), beside its Torznab feed. Unlike
/// Torznab it filters by the film's year; it takes the same API key, as a
/// Bearer token. Its torrent lists carry no TMDB id: [tmdbId] asks for one.
class C411Catalog {
  C411Catalog({
    required this.baseUrl,
    required this.apiKey,
    this.requestInterval = const Duration(milliseconds: 500),
    http.Client? client,
  }) : _http = client ?? http.Client();

  final String baseUrl;
  final String apiKey;

  /// Least time between two requests. C411 allows 1200 a minute per key (its
  /// `x-ratelimit-*` headers), shared with everything else using the key: this
  /// keeps to a tenth of it.
  final Duration requestInterval;
  final http.Client _http;
  var _nextRequest = DateTime(0);

  /// Films, animated films and documentaries: the Film, Animation and
  /// Documentaire subcategories of Films & Vidéos (category 1).
  static const filmSubcategories = '6,1,4';

  Future<http.Response> _get(Uri uri) async {
    final now = DateTime.now();
    final at = _nextRequest.isAfter(now) ? _nextRequest : now;
    _nextRequest = at.add(requestInterval); // reserved before awaiting
    await Future<void>.delayed(at.difference(now));
    return _http.get(uri, headers: {'Authorization': 'Bearer $apiKey'});
  }

  /// Every film torrent C411 files under [year], newest upload first. One
  /// request per 100 torrents.
  Future<List<C411Torrent>> films(int year) async {
    final out = <C411Torrent>[];
    for (var page = 1, pages = 1; page <= pages; page++) {
      final uri = Uri.parse('$baseUrl/api/torrents').replace(
        queryParameters: {
          'category': '1',
          'subcat': filmSubcategories,
          'year': '$year',
          'sortBy': 'createdAt',
          'sortOrder': 'desc',
          'perPage': '100',
          'page': '$page',
        },
      );
      final res = await _get(uri);
      if (res.statusCode != 200) {
        throw Exception(
          'C411 $year films, page $page → HTTP ${res.statusCode}',
        );
      }
      final j = jsonDecode(res.body) as Map<String, dynamic>;
      pages = ((j['meta'] as Map)['totalPages'] as num).toInt();
      out.addAll(
        (j['data'] as List).cast<Map<String, dynamic>>().map(
          C411Torrent.fromJson,
        ),
      );
    }
    return out;
  }

  /// The TMDB id C411 files [infoHash] under, if it has one.
  Future<int?> tmdbId(String infoHash) async {
    final res = await _get(Uri.parse('$baseUrl/api/torrents/$infoHash'));
    if (res.statusCode != 200) {
      throw Exception('C411 torrent $infoHash → HTTP ${res.statusCode}');
    }
    final ids = (jsonDecode(res.body) as Map)['externalIds'] as List? ?? [];
    for (final id in ids.cast<Map<String, dynamic>>()) {
      if (id['kind'] == 'tmdb_movie') return int.tryParse('${id['value']}');
    }
    return null;
  }
}

/// One torrent of [C411Catalog.films].
class C411Torrent {
  const C411Torrent({
    required this.name,
    required this.infoHash,
    this.posterUrl,
    this.seeders = 0,
    this.leechers = 0,
    this.completions = 0,
    this.size = 0,
    this.createdAt,
  });

  final String name;
  final String infoHash;

  /// The film's TMDB poster, as C411 took it at upload: the same for all of a
  /// film's torrents, bar re-uploads after TMDB changed it.
  final String? posterUrl;
  final int seeders;
  final int leechers;
  final int completions;
  final int size;
  final DateTime? createdAt;

  factory C411Torrent.fromJson(Map<String, dynamic> j) => C411Torrent(
    name: j['name'] as String,
    infoHash: j['infoHash'] as String,
    posterUrl: j['posterUrl'] as String?,
    seeders: (j['seeders'] as num?)?.toInt() ?? 0,
    leechers: (j['leechers'] as num?)?.toInt() ?? 0,
    completions: (j['completions'] as num?)?.toInt() ?? 0,
    size: (j['size'] as num?)?.toInt() ?? 0,
    createdAt: DateTime.tryParse(j['createdAt'] as String? ?? ''),
  );

  TorrentResult toRelease(int tmdbId) => TorrentResult(
    title: name,
    infoHash: infoHash,
    tmdbId: tmdbId,
    mediaType: MediaType.movie,
    seeders: seeders,
    leechers: leechers,
    grabs: completions,
    size: size,
    pubDate: createdAt,
  );
}
