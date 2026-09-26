/// Where a stream's bytes come from. Returned by a [MediaSourceResolver].
sealed class MediaSource {
  const MediaSource(this.label);

  /// What to call the source in logs (an object key, a file name). Never a
  /// presigned URL: those carry credentials.
  final String label;
}

/// A URL that answers HTTP Range requests, e.g. an S3 presigned GET. Read
/// through the caching `S3RangeProxy`, and re-resolved shortly before
/// [expiresAt] (null: never expires).
final class HttpMediaSource extends MediaSource {
  const HttpMediaSource(this.url, {required String label, this.expiresAt})
    : super(label);

  final String url;
  final DateTime? expiresAt;
}

/// A complete file on local disk, served on loopback by `LocalRangeServer`
/// (no cache: the page cache already does that job).
final class FileMediaSource extends MediaSource {
  const FileMediaSource(this.path) : super(path);

  final String path;
}

/// Maps a stream id to its source. The id is opaque to this package: it is
/// only handed back here and used as a cache key.
abstract interface class MediaSourceResolver {
  /// The source for [id], or null when it isn't playable as HLS (unknown id,
  /// not complete yet, …).
  Future<MediaSource?> resolve(String id);
}
