import 'dart:io';

import 's3_range_proxy.dart';

/// Serves registered local files on loopback with HTTP Range support, so
/// ffprobe, ffmpeg and `MkvCues` read a local file through the same URL-based
/// path as a remote one. The id → path mapping is resolved once, at
/// [register]; requests only touch the disk.
class LocalRangeServer {
  final _files = <String, String>{};
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

  /// Registers [path] under [id] and returns the loopback URL to read it from.
  String register(String id, String path) {
    final server = _server;
    if (server == null) throw StateError('LocalRangeServer not started');
    _files[id] = path;
    return 'http://127.0.0.1:${server.port}/$id';
  }

  void forget(String id) => _files.remove(id);

  Future<void> _handle(HttpRequest req) async {
    final res = req.response;
    final id = req.uri.pathSegments.isNotEmpty
        ? req.uri.pathSegments.first
        : '';
    final path = _files[id];
    final file = path == null ? null : File(path);
    if (file == null || !file.existsSync()) {
      res.statusCode = HttpStatus.notFound;
      await res.close();
      return;
    }
    final total = file.lengthSync();
    final rangeHeader = req.headers.value(HttpHeaders.rangeHeader);
    var start = 0;
    var end = total - 1;
    if (rangeHeader != null) {
      final parsed = S3RangeProxy.parseRange(rangeHeader, total);
      if (parsed == null) {
        res.statusCode = HttpStatus.requestedRangeNotSatisfiable;
        res.headers.set(HttpHeaders.contentRangeHeader, 'bytes */$total');
        await res.close();
        return;
      }
      (start, end) = parsed;
      res.statusCode = HttpStatus.partialContent;
      res.headers.set(
        HttpHeaders.contentRangeHeader,
        'bytes $start-$end/$total',
      );
    }
    res.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
    res.headers.contentType = ContentType.binary;
    res.headers.contentLength = end - start + 1;
    if (req.method == 'HEAD') {
      await res.close();
      return;
    }
    // A reader hanging up mid-body (ffmpeg on every seek) needs no handling:
    // addStream then returns at once and cancels the file read.
    await res.addStream(file.openRead(start, end + 1));
    await res.close();
  }
}
