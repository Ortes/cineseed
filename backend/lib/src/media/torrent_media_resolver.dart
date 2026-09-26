import 'package:cineseed_streaming/cineseed_streaming.dart';

import '../storage/s3_signer.dart';
import '../torrent/stream_id.dart';
import '../torrent/torrent_client.dart';

/// Resolves a stream id — `<hash>` or `<hash>.<index>` (see [StreamId]) — to
/// its file's S3 object.
///
/// HLS only for finished files that have actually landed on S3. Per FILE: a
/// season pack uploads one episode at a time, so E01 is playable while the
/// rest are still going up.
class TorrentMediaResolver implements MediaSourceResolver {
  TorrentMediaResolver({
    required this.client,
    required this.signer,
    required this.ttl,
  });

  final TorrentClient client;
  final S3Signer signer;

  /// Lifetime of the presigned URLs [S3Signer.presign] hands out.
  final Duration ttl;

  @override
  Future<MediaSource?> resolve(String id) async {
    final sid = StreamId.parse(id);
    if (sid == null) return null; // malformed id names no file
    final info = await client.streamInfo(sid.hash);
    if (info == null || info.files.isEmpty) return null;
    final index = sid.resolve(info.files);
    if (index == null) return null; // no such file in this torrent
    final file = info.files[index];
    if (info.percentDone < 1.0 || !await signer.exists(file.name)) return null;
    return HttpMediaSource(
      await signer.presign(file.name), // name == S3 key
      label: file.name,
      expiresAt: DateTime.now().add(ttl),
    );
  }
}
