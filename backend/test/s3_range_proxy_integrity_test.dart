import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:cineseed_backend/streaming/s3_range_proxy.dart';
import 'package:test/test.dart';

/// Deterministic content: byte at absolute offset [i]. Every test below asserts
/// the proxy returns exactly this for every byte of every range it serves.
///
/// The existing proxy tests use an all-zero upstream, so any mix-up between two
/// pooled buffers is invisible to them: zeros compare equal to zeros. This file
/// exists to make the *content* observable.
int _byteAt(int i) => (i * 31 + (i >> 7)) & 0xff;

class PatternUpstream {
  PatternUpstream({required this.total});

  final int total;
  int requests = 0;

  /// Delay inserted before the body of every response, to widen races.
  Duration bodyDelay = Duration.zero;

  HttpServer? _server;
  int get port => _server!.port;

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server!.listen((req) async {
      requests++;
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
        if (bodyDelay > Duration.zero) await Future<void>.delayed(bodyDelay);
        const block = 16 * 1024;
        var sent = 0;
        while (sent < len) {
          final n = (len - sent) < block ? (len - sent) : block;
          final b = Uint8List(n);
          for (var k = 0; k < n; k++) {
            b[k] = _byteAt(start + sent + k);
          }
          res.add(b);
          sent += n;
          await res.flush();
        }
        await res.close();
      } catch (_) {
        // client hung up — expected in some tests
      }
    });
  }

  Future<void> stop() => _server!.close(force: true);
}

/// Fetches `[start, end]` through the proxy, following the short-206 protocol
/// (the proxy caps a response at maxServeBytes and expects a re-request), and
/// verifies every byte against the pattern.
Future<void> fetchAndVerify(
  HttpClient client,
  int port,
  String hash,
  int start,
  int end,
) async {
  var pos = start;
  while (pos <= end) {
    final req = await client.getUrl(Uri.parse('http://127.0.0.1:$port/$hash'));
    req.headers.set(HttpHeaders.rangeHeader, 'bytes=$pos-$end');
    final resp = await req.close();
    expect(resp.statusCode, HttpStatus.partialContent);
    var off = pos;
    await for (final d in resp) {
      for (var k = 0; k < d.length; k++) {
        final abs = off + k;
        if (d[k] != _byteAt(abs)) {
          fail(
            'corrupt byte at offset $abs (range $start-$end): '
            'got ${d[k]}, want ${_byteAt(abs)}',
          );
        }
      }
      off += d.length;
    }
    if (off == pos) fail('no progress at $pos');
    pos = off;
  }
}

void main() {
  late PatternUpstream up;
  const total = 4 << 20; // 4 MiB

  setUp(() async {
    up = PatternUpstream(total: total);
    await up.start();
  });

  tearDown(() async => up.stop());

  test(
    'serves exact bytes for random overlapping ranges under concurrency',
    () async {
      // Tiny chunks and only 4 pool slots, so buffers are recycled constantly and
      // the cache thrashes — the condition prod hits when playback jumps between
      // distant regions of a film.
      final proxy = S3RangeProxy(
        chunkSize: 64 << 10,
        maxCacheBytes: 256 << 10, // 4 slots
        maxServeBytes: 128 << 10,
        readAheadChunks: 3,
        maxConcurrent: 6,
        upstreamTimeout: const Duration(seconds: 10),
      );
      await proxy.start();
      final url = proxy.register('h', 'http://127.0.0.1:${up.port}/o');
      final port = Uri.parse(url).port;
      final client = HttpClient()..maxConnectionsPerHost = 16;
      final rnd = Random(1234);

      try {
        for (var round = 0; round < 6; round++) {
          await Future.wait([
            for (var i = 0; i < 12; i++)
              () async {
                final start = rnd.nextInt(total - 1);
                final len = 1 + rnd.nextInt(300 << 10);
                final end = min(total - 1, start + len);
                await fetchAndVerify(client, port, 'h', start, end);
              }(),
          ]);
        }
      } finally {
        client.close(force: true);
        await proxy.stop();
      }
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test('a reader abandoned at the write-idle timeout cannot corrupt others', () async {
    // The suspected hazard: `_stream` recycles a chunk's pooled buffer in its
    // `finally` when `res.flush()` times out — but the timeout does not cancel
    // the underlying socket write, so the recycled buffer may still be pending.
    // Refill it from another fetch and the wedged socket ships the *new* chunk's
    // bytes under the old range. Here a wedged reader is held open while other
    // readers keep churning the pool, and every non-wedged byte is verified.
    final proxy = S3RangeProxy(
      chunkSize: 64 << 10,
      maxCacheBytes: 128 << 10, // 2 slots — maximum recycling pressure
      maxServeBytes: 128 << 10,
      readAheadChunks: 1,
      maxConcurrent: 4,
      writeIdleTimeout: const Duration(milliseconds: 300),
      upstreamTimeout: const Duration(seconds: 10),
    );
    await proxy.start();
    final url = proxy.register('h', 'http://127.0.0.1:${up.port}/o');
    final port = Uri.parse(url).port;
    final client = HttpClient()..maxConnectionsPerHost = 16;

    // Readers that never drain their socket: the proxy's writes back up and its
    // flush hits writeIdleTimeout.
    final wedged = <Socket>[];
    for (var i = 0; i < 3; i++) {
      final s = await Socket.connect(InternetAddress.loopbackIPv4, port);
      s.write(
        'GET /h HTTP/1.1\r\nHost: 127.0.0.1\r\n'
        'Range: bytes=${i * (512 << 10)}-\r\nConnection: close\r\n\r\n',
      );
      await s.flush();
      wedged.add(s);
    }

    try {
      final rnd = Random(99);
      for (var round = 0; round < 6; round++) {
        await Future.wait([
          for (var i = 0; i < 6; i++)
            () async {
              final start = rnd.nextInt(total - 1);
              final end = min(total - 1, start + 1 + rnd.nextInt(200 << 10));
              await fetchAndVerify(client, port, 'h', start, end);
            }(),
        ]);
      }
    } finally {
      for (final s in wedged) {
        s.destroy();
      }
      client.close(force: true);
      await proxy.stop();
    }
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('a client that disconnects mid-response cannot corrupt others', () async {
    // ffmpeg seeks by closing the connection mid-body. That aborts `res.flush()`
    // (or `res.add`) with an error, which unwinds `_stream` through its `finally`
    // and recycles the buffer — while the socket teardown may still hold it.
    final proxy = S3RangeProxy(
      chunkSize: 64 << 10,
      maxCacheBytes: 128 << 10,
      maxServeBytes: 512 << 10,
      readAheadChunks: 2,
      maxConcurrent: 4,
      upstreamTimeout: const Duration(seconds: 10),
    );
    await proxy.start();
    final url = proxy.register('h', 'http://127.0.0.1:${up.port}/o');
    final port = Uri.parse(url).port;
    final client = HttpClient()..maxConnectionsPerHost = 16;
    up.bodyDelay = const Duration(milliseconds: 5);

    try {
      final rnd = Random(7);
      for (var round = 0; round < 8; round++) {
        // Half the clients bail out after a few KB; the rest verify in full.
        await Future.wait([
          for (var i = 0; i < 4; i++)
            () async {
              final s = await Socket.connect(
                InternetAddress.loopbackIPv4,
                port,
              );
              s.write(
                'GET /h HTTP/1.1\r\nHost: 127.0.0.1\r\n'
                'Range: bytes=${rnd.nextInt(total - 1)}-\r\n'
                'Connection: close\r\n\r\n',
              );
              await s.flush();
              var got = 0;
              await for (final d in s) {
                got += d.length;
                if (got > 8 * 1024) break;
              }
              s.destroy();
            }(),
          for (var i = 0; i < 4; i++)
            () async {
              final start = rnd.nextInt(total - 1);
              final end = min(total - 1, start + 1 + rnd.nextInt(300 << 10));
              await fetchAndVerify(client, port, 'h', start, end);
            }(),
        ]);
      }
    } finally {
      client.close(force: true);
      await proxy.stop();
    }
  }, timeout: const Timeout(Duration(minutes: 3)));
}
