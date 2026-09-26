import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:hls_remux/hls_remux.dart';
import 'package:test/test.dart';

/// Upstream that answers any Range instantly with zeros.
class QuickUpstream {
  QuickUpstream({required this.total});
  final int total;
  HttpServer? _server;
  int get port => _server!.port;

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server!.listen((req) async {
      final res = req.response;
      try {
        final rh = req.headers.value(HttpHeaders.rangeHeader);
        var start = 0;
        var end = total - 1;
        if (rh != null) {
          final p = S3RangeProxy.parseRange(rh, total);
          if (p != null) {
            start = p.$1;
            end = p.$2;
          }
        }
        final len = end - start + 1;
        res.statusCode = HttpStatus.partialContent;
        res.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes $start-$end/$total',
        );
        res.headers.contentLength = len;
        res.add(Uint8List(len));
        await res.close();
      } catch (_) {}
    });
  }

  Future<void> stop() => _server!.close(force: true);
}

void main() {
  test('a warm read is not starved by readers that stopped reading', () async {
    // Prod values, and deliberately the *default* writeIdleTimeout: ffmpeg
    // abandons open-ended responses routinely (it opens `bytes=X-`, reads its
    // segment, stops without closing), so a seek fills every slot with them.
    // This is the steady state, not an edge case, and at the old 20 s default it
    // starved a cache-warm read for 19.5 s — past the 18 s segment timeout, so
    // the producer 404'd and hls.js gave up.
    final up = QuickUpstream(total: 64 << 20);
    await up.start();
    final proxy = S3RangeProxy(
      chunkSize: 8 << 20,
      maxCacheBytes: 64 << 20,
      maxServeBytes: 16 << 20,
      maxConcurrent: 6,
    );
    await proxy.start();
    final url = proxy.register('h', 'http://127.0.0.1:${up.port}/o');
    final port = Uri.parse(url).port;

    // Six readers that stop reading without closing — one per slot.
    final wedged = <Socket>[];
    for (var i = 0; i < 6; i++) {
      final s = await Socket.connect(InternetAddress.loopbackIPv4, port);
      s.write(
        'GET /h HTTP/1.1\r\nHost: 127.0.0.1\r\n'
        'Range: bytes=${i * (8 << 20)}-\r\nConnection: close\r\n\r\n',
      );
      await s.flush();
      wedged.add(s); // never listen() → nothing drained
    }
    await Future<void>.delayed(const Duration(milliseconds: 500));

    // A real read, of a chunk that is already cache-warm.
    final client = HttpClient();
    final sw = Stopwatch()..start();
    final req = await client.getUrl(Uri.parse('http://127.0.0.1:$port/h'));
    req.headers.set(HttpHeaders.rangeHeader, 'bytes=0-1023');
    final resp = await req.close();
    await resp.drain<void>();
    sw.stop();

    stderr.writeln(
      '>>> warm 1 KiB read behind 6 abandoned readers: '
      '${sw.elapsedMilliseconds} ms, pooled=${proxy.pooledBytes >> 20} MiB',
    );

    // Forfeited buffers are written off, so the pool still offers its full
    // complement and a later read cannot be short of one.
    expect(proxy.pooledBytes, lessThanOrEqualTo(64 << 20));
    final req2 = await client.getUrl(Uri.parse('http://127.0.0.1:$port/h'));
    req2.headers.set(
      HttpHeaders.rangeHeader,
      'bytes=${40 << 20}-${(40 << 20) + 1023}',
    );
    final resp2 = await req2.close().timeout(const Duration(seconds: 15));
    var got = 0;
    await for (final d in resp2) {
      got += d.length;
    }
    expect(got, 1024);

    for (final s in wedged) {
      s.destroy();
    }
    client.close(force: true);
    await proxy.stop();
    await up.stop();

    // The segment timeout is 18 s: a stall anywhere near it means the producer
    // never delivers, so the fragment 404s and playback dies.
    expect(
      sw.elapsed,
      lessThan(const Duration(seconds: 5)),
      reason: 'a warm read queued behind abandoned readers',
    );
  }, timeout: const Timeout(Duration(minutes: 2)));
}
