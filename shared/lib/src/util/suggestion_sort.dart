import '../models/film_suggestion.dart';
import '../models/tmdb_movie.dart';

/// The orders the Suggestions tab offers.
enum SuggestionSort {
  /// Rating and release date together: [recommendedScore].
  recommended,

  /// Best [weightedRating] first; unrated films last.
  rating,

  /// Latest release first.
  releaseDate,
}

/// Votes a rating needs to count at face value. With fewer, it is pulled
/// towards [typicalRating] (a Bayesian average), so a 9.0 from three votes
/// doesn't outrank an 8.3 from two thousand.
const ratingPriorVotes = 50;

/// Where a rating with few votes is pulled to: a middling TMDB rating.
const typicalRating = 6.5;

/// Rating points a film gives up per month since its release, in the
/// recommended order.
const agePenaltyPerMonth = 0.5;

/// [movie]'s TMDB rating weighed by its vote count: [typicalRating] unrated.
double weightedRating(TmdbMovie movie) {
  final votes = movie.rating == null ? 0 : movie.voteCount!;
  return (votes * (movie.rating ?? 0) + ratingPriorVotes * typicalRating) /
      (votes + ratingPriorVotes);
}

/// [weightedRating] minus [agePenaltyPerMonth] per month since release: a film
/// out today rated 7.0 ranks with one out two months ago rated 8.0.
double recommendedScore(TmdbMovie movie, DateTime now) {
  final released = DateTime.tryParse(movie.releaseDate ?? '');
  final months = released == null
      ? 1.0
      : (now.difference(released).inDays / 30.44).clamp(0, double.infinity);
  return weightedRating(movie) - agePenaltyPerMonth * months;
}

/// [films] in [sort] order.
List<FilmSuggestion> sortSuggestions(
  Iterable<FilmSuggestion> films,
  SuggestionSort sort,
  DateTime now,
) {
  double key(TmdbMovie m) => switch (sort) {
    SuggestionSort.recommended => recommendedScore(m, now),
    SuggestionSort.rating => m.rating == null ? -1 : weightedRating(m),
    SuggestionSort.releaseDate =>
      (DateTime.tryParse(m.releaseDate ?? '')?.millisecondsSinceEpoch ?? 0)
          .toDouble(),
  };
  final keyed = [for (final f in films) (f, key(f.movie))]
    ..sort((a, b) => b.$2.compareTo(a.$2));
  return [for (final (f, _) in keyed) f];
}
