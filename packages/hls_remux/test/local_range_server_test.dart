import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:hls_remux/hls_remux.dart';
import 'package:test/test.dart';

/// A file still downloading: only its first [have] bytes are readable, and it
/// sits at [at] (null once freed).
class _Downloading implements LocalFile {
  _Downloading(this.at, this.length);

  String? at;
  int have = 0;

  @override
  final int length;

  @override
  String? path() => at;

  @override
  Future<int> readable(int offset) async => max(0, have - offset);
}

void main() {
  late Directory dir;
  late File file;
  late LocalRangeServer server;
  final bytes = List<int>.generate(1 << 20, (i) => i % 251);

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('lrs_');
    file = File('${dir.path}/a.bin')..writeAsBytesSync(bytes);
    server = LocalRangeServer();
    await server.start();
  });

  tearDown(() async {
    await server.stop();
    await dir.delete(recursive: true);
  });

  Future<(int, Map<String, String>, List<int>)> get(
    String url, {
    String? range,
    String method = 'GET',
  }) async {
    final c = HttpClient();
    try {
      final req = await c.openUrl(method, Uri.parse(url));
      if (range != null) req.headers.set(HttpHeaders.rangeHeader, range);
      final res = await req.close();
      final body = await res.fold<List<int>>([], (a, b) => a..addAll(b));
      final h = <String, String>{};
      res.headers.forEach((k, v) => h[k] = v.join(','));
      return (res.statusCode, h, body);
    } finally {
      c.close();
    }
  }

  test('full GET is a 200 with the whole file', () async {
    final url = server.register('x', CompleteFile(file.path));
    final (status, h, body) = await get(url);
    expect(status, 200);
    expect(h['accept-ranges'], 'bytes');
    expect(body, bytes);
  });

  test('ranges: explicit, open-ended and suffix', () async {
    final url = server.register('x', CompleteFile(file.path));
    var (status, h, body) = await get(url, range: 'bytes=10-19');
    expect(status, 206);
    expect(h['content-range'], 'bytes 10-19/${bytes.length}');
    expect(body, bytes.sublist(10, 20));

    (status, h, body) = await get(url, range: 'bytes=${bytes.length - 5}-');
    expect(body, bytes.sublist(bytes.length - 5));

    (status, h, body) = await get(url, range: 'bytes=-7');
    expect(status, 206);
    expect(body, bytes.sublist(bytes.length - 7));
  });

  test('unsatisfiable range is a 416', () async {
    final url = server.register('x', CompleteFile(file.path));
    final (status, h, _) = await get(url, range: 'bytes=${bytes.length}-');
    expect(status, 416);
    expect(h['content-range'], 'bytes */${bytes.length}');
  });

  test('HEAD reports the length without a body', () async {
    final url = server.register('x', CompleteFile(file.path));
    final (status, h, body) = await get(url, method: 'HEAD');
    expect(status, 200);
    expect(h['content-length'], '${bytes.length}');
    expect(body, isEmpty);
  });

  test('unknown and forgotten ids are 404', () async {
    final url = server.register('x', CompleteFile(file.path));
    server.forget('x');
    expect((await get(url)).$1, 404);
    expect((await get(url.replaceFirst('/x', '/nope'))).$1, 404);
  });

  test('a reader hanging up mid-body leaves the server serving', () async {
    final big = File('${dir.path}/big.bin')
      ..writeAsBytesSync(List<int>.filled(64 << 20, 7));
    final url = server.register('big', CompleteFile(big.path));
    final errors = <Object>[];
    await runZonedGuarded(() async {
      final sock = await Socket.connect(
        InternetAddress.loopbackIPv4,
        Uri.parse(url).port,
      );
      sock.write('GET ${Uri.parse(url).path} HTTP/1.1\r\nHost: x\r\n\r\n');
      await sock.first; // some of the body arrived
      sock.destroy(); // like ffmpeg on a seek
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }, (e, _) => errors.add(e));
    expect(errors, isEmpty);
    expect((await get(url, range: 'bytes=0-3')).$3, [7, 7, 7, 7]);
  });

  group('a file still downloading', () {
    late LocalRangeServer gated;
    late _Downloading dl;
    late String url;

    setUp(() async {
      gated = LocalRangeServer(
        waitCap: const Duration(milliseconds: 300),
        pollInterval: const Duration(milliseconds: 10),
        chunkBytes: 64 << 10,
      );
      await gated.start();
      dl = _Downloading(file.path, bytes.length);
      url = gated.register('dl', dl);
    });

    tearDown(() => gated.stop());

    test('a read waits for the bytes, then streams them', () async {
      final res = get(url, range: 'bytes=0-');
      await Future<void>.delayed(const Duration(milliseconds: 100));
      dl.have = bytes.length ~/ 2;
      await Future<void>.delayed(const Duration(milliseconds: 100));
      dl.have = bytes.length;
      final (status, h, body) = await res;
      expect(status, 206);
      expect(h['content-range'], 'bytes 0-${bytes.length - 1}/${bytes.length}');
      expect(body, bytes);
    });

    test('nothing there within the wait cap is a 503', () async {
      expect((await get(url, range: 'bytes=0-')).$1, 503);
    });

    test('a stall mid-body drops the connection', () async {
      dl.have = 1000;
      await expectLater(
        get(url, range: 'bytes=0-'),
        throwsA(isA<HttpException>()),
      );
    });

    test('a rename mid-stream keeps streaming', () async {
      dl.have = bytes.length ~/ 2;
      final res = get(url, range: 'bytes=0-');
      await Future<void>.delayed(const Duration(milliseconds: 100));
      dl.at = file.renameSync('${dir.path}/a.done').path; // `.part` → final
      dl.have = bytes.length;
      expect((await res).$3, bytes);
    });

    test(
      'once the file is gone it redirects to the fallback, resolved once',
      () async {
        var asked = 0;
        final url = gated.register(
          'moved',
          dl,
          fallback: () async {
            asked++;
            return 'http://127.0.0.1:1/elsewhere';
          },
        );
        dl.at = null;
        final c = HttpClient();
        addTearDown(c.close);
        for (var i = 0; i < 2; i++) {
          final req = await c.getUrl(Uri.parse(url));
          req.followRedirects = false;
          final res = await req.close();
          await res.drain<void>();
          expect(res.statusCode, 302);
          expect(res.headers.value('location'), 'http://127.0.0.1:1/elsewhere');
        }
        expect(asked, 1);
      },
    );

    test('gone with no fallback is a 404', () async {
      dl.at = null;
      expect((await get(url)).$1, 404);
    });
  });
}
