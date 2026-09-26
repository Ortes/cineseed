import 'dart:typed_data';

import 'package:cineseed_shared/cineseed_shared.dart';

/// One file inside a torrent (subset of Transmission `files` fields).
class TorrentFile {
  final String name;
  final int length;
  final int bytesCompleted;
  const TorrentFile(this.name, this.length, this.bytesCompleted);
}

/// Everything `/api/stream` and `/api/file` need to decide S3-vs-local and to
/// serve the local file with byte-accurate Range responses.
class TorrentStreamInfo {
  final String name; // torrent top-level name
  final String downloadDir; // Transmission's per-torrent download dir
  final double percentDone;
  final bool isFinished;
  final List<TorrentFile> files;
  const TorrentStreamInfo({
    required this.name,
    required this.downloadDir,
    required this.percentDone,
    required this.isFinished,
    required this.files,
  });
}

/// The pieces a torrent has verified: bit `i` of [bits] (MSB first, the
/// BitTorrent bitfield layout) is set once piece `i` passed its hash check.
class TorrentPieces {
  final Uint8List bits;
  final int pieceSize;
  const TorrentPieces(this.bits, this.pieceSize);

  bool has(int piece) => (bits[piece >> 3] & (0x80 >> (piece & 7))) != 0;
}

/// Abstract torrent client. Transmission is the only implementation for now;
/// qBittorrent/Deluge could be added later without touching the routes/UI.
abstract interface class TorrentClient {
  Future<void> addTorrent(List<int> metainfo, {bool paused = false});
  Future<List<TorrentState>> list();
  Future<List<TorrentFile>> files(String hash);

  /// Torrent-level + per-file progress for the streaming decision. `null` if
  /// the torrent is unknown.
  Future<TorrentStreamInfo?> streamInfo(String hash);

  /// Which pieces are verified, to read a file while it downloads. `null` if
  /// the torrent is unknown.
  Future<TorrentPieces?> pieces(String hash);
  Future<void> start(String hash);
  Future<void> stop(String hash);
  Future<void> remove(String hash, {bool deleteData = false});

  /// Repoint the torrent at [location] without moving data (`move: false` tells
  /// Transmission the files are *already* there). Used to hand a finished
  /// torrent over to the S3-backed mount once its object has landed on S3.
  Future<void> setLocation(String hash, String location, {bool move = false});
}
