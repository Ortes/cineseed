import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:cineseed_streaming/cineseed_streaming.dart';
import 'package:test/test.dart';

/// A controllable stand-in for S3. Honours `Range`, and can be told to truncate
/// its body (to exercise short-read rejection) or to ignore Range entirely and
/// answer 200 (to exercise the `e.total` guard).
class FakeUpstream {
  FakeUpstream({required this.total});

  final int total;
  int truncateBy = 0;
  bool ignoreRange = false;
  int requests = 0;

  HttpServer? _server;
  int get port => _server!.port;

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server!.listen((req) async {
      requests++;
      final res = req.response;
      try {
        if (ignoreRange) {
          final body = Uint8List(total);
          res.statusCode = HttpStatus.ok;
          res.headers.contentLength = body.length;
          res.add(body);
          await res.close();
          return;
        }
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
        // Declare the true length but send fewer bytes when asked to truncate:
        // that is precisely the "connection dropped early without erroring"
        // case that must never be cached as a complete chunk.
        res.headers.contentLength = len - truncateBy;
        final send = len - truncateBy;
        var sent = 0;
        final block = Uint8List(64 * 1024);
        while (sent < send) {
          final n = (send - sent) < block.length ? (send - sent) : block.length;
          res.add(Uint8List.sublistView(block, 0, n));
          sent += n;
          await res.flush();
        }
        await res.close();
      } catch (_) {
        // client hung up mid-write — expected in some tests
      }
    });
  }

  Future<void> stop() => _server!.close(force: true);
}

void main() {
  late FakeUpstream up;

  setUp(() async {
    up = FakeUpstream(total: 64 << 20);
    await up.start();
  });

  tearDown(() async => up.stop());

  /// Sends a raw request and deliberately never reads the body, leaving the
  /// socket open — exactly what ffmpeg does when it seeks: it stops reading an
  /// open-ended response without closing. Returns the socket so the caller can
  /// keep it (and the wedge) alive.
  Future<Socket> wedgedRequest(int port, String hash) async {
    final sock = await Socket.connect(InternetAddress.loopbackIPv4, port);
    sock.write(
      'GET /$hash HTTP/1.1\r\n'
      'Host: 127.0.0.1\r\n'
      'Range: bytes=0-\r\n'
      'Connection: close\r\n\r\n',
    );
    await sock.flush();
    // Never listen() — nothing is drained, so the proxy's writes back up.
    return sock;
  }

  test(
    'a wedged reader does not hold its slot past the write-idle timeout',
    () async {
      // maxConcurrent 1 makes the hazard unambiguous: if the wedged response
      // never yields its slot, the second request can never be served.
      final proxy = S3RangeProxy(
        chunkSize: 1 << 20,
        readAheadChunks: 0,
        maxCacheBytes: 8 << 20,
        maxServeBytes: 8 << 20,
        maxConcurrent: 1,
        writeIdleTimeout: const Duration(seconds: 2),
      );
      await proxy.start();
      addTearDown(proxy.stop);
      proxy.register('h', 'http://127.0.0.1:${up.port}/obj');

      final wedged = await wedgedRequest(proxy.port, 'h');
      addTearDown(() => wedged.destroy());

      // Give the proxy time to accept, fetch, and block writing to the wedge.
      await Future<void>.delayed(const Duration(milliseconds: 500));

      // A well-behaved client must still get served once the wedge times out.
      final client = HttpClient();
      addTearDown(() => client.close(force: true));
      final sw = Stopwatch()..start();
      final req = await client.getUrl(
        Uri.parse('http://127.0.0.1:${proxy.port}/h'),
      );
      req.headers.set(HttpHeaders.rangeHeader, 'bytes=0-1023');
      final resp = await req.close().timeout(const Duration(seconds: 20));
      var got = 0;
      await for (final d in resp) {
        got += d.length;
      }
      sw.stop();

      expect(got, 1024);
      // It had to wait for the wedge to be reclaimed (>= the 2s idle timeout),
      // but must not have waited anywhere near forever.
      expect(sw.elapsed, greaterThan(const Duration(seconds: 1)));
      expect(sw.elapsed, lessThan(const Duration(seconds: 15)));
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test('a short upstream read is never cached as a complete chunk', () async {
    final proxy = S3RangeProxy(
      chunkSize: 1 << 20,
      readAheadChunks: 0,
      maxCacheBytes: 8 << 20,
      maxServeBytes: 1 << 20,
    );
    await proxy.start();
    addTearDown(proxy.stop);
    proxy.register('h', 'http://127.0.0.1:${up.port}/obj');
    up.truncateBy = 4096; // always short → all 3 attempts fail

    final client = HttpClient();
    addTearDown(() => client.close(force: true));
    final req = await client.getUrl(
      Uri.parse('http://127.0.0.1:${proxy.port}/h'),
    );
    req.headers.set(HttpHeaders.rangeHeader, 'bytes=0-65535');
    final resp = await req.close();
    await resp.drain<void>();

    // Nothing may be retained, and the budget must be clean — a leaked
    // reservation would permanently shrink the usable cache.
    expect(proxy.cachedBytes, 0);
    expect(proxy.reservedBytes, 0);
    // Retried rather than trusting the first short body.
    expect(up.requests, greaterThan(1));
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('a failed fetch returns its buffer to the pool', () async {
    final proxy = S3RangeProxy(
      chunkSize: 1 << 20,
      readAheadChunks: 0,
      maxCacheBytes: 2 << 20, // 2 pool buffers
      maxServeBytes: 1 << 20,
    );
    await proxy.start();
    addTearDown(proxy.stop);
    proxy.register('h', 'http://127.0.0.1:${up.port}/obj');
    final client = HttpClient();
    addTearDown(() => client.close(force: true));

    Future<int> read(int chunk) async {
      final req = await client.getUrl(
        Uri.parse('http://127.0.0.1:${proxy.port}/h'),
      );
      final from = chunk << 20;
      req.headers.set(HttpHeaders.rangeHeader, 'bytes=$from-${from + 1023}');
      final resp = await req.close();
      await resp.drain<void>();
      return resp.statusCode;
    }

    await read(0); // learns the total
    up.truncateBy = 4096; // every attempt fails
    await expectLater(read(1), throwsA(anything));
    up.truncateBy = 0;

    // More distinct chunks than there are buffers: each needs an eviction to
    // get one. A leaked buffer made the first of these hang forever.
    for (var i = 2; i < 6; i++) {
      expect(await read(i).timeout(const Duration(seconds: 5)), 206);
    }
  }, timeout: const Timeout(Duration(seconds: 60)));

  test(
    'forget() during an in-flight fetch leaves the budget balanced',
    () async {
      final proxy = S3RangeProxy(
        chunkSize: 1 << 20,
        readAheadChunks: 3,
        maxCacheBytes: 8 << 20,
        maxServeBytes: 4 << 20,
      );
      await proxy.start();
      addTearDown(proxy.stop);
      proxy.register('h', 'http://127.0.0.1:${up.port}/obj');

      final client = HttpClient();
      addTearDown(() => client.close(force: true));
      final req = await client.getUrl(
        Uri.parse('http://127.0.0.1:${proxy.port}/h'),
      );
      req.headers.set(HttpHeaders.rangeHeader, 'bytes=0-');
      final pending = req.close().then((r) => r.drain<void>());

      // Drop the file mid-flight, racing the fetches and their read-ahead.
      await Future<void>.delayed(const Duration(milliseconds: 20));
      proxy.forget('h');
      try {
        await pending.timeout(const Duration(seconds: 15));
      } catch (_) {
        // The response may legitimately fail once the entry is gone.
      }
      await Future<void>.delayed(const Duration(milliseconds: 800));

      expect(proxy.cachedBytes, 0);
      expect(proxy.reservedBytes, 0);
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test('the byte budget is never exceeded across many cold reads', () async {
    const cap = 4 << 20;
    final proxy = S3RangeProxy(
      chunkSize: 1 << 20,
      readAheadChunks: 3,
      maxCacheBytes: cap,
      maxServeBytes: 2 << 20,
      maxConcurrent: 4,
    );
    await proxy.start();
    addTearDown(proxy.stop);
    proxy.register('h', 'http://127.0.0.1:${up.port}/obj');

    final client = HttpClient()..maxConnectionsPerHost = 8;
    addTearDown(() => client.close(force: true));
    var maxSeen = 0;
    for (var i = 0; i < 24; i++) {
      final off = i * (2 << 20);
      final req = await client.getUrl(
        Uri.parse('http://127.0.0.1:${proxy.port}/h'),
      );
      req.headers.set(HttpHeaders.rangeHeader, 'bytes=$off-');
      final resp = await req.close();
      await resp.drain<void>();
      final used = proxy.cachedBytes + proxy.reservedBytes;
      if (used > maxSeen) maxSeen = used;
      expect(used, lessThanOrEqualTo(cap));
    }
    expect(maxSeen, greaterThan(0)); // the cache really was exercised
  }, timeout: const Timeout(Duration(seconds: 120)));

  group('parseRange', () {
    test('open-ended, closed and suffix ranges', () {
      expect(S3RangeProxy.parseRange('bytes=0-', 100), (0, 99));
      expect(S3RangeProxy.parseRange('bytes=10-19', 100), (10, 19));
      expect(S3RangeProxy.parseRange('bytes=-10', 100), (90, 99));
      expect(S3RangeProxy.parseRange('bytes=90-200', 100), (90, 99));
    });

    test('suffix range is the LAST n bytes, not the first n', () {
      // Regression guard for /api/file/<hash>, which used to parse this inline
      // and read `bytes=-500` as 0-500 — the first 501 bytes. ffmpeg uses a
      // suffix range to read an MKV's Cues near EOF, so getting this wrong
      // hands it the file header instead of the index.
      expect(S3RangeProxy.parseRange('bytes=-500', 10000), (9500, 9999));
      // A suffix larger than the object clamps to the whole object.
      expect(S3RangeProxy.parseRange('bytes=-99999', 10000), (0, 9999));
      expect(S3RangeProxy.parseRange('bytes=-0', 10000), isNull);
    });

    test('rejects malformed and unsatisfiable', () {
      expect(S3RangeProxy.parseRange('items=0-1', 100), isNull);
      expect(S3RangeProxy.parseRange('bytes=100-', 100), isNull);
      expect(S3RangeProxy.parseRange('bytes=50-10', 100), isNull);
      expect(S3RangeProxy.parseRange('bytes=0-', 0), isNull);
    });
  });
}
