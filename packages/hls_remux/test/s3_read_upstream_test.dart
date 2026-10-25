import 'dart:io';
import 'dart:typed_data';

import 'package:hls_remux/hls_remux.dart';
import 'package:test/test.dart';

void main() {
  const total = 100000;
  late HttpServer upstream;
  late S3RangeProxy proxy;
  var stallNext = 0; // requests to hold without answering, like Scaleway's
  var ignoreRange = false;
  var requests = 0;

  setUp(() async {
    stallNext = 0;
    ignoreRange = false;
    requests = 0;
    upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    upstream.listen((req) async {
      requests++;
      final res = req.response;
      if (stallNext > 0) {
        stallNext--;
        return; // never answered; the client gives up on it
      }
      final range = S3RangeProxy.parseRange(
        req.headers.value(HttpHeaders.rangeHeader) ?? '',
        total,
      );
      if (ignoreRange) {
        res.statusCode = HttpStatus.ok;
      } else if (range == null) {
        res.statusCode = HttpStatus.requestedRangeNotSatisfiable;
        return res.close();
      } else {
        res.statusCode = HttpStatus.partialContent;
      }
      final (start, end) = range ?? (0, total - 1);
      res.add([for (var i = start; i <= end; i++) i % 251]);
      await res.close();
    });
    proxy = S3RangeProxy();
    await proxy.start();
    proxy.register('f', 'http://127.0.0.1:${upstream.port}/f');
  });

  tearDown(() async {
    await proxy.stop();
    await upstream.close(force: true);
  });

  test('reads exactly the range, in one request', () async {
    final b = await proxy.readUpstream('f', 5000, 300);
    expect(b, Uint8List.fromList([for (var i = 5000; i < 5300; i++) i % 251]));
    expect(requests, 1);
  });

  test('fewer bytes at the end, none past it', () async {
    expect(await proxy.readUpstream('f', total - 10, 300), hasLength(10));
    expect(await proxy.readUpstream('f', total + 5, 300), isEmpty);
  });

  test('a request held without an answer is sent again', () async {
    stallNext = 1;
    final b = await proxy.readUpstream('f', 10, 4);
    expect(b, [10, 11, 12, 13]);
    expect(requests, 2);
  });

  test('an upstream ignoring Range is an error, not the whole file', () async {
    ignoreRange = true;
    await expectLater(
      proxy.readUpstream('f', 10, 4),
      throwsA(isA<HttpException>()),
    );
  });
}
