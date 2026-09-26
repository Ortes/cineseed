/// Broad media category of a tracker release, derived from its Torznab
/// category code. This is what lets the app pick TMDB's `/movie/{id}` vs
/// `/tv/{id}` endpoint: those id namespaces are independent and can collide on
/// the same integer (e.g. movie 1396 = *Mirror*, TV 1396 = *Breaking Bad*), so
/// a TV id looked up as a movie silently resolves to the wrong title.
enum MediaType {
  movie,
  tv,
  other;

  /// Maps a Torznab/Newznab category code to a media type. The thousands digit
  /// is the top-level bucket: `2xxx` = Movies, `5xxx` = TV. Anything else
  /// (audio, books, apps, …) and `null` map to [other].
  factory MediaType.fromTorznabCategory(int? category) {
    if (category == null) return MediaType.other;
    return switch (category ~/ 1000) {
      2 => MediaType.movie,
      5 => MediaType.tv,
      _ => MediaType.other,
    };
  }

  factory MediaType.fromJson(String? value) => switch (value) {
    'movie' => MediaType.movie,
    'tv' => MediaType.tv,
    _ => MediaType.other,
  };

  String toJson() => name;
}
