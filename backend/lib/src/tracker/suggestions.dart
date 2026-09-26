import 'package:cineseed_shared/cineseed_shared.dart';

import 'tracker_connector.dart';

/// The films among the tracker's [count] latest movie releases, best TMDB
/// rating first; unrated films last. Releases without a TMDB id, or whose id
/// TMDB doesn't know, have nothing to rank by and are left out.
Future<List<FilmSuggestion>> latestByRating(
  TrackerConnector tracker,
  Future<TmdbMovie?> Function(int id) tmdbMovie, {
  int count = 100,
}) async {
  final byFilm = <int, List<TorrentResult>>{};
  for (final r in await tracker.latestMovies(count)) {
    final id = r.tmdbId;
    if (id == null || r.mediaType != MediaType.movie) continue;
    byFilm.putIfAbsent(id, () => []).add(r);
  }

  // A few at a time: TMDB rate-limits per IP.
  final ids = byFilm.keys.toList();
  final movies = <TmdbMovie?>[];
  for (var i = 0; i < ids.length; i += 20) {
    movies.addAll(await Future.wait(ids.skip(i).take(20).map(tmdbMovie)));
  }

  return [
    for (final (i, m) in movies.indexed)
      if (m != null) FilmSuggestion(movie: m, releases: byFilm[ids[i]]!),
  ]..sort((a, b) => (b.movie.rating ?? -1).compareTo(a.movie.rating ?? -1));
}
