/// Live state of a torrent in the client, polled by the library screen.
/// Mirrors the subset of Transmission `torrent-get` fields we care about.
class TorrentState {
  final String hashString;
  final String name;
  final double percentDone; // 0.0 .. 1.0
  final int status; // Transmission status code (4 = downloading, 6 = seeding)
  final int eta; // seconds, -1 if unknown
  final int rateDownload; // bytes/s
  final int rateUpload; // bytes/s
  final int uploadedEver; // bytes sent to peers since the torrent was added
  final int downloadedEver; // bytes fetched from peers since it was added
  final int totalSize; // bytes of the (wanted) content
  final bool isFinished;

  /// Ready to stream: the real gate for in-app HLS playback and the download
  /// link (the wire name predates local-only mode). With S3, the completed
  /// file has actually landed there — false while downloading AND during the
  /// upload window after 100% (backend computes it; Transmission never reports
  /// it). Without S3, simply "download complete".
  final bool onS3;

  /// Fraction (0.0 .. 1.0) of the S3 upload done, during the window after 100%
  /// download and before [onS3] flips true. 0 when not uploading. Drives the
  /// second progress bar in the library.
  final double uploadProgress;

  /// How many of the torrent's video files are on neither S3 nor the download
  /// disk, and so can never be uploaded. Their local copies were freed before
  /// their upload had landed, which nothing but re-downloading undoes — the
  /// torrent can never reach [onS3]. 0 for every healthy torrent.
  final int strandedFiles;

  /// The in-app player can start: on S3, or while downloading once a video
  /// file's first and last pieces are in (all that building its HLS session
  /// reads). The library's Play gate; backend-computed.
  final bool playable;

  /// How many video files the torrent holds: what its file list shows. More
  /// than one (a season pack) and the library opens that list rather than
  /// acting on a single file. 0 when unknown (metadata not fetched yet).
  final int videoCount;

  const TorrentState({
    required this.hashString,
    required this.name,
    this.percentDone = 0,
    this.status = 0,
    this.eta = -1,
    this.rateDownload = 0,
    this.rateUpload = 0,
    this.uploadedEver = 0,
    this.downloadedEver = 0,
    this.totalSize = 0,
    this.isFinished = false,
    this.onS3 = false,
    this.uploadProgress = 0,
    this.strandedFiles = 0,
    this.playable = false,
    this.videoCount = 0,
  });

  /// Bytes fully present locally (Transmission's view). NB: this is NOT the
  /// playable/downloadable gate — that's [onS3]. Between 100% downloaded and
  /// the rclone flush to S3 there's a multi-minute window where [isReady] is
  /// true but [onS3] is still false.
  bool get isReady => isFinished || percentDone >= 1.0;

  /// Denominator for [ratio]: the content size, matching what Transmission
  /// itself divides by (`uploadedEver / sizeWhenDone`, verified against live
  /// RPC data). It does NOT use `downloadedEver` — that field is 0 for every
  /// torrent added onto data already on disk (cross-seeds) and would leave most
  /// ratios undefined. Falls back to `downloadedEver` only if the size is
  /// missing, so the number can never be silently divided by zero.
  int get ratioBase => totalSize > 0 ? totalSize : downloadedEver;

  /// Share ratio, or `null` when there's nothing to divide by yet. Computed
  /// here rather than read from Transmission's `uploadRatio`, which uses -1/-2
  /// sentinels for NA/infinite.
  double? get ratio => ratioBase > 0 ? uploadedEver / ratioBase : null;

  TorrentState copyWith({
    bool? onS3,
    double? uploadProgress,
    int? strandedFiles,
    bool? playable,
    int? videoCount,
  }) => TorrentState(
    hashString: hashString,
    name: name,
    percentDone: percentDone,
    status: status,
    eta: eta,
    rateDownload: rateDownload,
    rateUpload: rateUpload,
    uploadedEver: uploadedEver,
    downloadedEver: downloadedEver,
    totalSize: totalSize,
    isFinished: isFinished,
    onS3: onS3 ?? this.onS3,
    uploadProgress: uploadProgress ?? this.uploadProgress,
    strandedFiles: strandedFiles ?? this.strandedFiles,
    playable: playable ?? this.playable,
    videoCount: videoCount ?? this.videoCount,
  );

  factory TorrentState.fromJson(Map<String, dynamic> json) => TorrentState(
    hashString: json['hashString'] as String? ?? '',
    name: json['name'] as String? ?? '',
    percentDone: (json['percentDone'] as num?)?.toDouble() ?? 0,
    status: (json['status'] as num?)?.toInt() ?? 0,
    eta: (json['eta'] as num?)?.toInt() ?? -1,
    rateDownload: (json['rateDownload'] as num?)?.toInt() ?? 0,
    rateUpload: (json['rateUpload'] as num?)?.toInt() ?? 0,
    uploadedEver: (json['uploadedEver'] as num?)?.toInt() ?? 0,
    downloadedEver: (json['downloadedEver'] as num?)?.toInt() ?? 0,
    totalSize: (json['totalSize'] as num?)?.toInt() ?? 0,
    isFinished: json['isFinished'] as bool? ?? false,
    onS3: json['onS3'] as bool? ?? false,
    uploadProgress: (json['uploadProgress'] as num?)?.toDouble() ?? 0,
    strandedFiles: (json['strandedFiles'] as num?)?.toInt() ?? 0,
    playable: json['playable'] as bool? ?? false,
    videoCount: (json['videoCount'] as num?)?.toInt() ?? 0,
  );

  Map<String, dynamic> toJson() => {
    'hashString': hashString,
    'name': name,
    'percentDone': percentDone,
    'status': status,
    'eta': eta,
    'rateDownload': rateDownload,
    'rateUpload': rateUpload,
    'uploadedEver': uploadedEver,
    'downloadedEver': downloadedEver,
    'totalSize': totalSize,
    'isFinished': isFinished,
    'onS3': onS3,
    'uploadProgress': uploadProgress,
    'strandedFiles': strandedFiles,
    'playable': playable,
    'videoCount': videoCount,
  };
}
