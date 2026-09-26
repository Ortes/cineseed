import 'dart:io';

import 'package:hls_remux/hls_remux.dart';
import 'package:test/test.dart';

/// Resolves every id to one local file.
class _OneFile implements MediaSourceResolver {
  _OneFile(this.path);
  final String path;
  final resolved = <String>[];

  @override
  Future<MediaSource?> resolve(String id) async {
    resolved.add(id);
    return id == 'film' ? FileMediaSource(path) : null;
  }
}

/// The file on local disk until [freed], then only at [remote] — like a film
/// uploaded to S3 and its local copy deleted.
class _Uploaded implements MediaSourceResolver, LocalFile {
  _Uploaded(this.local, this.remote);
  final String local;
  final String remote;
  bool freed = false;

  @override
  Future<MediaSource?> resolve(String id) async => freed
      ? HttpMediaSource(remote, label: 'remote', expiresAt: DateTime(2100))
      : FileMediaSource.of(this, label: local);

  @override
  late final int length = File(local).lengthSync();

  @override
  String? path() => freed ? null : local;

  @override
  Future<int> readable(int offset) async => length - offset;
}

void main() {
  late Directory dir;
  late String mkv;

  setUpAll(() async {
    dir = await Directory.systemTemp.createTemp('local_session_');
    mkv = '${dir.path}/film.mkv';
    // 6 s, a keyframe every second: enough for Cues and several segments.
    final r = await Process.run(
      'ffmpeg',
      '-v error -y -f lavfi -i testsrc=duration=6:size=160x120:rate=24 '
              '-f lavfi -i sine=duration=6 -c:v mpeg4 -g 24 -c:a aac $mkv'
          .split(' '),
    );
    if (r.exitCode != 0) fail('ffmpeg: ${r.stderr}');
  });

  tearDownAll(() => dir.delete(recursive: true));

  test(
    'a FileMediaSource builds a session through the loopback server',
    () async {
      final proxy = S3RangeProxy();
      final files = LocalRangeServer();
      await proxy.start();
      await files.start();
      addTearDown(() async {
        await proxy.stop();
        await files.stop();
      });
      final resolver = _OneFile(mkv);
      final hls = HlsSessionManager(
        resolver: resolver,
        proxy: proxy,
        localFiles: files,
        targetSegmentSeconds: 2,
      );

      final s = await hls.get('film');
      expect(s, isNotNull);
      expect(s!.url, startsWith('http://127.0.0.1:'));
      expect(s.probe.video, isNotNull);
      expect(s.probe.audio, hasLength(1));
      expect(s.keyframes.length, greaterThanOrEqualTo(5));
      expect(s.segmentCount, greaterThan(1));
      expect(s.sourceExpiresAt, isNull); // local files never need re-resolving

      // Cached: a second get neither rebuilds nor re-resolves.
      expect(await hls.get('film'), same(s));
      expect(resolver.resolved, ['film']);

      expect(await hls.get('other'), isNull);
    },
  );

  test('a FileMediaSource without a LocalRangeServer fails loudly', () async {
    final proxy = S3RangeProxy();
    await proxy.start();
    addTearDown(proxy.stop);
    final hls = HlsSessionManager(resolver: _OneFile(mkv), proxy: proxy);
    await expectLater(hls.get('film'), throwsStateError);
  });

  test(
    'once the local file is freed, the session reads the remote copy',
    () async {
      final proxy = S3RangeProxy();
      final files = LocalRangeServer();
      final remote = LocalRangeServer(); // stands in for S3
      await proxy.start();
      await files.start();
      await remote.start();
      addTearDown(() async {
        await proxy.stop();
        await files.stop();
        await remote.stop();
      });
      final film = _Uploaded(mkv, remote.register('obj', CompleteFile(mkv)));
      final hls = HlsSessionManager(
        resolver: film,
        proxy: proxy,
        localFiles: files,
        targetSegmentSeconds: 2,
      );
      final s = (await hls.get('film'))!;
      expect(s.sourceExpiresAt, isNull);

      film.freed = true;
      final c = HttpClient();
      addTearDown(c.close);
      final req = await c.getUrl(Uri.parse(s.url)); // follows the redirect
      req.headers.set(HttpHeaders.rangeHeader, 'bytes=0-99');
      final res = await req.close();
      final body = await res.fold<List<int>>([], (a, b) => a..addAll(b));
      expect(res.redirects.single.location.port, isNot(Uri.parse(s.url).port));
      expect(body, File(mkv).readAsBytesSync().sublist(0, 100));
      expect(
        s.sourceExpiresAt,
        DateTime(2100),
      ); // refreshed like any S3 session
    },
  );
}
