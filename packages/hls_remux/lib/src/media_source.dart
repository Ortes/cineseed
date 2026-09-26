import 'dart:io';

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

/// A file on local disk, served on loopback by `LocalRangeServer` (no cache:
/// the page cache already does that job). It may still be downloading: see
/// [LocalFile].
final class FileMediaSource extends MediaSource {
  /// A file that is already complete at [path].
  FileMediaSource(String path) : this.of(CompleteFile(path), label: path);

  const FileMediaSource.of(this.file, {required String label}) : super(label);

  final LocalFile file;
}

/// A local file as `LocalRangeServer` reads it. While it downloads, reads may
/// only go as far as [readable] says, and the file may move (a `.part` rename
/// on completion) or disappear (freed once uploaded): [path] says where it is
/// now.
abstract interface class LocalFile {
  /// Final size in bytes. The file on disk may be sparse or shorter until then.
  int get length;

  /// Where the file is now, or null once it is gone.
  String? path();

  /// How many bytes from [offset] can be read now; 0 if they aren't there yet.
  Future<int> readable(int offset);
}

/// A [LocalFile] that is complete on disk.
final class CompleteFile implements LocalFile {
  CompleteFile(this._path);

  final String _path;

  @override
  late final int length = File(_path).lengthSync();

  @override
  String? path() => File(_path).existsSync() ? _path : null;

  @override
  Future<int> readable(int offset) async => length - offset;
}

/// Maps a stream id to its source. The id is opaque to this package: it is
/// only handed back here and used as a cache key.
abstract interface class MediaSourceResolver {
  /// The source for [id], or null when it isn't playable as HLS (unknown id,
  /// not downloaded far enough yet, …).
  Future<MediaSource?> resolve(String id);
}
