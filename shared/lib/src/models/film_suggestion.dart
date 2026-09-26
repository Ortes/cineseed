import 'tmdb_movie.dart';
import 'torrent_result.dart';

/// One film of `/api/suggestions`: its TMDB metadata (which carries the
/// rating the list is sorted by) and its releases among the tracker's latest.
class FilmSuggestion {
  final TmdbMovie movie;
  final List<TorrentResult> releases;

  const FilmSuggestion({required this.movie, required this.releases});

  Map<String, Object?> toJson() => {
    'movie': movie.toJson(),
    'releases': releases.map((r) => r.toJson()).toList(),
  };

  factory FilmSuggestion.fromJson(Map<String, dynamic> json) => FilmSuggestion(
    movie: TmdbMovie.fromJson((json['movie'] as Map).cast<String, dynamic>()),
    releases: (json['releases'] as List)
        .map((e) => TorrentResult.fromJson((e as Map).cast<String, dynamic>()))
        .toList(),
  );
}
