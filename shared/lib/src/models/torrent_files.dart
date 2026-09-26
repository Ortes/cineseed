/// One video file inside a torrent, as listed by `/api/torrents/<hash>/files`.
class TorrentFileInfo {
  /// Position in the torrent's OWN file list — not in this (video-only) list.
  /// This is the file's stable identity: it is the `<index>` in the stream id
  /// `<hash>.<index>` that addresses the file on every other route.
  final int index;

  /// Path inside the torrent, e.g. `Show.S01.1080p/Show.S01E02.1080p.mkv`.
  /// Also the S3 object key once uploaded.
  final String name;

  final int length; // bytes
  final int bytesCompleted; // bytes downloaded so far

  /// Whether THIS file has landed on S3 — the gate for in-app playback, Cast
  /// and download. A season pack uploads one file at a time, so early episodes
  /// become playable while the later ones are still going up.
  final bool onS3;

  const TorrentFileInfo({
    required this.index,
    required this.name,
    this.length = 0,
    this.bytesCompleted = 0,
    this.onS3 = false,
  });

  /// Basename — the picker lists episodes, not paths.
  String get displayName => name.split('/').last;

  double get percentDone => length > 0 ? bytesCompleted / length : 0;

  /// Sequential download fills the torrent front-to-back, so any downloaded
  /// bytes of this file are a contiguous prefix — enough for VLC to start.
  bool get hasBytes => bytesCompleted > 0;

  factory TorrentFileInfo.fromJson(Map<String, dynamic> json) =>
      TorrentFileInfo(
        index: (json['index'] as num?)?.toInt() ?? 0,
        name: json['name'] as String? ?? '',
        length: (json['length'] as num?)?.toInt() ?? 0,
        bytesCompleted: (json['bytesCompleted'] as num?)?.toInt() ?? 0,
        onS3: json['onS3'] as bool? ?? false,
      );

  Map<String, dynamic> toJson() => {
    'index': index,
    'name': name,
    'length': length,
    'bytesCompleted': bytesCompleted,
    'onS3': onS3,
  };
}

/// `/api/torrents/<hash>/files` — the torrent's video files plus the bit of
/// torrent-level state the file picker shows above them.
class TorrentFiles {
  final String name; // torrent name
  final double percentDone; // 0.0 .. 1.0, whole torrent
  final List<TorrentFileInfo> files;

  const TorrentFiles({
    this.name = '',
    this.percentDone = 0,
    this.files = const [],
  });

  /// A single-video torrent needs no picker — the caller plays [files].first
  /// straight away, exactly as before multi-file support existed.
  bool get isSingleFile => files.length <= 1;

  factory TorrentFiles.fromJson(Map<String, dynamic> json) => TorrentFiles(
    name: json['name'] as String? ?? '',
    percentDone: (json['percentDone'] as num?)?.toDouble() ?? 0,
    files: ((json['files'] as List?) ?? [])
        .map(
          (e) => TorrentFileInfo.fromJson((e as Map).cast<String, dynamic>()),
        )
        .toList(),
  );

  Map<String, dynamic> toJson() => {
    'name': name,
    'percentDone': percentDone,
    'files': files.map((f) => f.toJson()).toList(),
  };
}
