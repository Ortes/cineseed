import 'package:minio/minio.dart';
import 'package:minio/io.dart';

import 'stall_watchdog.dart';

/// Signs short-lived presigned GET URLs for objects in the S3 bucket.
/// The `<video>` element fetches these directly (Range requests) — the backend
/// never proxies bytes.
class S3Signer {
  final Minio _minio;
  final String bucket;
  final int defaultTtl;

  /// How long an upload may report no progress at all before it's declared
  /// stalled. Parts are 64 MiB and progress ticks every 64 KiB while the body
  /// goes out, so the only quiet stretch in a healthy upload is the wait for a
  /// part's response — seconds, not minutes.
  final Duration uploadStallTimeout;

  S3Signer({
    required String endpoint,
    required String region,
    required this.bucket,
    required String accessKey,
    required String secretKey,
    this.defaultTtl = 21600,
    this.uploadStallTimeout = const Duration(seconds: 60),
  }) : _minio = Minio(
         endPoint: endpoint,
         accessKey: accessKey,
         secretKey: secretKey,
         region: region,
         useSSL: true,
       );

  Future<String> presign(String key, {int? ttl}) =>
      _minio.presignedGetObject(bucket, key, expires: ttl ?? defaultTtl);

  /// Uploads a local file to [key] (multipart, streamed from disk). [onProgress]
  /// is called with the cumulative bytes uploaded as the transfer proceeds.
  ///
  /// Throws [TimeoutException] if the transfer goes quiet for
  /// [uploadStallTimeout]. S3 does sometimes swallow a part outright: it takes
  /// the whole 64 MiB body, ACKs every byte, then never answers. minio-dart
  /// sends each request through `BaseRequest.send()`, whose `HttpClient` has no
  /// response timeout, so without this that `await` would never return — and
  /// since the caller only releases its in-flight latch on error, the torrent
  /// would sit at a frozen percentage for the life of the process, never
  /// retried and never freed from the download disk.
  ///
  /// The stalled request itself can't be cancelled — `send()` creates and owns
  /// the underlying client — so it leaks its socket and its 64 MiB chunk until
  /// the process exits. That's the cost of failing instead of hanging forever.
  Future<void> putFile(
    String key,
    String filePath, {
    void Function(int)? onProgress,
  }) => awaitProgress(
    stallTimeout: uploadStallTimeout,
    what: 'S3 upload of $key',
    onProgress: onProgress,
    run: (progress) =>
        _minio.fPutObject(bucket, key, filePath, onProgress: progress),
  );

  /// Like [presign] but the URL forces a download instead of inline playback.
  /// S3 echoes the `response-content-disposition` param back as the
  /// `Content-Disposition` header on the response.
  Future<String> presignDownload(String key, {int? ttl}) {
    final filename = key.split('/').last;
    return _minio.presignedGetObject(
      bucket,
      key,
      expires: ttl ?? defaultTtl,
      respHeaders: {
        'response-content-disposition': 'attachment; filename="$filename"',
      },
    );
  }

  /// True if the object is actually in the bucket. Transmission can report a
  /// torrent as 100% done *before* rclone has flushed the completed file from
  /// its local VFS cache up to S3 (the object is immutable, so it only appears
  /// on close/writeback). Until then a presigned URL would 404 — callers should
  /// fall back to serving the local file.
  Future<bool> exists(String key) async {
    try {
      await _minio.statObject(bucket, key);
      return true;
    } catch (_) {
      return false;
    }
  }
}
