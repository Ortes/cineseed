import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:hls_remux/hls_remux.dart';

import 'local_file.dart';
import 'torrent_client.dart';

/// A torrent's file on the local download disk, read while it downloads. Only
/// pieces Transmission has verified are readable: with sequential download it
/// writes a piece to disk before reporting it. The file may be renamed from
/// `.part` or moved out of the incomplete dir on completion, so [path] checks
/// every local location each time.
class TorrentLocalFile implements LocalFile {
  TorrentLocalFile._(
    this._client,
    this._hash,
    this._offset,
    this.length,
    this._paths,
  );

  /// File [index] of [info] if it is on the local disk, else null. Nothing
  /// under [remoteDir] (the post-upload dir, an rclone mount of the bucket)
  /// counts as local: reads through it are what the local copy avoids.
  static TorrentLocalFile? find(
    TorrentClient client,
    String hash,
    TorrentStreamInfo info,
    int index, {
    required String fallbackDir,
    String incompleteDir = '',
    String? remoteDir,
  }) {
    final remote = remoteDir == null
        ? null
        : (remoteDir.endsWith('/') ? remoteDir : '$remoteDir/');
    final paths = [
      for (final p in localPathsOf(
        info,
        info.files[index],
        fallbackDir: fallbackDir,
        incompleteDir: incompleteDir,
      ))
        if (remote == null || !p.startsWith(remote)) p,
    ];
    if (!paths.any((p) => File(p).existsSync())) return null;
    var offset = 0;
    for (var i = 0; i < index; i++) {
      offset += info.files[i].length;
    }
    return TorrentLocalFile._(
      client,
      hash,
      offset,
      info.files[index].length,
      paths,
    );
  }

  final TorrentClient _client;
  final String _hash;
  final int _offset; // where the file starts in the torrent's byte stream
  final List<String> _paths;

  @override
  final int length;

  TorrentPieces? _pieces;
  DateTime _fetchedAt = DateTime(0);
  Future<TorrentPieces?>? _fetching;
  bool _complete = false; // latched: no more RPCs once every piece is in

  /// Whether [p] has everything building this file's HLS session reads before
  /// it can wait for pieces: the first piece (header, SeekHead) and the Cues,
  /// wherever the SeekHead puts them — not always within the last piece, which
  /// can be only a few KB long.
  Future<bool> hasIndex(TorrentPieces p) async {
    if (!p.has(_offset ~/ p.pieceSize)) return false;
    final cues = await MkvCues.locate((offset, length) async {
      final n = min(length, _readableIn(p, offset));
      final path = this.path();
      if (n <= 0 || path == null) return Uint8List(0);
      final f = await File(path).open();
      try {
        await f.setPosition(offset);
        return await f.read(n);
      } finally {
        await f.close();
      }
    });
    return cues != null && _readableIn(p, cues.start) >= cues.end - cues.start;
  }

  @override
  String? path() {
    for (final p in _paths) {
      if (File(p).existsSync()) return p;
    }
    return null;
  }

  @override
  Future<int> readable(int offset) async {
    if (offset >= length) return 0;
    if (_complete) return length - offset;
    final pieces = await _fresh();
    if (pieces == null) return 0; // torrent removed: nothing verified to read
    return _readableIn(pieces, offset);
  }

  /// How many bytes from [offset] on are in verified pieces of [pieces].
  int _readableIn(TorrentPieces pieces, int offset) {
    if (offset >= length) return 0;
    final size = pieces.pieceSize;
    final last = (_offset + length - 1) ~/ size;
    var i = (_offset + offset) ~/ size;
    while (i <= last && pieces.has(i)) {
      i++;
    }
    if (i > last) return length - offset;
    return max(0, i * size - _offset - offset);
  }

  /// The bitfield, fetched at most once a second: every waiting read polls it.
  Future<TorrentPieces?> _fresh() async {
    if (DateTime.now().difference(_fetchedAt) < const Duration(seconds: 1)) {
      return _pieces;
    }
    final pieces = await (_fetching ??= _client
        .pieces(_hash)
        .whenComplete(() => _fetching = null));
    _pieces = pieces;
    _fetchedAt = DateTime.now();
    if (pieces != null) _complete = _hasAll(pieces);
    return pieces;
  }

  bool _hasAll(TorrentPieces p) {
    final size = p.pieceSize;
    for (var i = _offset ~/ size; i <= (_offset + length - 1) ~/ size; i++) {
      if (!p.has(i)) return false;
    }
    return true;
  }
}
