import 'media_type.dart';

/// A search hit from a tracker (Torznab). The backend builds it from the RSS
/// feed; the frontend renders it in the search list. `infoHash` is all the
/// backend needs to later fetch the `.torrent` and add it to the client.
class TorrentResult {
  final String title;
  final String infoHash;
  final int? tmdbId;

  /// Movie vs TV vs other, from the tracker's Torznab category. Determines
  /// which TMDB endpoint (`/movie` vs `/tv`) resolves [tmdbId].
  final MediaType mediaType;
  final int seeders;
  final int leechers;
  final int grabs;
  final int size; // bytes
  final DateTime? pubDate;

  const TorrentResult({
    required this.title,
    required this.infoHash,
    this.tmdbId,
    this.mediaType = MediaType.other,
    this.seeders = 0,
    this.leechers = 0,
    this.grabs = 0,
    this.size = 0,
    this.pubDate,
  });

  factory TorrentResult.fromJson(Map<String, dynamic> json) => TorrentResult(
        title: json['title'] as String? ?? '',
        infoHash: json['infoHash'] as String? ?? '',
        tmdbId: (json['tmdbId'] as num?)?.toInt(),
        mediaType: MediaType.fromJson(json['mediaType'] as String?),
        seeders: (json['seeders'] as num?)?.toInt() ?? 0,
        leechers: (json['leechers'] as num?)?.toInt() ?? 0,
        grabs: (json['grabs'] as num?)?.toInt() ?? 0,
        size: (json['size'] as num?)?.toInt() ?? 0,
        pubDate: switch (json['pubDate']) {
          final String s when s.isNotEmpty => DateTime.tryParse(s),
          _ => null,
        },
      );

  Map<String, dynamic> toJson() => {
        'title': title,
        'infoHash': infoHash,
        'tmdbId': tmdbId,
        'mediaType': mediaType.toJson(),
        'seeders': seeders,
        'leechers': leechers,
        'grabs': grabs,
        'size': size,
        'pubDate': pubDate?.toIso8601String(),
      };
}
