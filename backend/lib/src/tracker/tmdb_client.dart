import 'dart:async';
import 'dart:convert';

import 'package:cineseed_shared/cineseed_shared.dart';
import 'package:http/http.dart' as http;

/// TMDB v3 client. Caches successful lookups in-memory (movies don't change).
class TmdbClient {
  TmdbClient({required this.apiKey, this.language = 'en-US'});

  final String apiKey;
  final String language;
  static const _imageBase = 'https://image.tmdb.org/t/p';
  static const _apiBase = 'https://api.themoviedb.org/3';

  // Movie and TV ids share the same integer space but are distinct entities,
  // so they're cached separately.
  final Map<int, TmdbMovie> _movieCache = {};
  final Map<int, TmdbMovie> _tvCache = {};

  Future<TmdbMovie?> movie(int id) => _fetch(
    'movie',
    id,
    _movieCache,
    titleKey: 'title',
    originalTitleKey: 'original_title',
    dateKey: 'release_date',
  );

  /// TV show by id via `/tv/{id}`. TMDB's TV schema differs (`name`,
  /// `first_air_date`, no top-level `runtime`), so those are normalized into
  /// the shared [TmdbMovie] shape.
  Future<TmdbMovie?> tv(int id) => _fetch(
    'tv',
    id,
    _tvCache,
    titleKey: 'name',
    originalTitleKey: 'original_name',
    dateKey: 'first_air_date',
  );

  Future<TmdbMovie?> _fetch(
    String kind,
    int id,
    Map<int, TmdbMovie> cache, {
    required String titleKey,
    required String originalTitleKey,
    required String dateKey,
  }) async {
    final cached = cache[id];
    if (cached != null) return cached;

    final uri = Uri.parse(
      '$_apiBase/$kind/$id',
    ).replace(queryParameters: {'api_key': apiKey, 'language': language});
    final res = await http.get(uri);
    if (res.statusCode == 404) return null;
    if (res.statusCode != 200) {
      throw StateError('TMDB $kind/$id → HTTP ${res.statusCode}: ${res.body}');
    }
    final j = jsonDecode(res.body) as Map<String, dynamic>;
    final poster = j['poster_path'] as String?;
    final backdrop = j['backdrop_path'] as String?;
    final item = TmdbMovie(
      id: (j['id'] as num).toInt(),
      title: (j[titleKey] as String?) ?? '',
      originalTitle: j[originalTitleKey] as String?,
      overview: j['overview'] as String?,
      posterUrl: poster != null ? '$_imageBase/w500$poster' : null,
      backdropUrl: backdrop != null ? '$_imageBase/w1280$backdrop' : null,
      releaseDate: j[dateKey] as String?,
      runtime: (j['runtime'] as num?)?.toInt(),
      voteAverage: (j['vote_average'] as num?)?.toDouble(),
      voteCount: (j['vote_count'] as num?)?.toInt(),
      genres: ((j['genres'] as List?) ?? const [])
          .map((g) => (g as Map)['name'] as String)
          .toList(),
    );
    cache[id] = item;
    return item;
  }
}
