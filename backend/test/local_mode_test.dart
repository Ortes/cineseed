import 'dart:convert';
import 'dart:io';

import 'package:cineseed_backend/cineseed_backend.dart';
import 'package:test/test.dart';

/// One finished single-file torrent at [dir]/film.mkv.
class _Finished implements TorrentClient {
  _Finished(this.dir, this.length);
  final String dir;
  final int length;

  @override
  Future<List<TorrentState>> list() async => [
    const TorrentState(hashString: 'h1', name: 'film.mkv', percentDone: 1.0),
  ];
  @override
  Future<TorrentStreamInfo?> streamInfo(String hash) async => hash != 'h1'
      ? null
      : TorrentStreamInfo(
          name: 'film.mkv',
          downloadDir: dir,
          percentDone: 1.0,
          isFinished: false,
          files: [TorrentFile('film.mkv', length, length)],
        );
  @override
  Future<List<TorrentFile>> files(String hash) async => [];
  @override
  Future<void> addTorrent(List<int> m, {bool paused = false}) async {}
  @override
  Future<void> start(String hash) async {}
  @override
  Future<void> stop(String hash) async {}
  @override
  Future<void> remove(String hash, {bool deleteData = false}) async {}
  @override
  Future<void> setLocation(String h, String l, {bool move = false}) =>
      throw StateError('no relocation without S3');
}

Map<String, String> _env([Map<String, String> extra = const {}]) => {
  'CINESEED_TRACKER_APIKEY': 'x',
  'CINESEED_TRACKER_BASEURL': 'http://127.0.0.1:9',
  'PORT': '0',
  'PUBLIC_DIR': '/nonexistent',
  'HLS_PRODUCER_TEMP': '${Directory.systemTemp.path}/local_mode_hls',
  ...extra,
};

void main() {
  group('S3 config', () {
    test('no S3 variables → local-only storage', () {
      expect(Config.fromEnv(_env()).s3, isNull);
    });

    test('a partial set refuses to boot and names what is missing', () {
      expect(
        () => Config.fromEnv(_env({'S3_ENDPOINT': 'e', 'S3_BUCKET': 'b'})),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(contains('S3_ACCESS_KEY'), contains('S3_SECRET_KEY')),
          ),
        ),
      );
    });

    test('the full set, region defaulting to us-east-1', () {
      final s3 = Config.fromEnv(
        _env({
          'S3_ENDPOINT': 'e',
          'S3_BUCKET': 'b',
          'S3_ACCESS_KEY': 'a',
          'S3_SECRET_KEY': 's',
        }),
      ).s3!;
      expect((s3.bucket, s3.region), ('b', 'us-east-1'));
    });
  });

  group('local-only mode', () {
    late Directory dir;
    late File mkv;
    late CineseedServer server;
    late String base;
    final http = HttpClient();

    setUpAll(() async {
      dir = await Directory.systemTemp.createTemp('local_mode_');
      mkv = File('${dir.path}/film.mkv');
      final r = await Process.run(
        'ffmpeg',
        '-v error -y -f lavfi -i testsrc=duration=12:size=160x120:rate=24 '
                '-f lavfi -i sine=duration=12 -c:v mpeg4 -g 24 -c:a aac '
                '${mkv.path}'
            .split(' '),
      );
      if (r.exitCode != 0) fail('ffmpeg: ${r.stderr}');
      server = await startServer(
        Config.fromEnv(_env()),
        client: _Finished(dir.path, mkv.lengthSync()),
      );
      base = 'http://127.0.0.1:${server.http.port}/api';
    });

    tearDownAll(() async {
      http.close(force: true);
      await server.close();
      await dir.delete(recursive: true);
    });

    Future<HttpClientResponse> get(String url, {String? range}) async {
      final req = await http.getUrl(Uri.parse(url));
      if (range != null) req.headers.set(HttpHeaders.rangeHeader, range);
      return req.close();
    }

    Future<Object?> json(String url) async =>
        jsonDecode(await (await get(url)).transform(utf8.decoder).join());

    test('a finished torrent is ready to stream, with no upload', () async {
      final t = (await json('$base/torrents') as List).single as Map;
      expect(t['onS3'], isTrue); // "ready to stream" without S3
      expect(t['uploadProgress'], 0);
      expect(t['strandedFiles'], 0);
    });

    test('stream goes to the local file route', () async {
      final s = await json('$base/stream/h1') as Map;
      expect(s['mode'], 'local');
      expect(s['ready'], isTrue); // the in-app player's gate
      expect(s['url'], endsWith('/api/file/h1'));
    });

    test('download is the whole file as an attachment', () async {
      final d = await json('$base/download/h1') as Map;
      final res = await get(d['url'] as String);
      expect(res.statusCode, 200);
      expect(res.headers.value('content-disposition'), contains('film.mkv'));
      final body = await res.fold<int>(0, (n, c) => n + c.length);
      expect(body, mkv.lengthSync());
    });

    test('ranged reads of the local file stay 206', () async {
      final res = await get('$base/file/h1', range: 'bytes=0-9');
      expect(res.statusCode, 206);
      expect(
        res.headers.value('content-range'),
        'bytes 0-9/${mkv.lengthSync()}',
      );
      await res.drain<void>();
    });

    test('HLS plays from the local disk', () async {
      final master = await (await get(
        '$base/hls/h1/master.m3u8',
      )).transform(utf8.decoder).join();
      expect(master, contains('m/0/index.m3u8'));
      final init = await get('$base/hls/h1/m/0/init.mp4');
      expect(init.statusCode, 200);
      final seg = await get('$base/hls/h1/m/0/1.m4s');
      expect(seg.statusCode, 200);
      final out = File('${dir.path}/seg.mp4').openWrite();
      await out.addStream(init);
      await out.addStream(seg);
      await out.close();
      final probe = await Process.run('ffprobe', [
        '-v',
        'error',
        '-show_entries',
        'stream=codec_type',
        '-of',
        'csv=p=0',
        '${dir.path}/seg.mp4',
      ]);
      expect(probe.stdout.toString().trim().split('\n'), ['video', 'audio']);
    });
  });
}
