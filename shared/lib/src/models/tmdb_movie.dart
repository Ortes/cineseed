/// Slim TMDB movie view returned by `/api/tmdb/movie/:id`.
class TmdbMovie {
  final int id;
  final String title;
  final String? originalTitle;
  final String? overview;
  final String? posterUrl;
  final String? backdropUrl;
  final String? releaseDate; // YYYY-MM-DD
  final int? runtime; // minutes
  final double? voteAverage;
  final List<String> genres;

  const TmdbMovie({
    required this.id,
    required this.title,
    this.originalTitle,
    this.overview,
    this.posterUrl,
    this.backdropUrl,
    this.releaseDate,
    this.runtime,
    this.voteAverage,
    this.genres = const [],
  });

  Map<String, Object?> toJson() => {
        'id': id,
        'title': title,
        'originalTitle': originalTitle,
        'overview': overview,
        'posterUrl': posterUrl,
        'backdropUrl': backdropUrl,
        'releaseDate': releaseDate,
        'runtime': runtime,
        'voteAverage': voteAverage,
        'genres': genres,
      };

  factory TmdbMovie.fromJson(Map<String, dynamic> json) => TmdbMovie(
        id: (json['id'] as num).toInt(),
        title: (json['title'] as String?) ?? '',
        originalTitle: json['originalTitle'] as String?,
        overview: json['overview'] as String?,
        posterUrl: json['posterUrl'] as String?,
        backdropUrl: json['backdropUrl'] as String?,
        releaseDate: json['releaseDate'] as String?,
        runtime: (json['runtime'] as num?)?.toInt(),
        voteAverage: (json['voteAverage'] as num?)?.toDouble(),
        genres: ((json['genres'] as List?) ?? const [])
            .map((e) => e as String)
            .toList(),
      );

  /// Release year parsed from [releaseDate], if any.
  int? get year {
    final d = releaseDate;
    if (d == null || d.length < 4) return null;
    return int.tryParse(d.substring(0, 4));
  }
}
