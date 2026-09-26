import 'dart:async';
import 'dart:io';

import 'package:hls_remux/hls_remux.dart';
import 'package:test/test.dart';

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
    final url = server.register('x', file.path);
    final (status, h, body) = await get(url);
    expect(status, 200);
    expect(h['accept-ranges'], 'bytes');
    expect(body, bytes);
  });

  test('ranges: explicit, open-ended and suffix', () async {
    final url = server.register('x', file.path);
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
    final url = server.register('x', file.path);
    final (status, h, _) = await get(url, range: 'bytes=${bytes.length}-');
    expect(status, 416);
    expect(h['content-range'], 'bytes */${bytes.length}');
  });

  test('HEAD reports the length without a body', () async {
    final url = server.register('x', file.path);
    final (status, h, body) = await get(url, method: 'HEAD');
    expect(status, 200);
    expect(h['content-length'], '${bytes.length}');
    expect(body, isEmpty);
  });

  test('unknown and forgotten ids are 404', () async {
    final url = server.register('x', file.path);
    server.forget('x');
    expect((await get(url)).$1, 404);
    expect((await get(url.replaceFirst('/x', '/nope'))).$1, 404);
  });

  test('a reader hanging up mid-body leaves the server serving', () async {
    final big = File('${dir.path}/big.bin')
      ..writeAsBytesSync(List<int>.filled(64 << 20, 7));
    final url = server.register('big', big.path);
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
}
