import 'package:hls_remux/hls_remux.dart';

import '../storage/s3_signer.dart';
import '../torrent/local_file.dart';
import '../torrent/stream_id.dart';
import '../torrent/torrent_client.dart';
import '../torrent/torrent_local_file.dart';

/// Resolves a stream id — `<hash>` or `<hash>.<index>` (see [StreamId]) — to
/// its file. Per FILE: each episode of a season pack is its own source.
///
/// With S3 ([signer] set), a finished file whose object has landed there plays
/// from S3. Otherwise it plays from the local disk as soon as it is there, even
/// mid-download: [TorrentLocalFile] only lets reads through verified pieces.
class TorrentMediaResolver implements MediaSourceResolver {
  TorrentMediaResolver({
    required this.client,
    required this.signer,
    required this.ttl,
    required this.downloadDir,
    this.incompleteDir = '',
  });

  final TorrentClient client;
  final S3Signer? signer;

  /// Lifetime of the presigned URLs [S3Signer.presign] hands out.
  final Duration ttl;

  /// Local lookup (see [localPathsOf]). With S3 it is the post-upload dir (an
  /// rclone mount of the bucket), which is never read as a local file.
  final String downloadDir;
  final String incompleteDir;

  @override
  Future<MediaSource?> resolve(String id) async {
    final sid = StreamId.parse(id);
    if (sid == null) return null; // malformed id names no file
    final info = await client.streamInfo(sid.hash);
    if (info == null || info.files.isEmpty) return null;
    final index = sid.resolve(info.files);
    if (index == null) return null; // no such file in this torrent
    final file = info.files[index];

    final signer = this.signer;
    if (signer != null &&
        info.percentDone >= 1.0 &&
        await signer.exists(file.name)) {
      return HttpMediaSource(
        await signer.presign(file.name), // name == S3 key
        label: file.name,
        expiresAt: DateTime.now().add(ttl),
      );
    }
    final local = TorrentLocalFile.find(
      client,
      sid.hash,
      info,
      index,
      fallbackDir: downloadDir,
      incompleteDir: incompleteDir,
      remoteDir: signer == null ? null : downloadDir,
    );
    return local == null
        ? null
        : FileMediaSource.of(local, label: local.path() ?? file.name);
  }
}
