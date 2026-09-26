import 'package:hls_remux/hls_remux.dart';

import '../storage/s3_signer.dart';
import '../torrent/local_file.dart';
import '../torrent/stream_id.dart';
import '../torrent/torrent_client.dart';

/// Resolves a stream id — `<hash>` or `<hash>.<index>` (see [StreamId]) — to
/// its file, once the file is finished. Per FILE: a season pack finishes (and
/// uploads) one episode at a time, so E01 is playable while the rest aren't.
///
/// With S3 ([signer] set) the source is the file's object, and only once it
/// has actually landed there. Without S3 it is the file on the local disk.
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

  /// Local lookup (see [localFileOf]) when there is no S3.
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
    if (info.percentDone < 1.0) return null;

    final signer = this.signer;
    if (signer == null) {
      final local = localFileOf(
        info,
        file,
        fallbackDir: downloadDir,
        incompleteDir: incompleteDir,
      );
      return local == null ? null : FileMediaSource(local.path);
    }
    if (!await signer.exists(file.name)) return null;
    return HttpMediaSource(
      await signer.presign(file.name), // name == S3 key
      label: file.name,
      expiresAt: DateTime.now().add(ttl),
    );
  }
}
