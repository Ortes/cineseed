import 'dart:math';

import 'package:cineseed_shared/cineseed_shared.dart';

import 'tracker_connector.dart';

/// The most an old film's rating is discounted: a 30-year-old film ranks as
/// if rated ~20 % lower. The latest releases are full of old films; this lets
/// the new ones through without dropping the classics.
const maxAgePenalty = 0.2;

/// Age, in years, at which a film takes half of [maxAgePenalty].
const agePenaltyHalfLife = 5.0;

/// A film's rank in the suggestions: its TMDB rating, discounted with age
/// (see [maxAgePenalty]). Null when unrated; an unknown release date counts as
/// old.
double? suggestionScore(TmdbMovie movie, DateTime now) {
  final rating = movie.rating;
  if (rating == null) return null;
  final released = DateTime.tryParse(movie.releaseDate ?? '');
  final years = released == null
      ? double.infinity
      : max(0, now.difference(released).inDays / 365.25);
  final freshness = pow(0.5, years / agePenaltyHalfLife); // 1 → 0 with age
  return rating * (1 - maxAgePenalty * (1 - freshness));
}

/// The films among the tracker's [count] latest movie releases, best
/// [suggestionScore] first; unrated films last. Releases without a TMDB id, or
/// whose id TMDB doesn't know, have nothing to rank by and are left out.
Future<List<FilmSuggestion>> latestByRating(
  TrackerConnector tracker,
  Future<TmdbMovie?> Function(int id) tmdbMovie, {
  int count = 100,
  DateTime? now,
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

  now ??= DateTime.now();
  double score(FilmSuggestion s) => suggestionScore(s.movie, now!) ?? -1;
  return [
    for (final (i, m) in movies.indexed)
      if (m != null) FilmSuggestion(movie: m, releases: byFilm[ids[i]]!),
  ]..sort((a, b) => score(b).compareTo(score(a)));
}
