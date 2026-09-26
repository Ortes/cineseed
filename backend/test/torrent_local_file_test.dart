import 'dart:io';
import 'dart:typed_data';

import 'package:cineseed_backend/cineseed_backend.dart';
import 'package:cineseed_backend/src/torrent/torrent_local_file.dart';
import 'package:test/test.dart';

/// A torrent whose verified pieces are [have]; counts the bitfield fetches.
class _Pieces implements TorrentClient {
  _Pieces(this.have, this.count);
  Set<int> have;
  final int count;
  int fetches = 0;

  @override
  Future<TorrentPieces?> pieces(String hash) async {
    fetches++;
    final bits = Uint8List((count + 7) ~/ 8);
    for (final i in have) {
      bits[i >> 3] |= 0x80 >> (i & 7);
    }
    return TorrentPieces(bits, 16384);
  }

  @override
  dynamic noSuchMethod(Invocation i) => throw UnimplementedError('$i');
}

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('tlf_');
    File('${dir.path}/b.mkv.part').createSync(); // still downloading
  });
  tearDown(() => dir.delete(recursive: true));

  // Two files: a (10 000 B) then b (50 000 B), 16 KiB pieces. b spans torrent
  // bytes 10 000..59 999 = pieces 0..3, its last piece cut short at 59 999.
  TorrentStreamInfo info() => TorrentStreamInfo(
    name: 'pack',
    downloadDir: dir.path,
    percentDone: 0.5,
    isFinished: false,
    files: const [
      TorrentFile('a.nfo', 10000, 0),
      TorrentFile('b.mkv', 50000, 0),
    ],
  );

  TorrentLocalFile find(TorrentClient c) =>
      TorrentLocalFile.find(c, 'h', info(), 1, fallbackDir: dir.path)!;

  test('readable runs to the first missing piece, in file offsets', () async {
    final f = find(_Pieces({0, 1, 3}, 4));
    expect(f.length, 50000);
    expect(await f.readable(0), 2 * 16384 - 10000); // up to piece 2
    expect(await f.readable(22767), 1);
    expect(await f.readable(22768), 0); // piece 2 isn't there
    expect(await f.readable(49999), 1); // last byte, in the short last piece
    expect(await f.readable(50000), 0); // past the end
  });

  test('once every piece is in, no more bitfield fetches', () async {
    final c = _Pieces({0, 1, 2, 3}, 4);
    final f = find(c);
    expect(await f.readable(0), 50000);
    await Future<void>.delayed(const Duration(milliseconds: 1100));
    expect(await f.readable(100), 49900);
    expect(c.fetches, 1);
  });

  test('path follows the .part rename', () {
    final f = find(_Pieces({}, 4));
    expect(f.path(), '${dir.path}/b.mkv.part');
    File('${dir.path}/b.mkv.part').renameSync('${dir.path}/b.mkv');
    expect(f.path(), '${dir.path}/b.mkv');
    File('${dir.path}/b.mkv').deleteSync();
    expect(f.path(), isNull);
  });

  test('nothing under the remote dir counts as local', () {
    expect(
      TorrentLocalFile.find(
        _Pieces({}, 4),
        'h',
        info(),
        1,
        fallbackDir: dir.path,
        remoteDir: dir.path,
      ),
      isNull,
    );
  });
}
