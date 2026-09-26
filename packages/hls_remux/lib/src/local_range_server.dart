import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'log.dart';
import 'media_source.dart';
import 's3_range_proxy.dart';

/// Serves registered local files on loopback with HTTP Range support, so
/// ffprobe, ffmpeg and `MkvCues` read a local file through the same URL-based
/// path as a remote one.
///
/// A file may still be downloading. ffmpeg reads well ahead of playback, and
/// past the download point the file holds holes, not an EOF: so every chunk
/// first waits until [LocalFile.readable] covers it, for at most [waitCap]
/// (ffmpeg's own `-rw_timeout`). A request that got nothing by then is a 503;
/// one cut off mid-body has its connection dropped, and ffmpeg reconnects.
///
/// Each chunk reopens the file at its current [LocalFile.path]: it may be
/// renamed on completion, and an fd held for a whole film would pin its blocks
/// once the local copy is freed. After that, requests are redirected to the
/// registration's `fallback` (the same file elsewhere, e.g. on S3); ffmpeg
/// follows the redirect and stays there.
class LocalRangeServer {
  LocalRangeServer({
    this.waitCap = const Duration(seconds: 30),
    this.pollInterval = const Duration(seconds: 1),
    this.chunkBytes = 4 << 20,
  });

  final Duration waitCap;
  final Duration pollInterval;
  final int chunkBytes;

  final _files = <String, _Entry>{};
  HttpServer? _server;

  Future<void> start() async {
    if (_server != null) return;
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server!.listen(_handle);
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
  }

  /// Registers [file] under [id] and returns the loopback URL to read it from.
  /// [fallback] gives the URL to redirect to once the file is gone.
  String register(
    String id,
    LocalFile file, {
    Future<String?> Function()? fallback,
  }) {
    final server = _server;
    if (server == null) throw StateError('LocalRangeServer not started');
    _files[id] = _Entry(file, fallback);
    return 'http://127.0.0.1:${server.port}/$id';
  }

  void forget(String id) => _files.remove(id);

  Future<void> _handle(HttpRequest req) async {
    final res = req.response;
    var streaming = false; // status and headers are out
    try {
      final id = req.uri.pathSegments.isNotEmpty
          ? req.uri.pathSegments.first
          : '';
      final entry = _files[id];
      if (entry == null) return await _status(res, HttpStatus.notFound);
      final file = entry.file;
      if (file.path() == null) {
        final to = await entry.moved();
        if (to == null) return await _status(res, HttpStatus.notFound);
        res.headers.set(HttpHeaders.locationHeader, to);
        return await _status(res, HttpStatus.found);
      }

      final total = file.length;
      final rangeHeader = req.headers.value(HttpHeaders.rangeHeader);
      var start = 0;
      var end = total - 1;
      if (rangeHeader != null) {
        final parsed = S3RangeProxy.parseRange(rangeHeader, total);
        if (parsed == null) {
          res.headers.set(HttpHeaders.contentRangeHeader, 'bytes */$total');
          return await _status(res, HttpStatus.requestedRangeNotSatisfiable);
        }
        (start, end) = parsed;
      }
      // Nothing goes out before the first byte is there, so a file not yet
      // downloaded that far is a clean 503 rather than a truncated 206.
      if (req.method != 'HEAD' && await _waitReadable(file, start) == 0) {
        return await _status(res, HttpStatus.serviceUnavailable);
      }

      if (rangeHeader != null) {
        res.statusCode = HttpStatus.partialContent;
        res.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes $start-$end/$total',
        );
      }
      res.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
      res.headers.contentType = ContentType.binary;
      res.headers.contentLength = end - start + 1;
      if (req.method == 'HEAD') return await res.close();

      streaming = true;
      var pos = start;
      while (pos <= end) {
        final n = await _waitReadable(file, pos);
        final path = file.path();
        if (n == 0 || path == null) {
          Log.d('local', '$id: stalled at $pos, dropping the connection');
          return await _abort(res);
        }
        final to = min(end + 1, pos + min<int>(n, chunkBytes));
        var sent = 0;
        await res.addStream(
          File(path).openRead(pos, to).map((b) {
            sent += b.length;
            return b;
          }),
        );
        // A reader hanging up (ffmpeg on every seek) makes addStream return
        // early with the file read cancelled: stop there.
        if (pos + sent < to) return await res.close();
        pos = to;
      }
      await res.close();
    } catch (e) {
      // One failed lookup (e.g. the torrent client's RPC) fails this request
      // only; the server keeps serving the others.
      Log.w('local', '${req.method} ${req.uri.path} failed: $e');
      if (streaming) return await _abort(res);
      await _status(res, HttpStatus.internalServerError);
    }
  }

  /// How many bytes [file] has from [pos], waiting up to [waitCap] for some.
  Future<int> _waitReadable(LocalFile file, int pos) async {
    final deadline = DateTime.now().add(waitCap);
    while (true) {
      final n = await file.readable(pos);
      if (n > 0 || !DateTime.now().isBefore(deadline)) return n;
      await Future<void>.delayed(pollInterval);
    }
  }

  static Future<void> _status(HttpResponse res, int code) {
    res.statusCode = code;
    return res.close();
  }

  /// Drops the connection mid-body. Closing short of Content-Length is how:
  /// dart:io then destroys the socket and fails close() with an
  /// [HttpException], which is the expected outcome here. The reader sees a
  /// premature end.
  static Future<void> _abort(HttpResponse res) async {
    try {
      await res.close();
    } on HttpException {
      // The short close above: the connection is gone, as intended.
    }
  }
}

class _Entry {
  _Entry(this.file, this.fallback);

  final LocalFile file;
  final Future<String?> Function()? fallback;
  Future<String?>? _moved; // the redirect target, resolved once

  Future<String?> moved() async {
    final fallback = this.fallback;
    if (fallback == null) return null;
    final pending = _moved ??= fallback();
    try {
      final url = await pending;
      if (url == null) _moved = null; // not there yet: ask again next time
      return url;
    } catch (_) {
      _moved = null;
      rethrow;
    }
  }
}
