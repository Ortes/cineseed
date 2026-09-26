import 'package:cineseed_backend/src/torrent/stream_id.dart';
import 'package:cineseed_backend/src/torrent/torrent_client.dart';
import 'package:test/test.dart';

const _hash = 'a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2';

TorrentFile _f(String name, int length) => TorrentFile(name, length, 0);

/// A season pack: episodes in torrent order, plus the junk real packs carry.
final _pack = [
  _f('Show.S01/Show.S01E01.mkv', 2000),
  _f('Show.S01/Show.S01E02.mkv', 3000), // largest — the "primary" video
  _f('Show.S01/readme.nfo', 10),
  _f('Show.S01/Show.S01E03.mkv', 2500),
];

void main() {
  group('StreamId.parse', () {
    test('a bare hash addresses no particular file', () {
      final id = StreamId.parse(_hash)!;
      expect(id.hash, _hash);
      expect(id.fileIndex, isNull);
    });

    test('a .<index> suffix addresses one file', () {
      final id = StreamId.parse('$_hash.3')!;
      expect(id.hash, _hash);
      expect(id.fileIndex, 3);
    });

    test('rejects a suffix that is not a file index', () {
      // Rejected rather than read as a bare hash: a malformed id names no file,
      // and guessing would serve the wrong episode.
      expect(StreamId.parse('$_hash.x'), isNull);
      expect(StreamId.parse('$_hash.-1'), isNull);
      expect(StreamId.parse('$_hash.'), isNull);
    });

    test('round-trips through toString', () {
      expect(StreamId.parse('$_hash.2')!.toString(), '$_hash.2');
      expect(StreamId.parse(_hash)!.toString(), _hash);
    });
  });

  group('StreamId.resolve', () {
    test('a bare hash resolves to the largest video', () {
      expect(StreamId.parse(_hash)!.resolve(_pack), 1);
    });

    test('an explicit index resolves to that file, whatever its size', () {
      expect(StreamId.parse('$_hash.0')!.resolve(_pack), 0);
      expect(StreamId.parse('$_hash.3')!.resolve(_pack), 3);
    });

    test('an out-of-range index resolves to nothing', () {
      // Not clamped to the primary video: serving a different episode than the
      // one requested would look like a playback bug, not a bad link.
      expect(StreamId.parse('$_hash.4')!.resolve(_pack), isNull);
      expect(StreamId.parse('$_hash.0')!.resolve(const []), isNull);
    });
  });

  group('videoFileIndices', () {
    test('keeps torrent (episode) order and drops non-video files', () {
      expect(videoFileIndices(_pack), [0, 1, 3]);
    });

    test('falls back to every file when nothing looks like video', () {
      final files = [_f('disc/VIDEO_TS.IFO', 10), _f('disc/VTS_01_1.VOB', 900)];
      expect(videoFileIndices(files), [0, 1]);
      expect(primaryVideoIndex(files), 1); // largest
    });
  });
}
