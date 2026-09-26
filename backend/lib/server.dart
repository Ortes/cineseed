import 'dart:async';
import 'dart:io';

import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as io;
import 'package:shelf_cors_headers/shelf_cors_headers.dart';
import 'package:shelf_router/shelf_router.dart';
import 'package:shelf_static/shelf_static.dart';

import 'api.dart';
import 'config.dart';
import 'log.dart';
import 'storage/s3_signer.dart';
import 'streaming/hls_session.dart';
import 'streaming/producer_manager.dart';
import 'streaming/s3_range_proxy.dart';
import 'streaming/segment_producer.dart';
import 'streaming/segments.dart';
import 'streaming/transcode_pool.dart';
import 'torrent/transmission_client.dart';
import 'tracker/torznab_tracker.dart';
import 'tracker/tmdb_client.dart';

/// Wires the connector + client + signer into a shelf handler and serves it.
Future<HttpServer> startServer(Config config) async {
  Log.enabled = config.debug;
  if (config.debug) {
    Log.d('boot', 'CINESEED_DEBUG on: verbose logging + segments kept on disk');
  }

  final tracker = TorznabTracker(
    baseUrl: config.trackerBaseUrl,
    apiKey: config.trackerApiKey,
  );
  final client = TransmissionClient(
    url: config.transmissionUrl,
    user: config.transmissionUser,
    pass: config.transmissionPass,
  );
  final signer = S3Signer(
    endpoint: config.s3Endpoint,
    region: config.s3Region,
    bucket: config.s3Bucket,
    accessKey: config.s3AccessKey,
    secretKey: config.s3SecretKey,
    defaultTtl: config.streamUrlTtl,
  );
  final tmdb = (config.tmdbApiKey != null && config.tmdbApiKey!.isNotEmpty)
      ? TmdbClient(apiKey: config.tmdbApiKey!)
      : null;

  // Live HLS: bounded ffmpeg pool + caching range proxy + per-file session
  // cache + segment generator.
  final pool = TranscodePool(config.hlsMaxTranscodes);
  final proxy = S3RangeProxy(
    chunkSize: config.hlsProxyChunkMb << 20,
    readAheadChunks: config.hlsProxyReadahead,
    maxCacheBytes: config.hlsProxyCacheMb << 20,
    maxServeBytes: config.hlsProxyMaxServeMb << 20,
    maxConcurrent: config.hlsProxyMaxConcurrent,
    debug: config.debug,
  );
  await proxy.start();
  // Continuous per-session video producer (Jellyfin-style): one ffmpeg per
  // session stream-copies the video into fMP4 segments on disk, preserving
  // open-GOP leading pictures so playback is gapless.
  final producerManager = ProducerManager(
    config: ProducerConfig(
      ffmpegBin: config.ffmpegBin,
      tempRoot:
          config.hlsProducerTemp ?? '${Directory.systemTemp.path}/cineseed_hls',
      targetSeconds: config.hlsSegmentSeconds,
      throttleAheadSegments: config.hlsThrottleAhead,
      debug: config.debug,
    ),
    maxSessions: config.hlsMaxSessions,
  );
  await producerManager
      .sweepStaleTempDirs(); // clean leftovers from a prior run
  final segments = SegmentGenerator(
    pool: pool,
    producerManager: producerManager,
    ffmpegBin: config.ffmpegBin,
    audioBitrate: config.hlsAudioBitrate,
    debug: config.debug,
  );
  final hls = HlsSessionManager(
    signer: signer,
    client: client,
    proxy: proxy,
    ffprobeBin: config.ffprobeBin,
    targetSegmentSeconds: config.hlsSegmentSeconds,
    ttl: Duration(seconds: config.streamUrlTtl),
    idleTtl: Duration(seconds: config.hlsSessionIdleTtl),
    maxSessions: config.hlsMaxSessions,
    // Pre-warm the video init (and thus master CODECS) while the proxy cache is
    // hot, so the first master.m3u8 request doesn't pay the ffmpeg open cost.
    onReady: (s) => segments.videoInit(s),
    // Kill the live producer when a session is evicted (TTL).
    onEvict: (hash) => producerManager.killSession(hash),
  );
  // Release idle sessions (producer + proxy chunks) on a timer, not only as a
  // side effect of an incoming request.
  hls.startSweeping();

  final root = Router();
  root.mount(
    '/api',
    buildApiRouter(
      tracker: tracker,
      client: client,
      signer: signer,
      downloadDir: config.downloadDir,
      incompleteDir: config.incompleteDir,
      hls: hls,
      segments: segments,
      tmdb: tmdb,
      debug: config.debug,
    ).call,
  );

  // Static Flutter web build (prod). During local testing the frontend runs
  // separately, so this just 404s if there's no build.
  final publicExists = Directory(config.publicDir).existsSync();
  final Handler staticHandler = publicExists
      ? createStaticHandler(config.publicDir, defaultDocument: 'index.html')
      : (Request req) => Response.notFound('No web build on this instance.');

  // SPA fallback: any non-API 404 is served as index.html so go_router can
  // handle client-side routing for deep-linked URLs like /watch/:hash.
  final indexFile = File('${config.publicDir}/index.html');
  FutureOr<Response> spaFallback(Request req) {
    final path = req.url.path;
    if (path == 'api' ||
        path.startsWith('api/') ||
        !publicExists ||
        !indexFile.existsSync()) {
      return Response.notFound('Not found.');
    }
    return Response.ok(
      indexFile.readAsBytesSync(),
      headers: {'content-type': 'text/html; charset=utf-8'},
    );
  }

  final handler = const Pipeline()
      .addMiddleware(logRequests())
      .addMiddleware(corsHeaders())
      .addHandler(
        Cascade().add(root.call).add(staticHandler).add(spaFallback).handler,
      );

  final server = await io.serve(handler, InternetAddress.anyIPv4, config.port);

  // Graceful shutdown: stop accepting connections, kill all live ffmpeg
  // producers (+ their temp dirs), and stop the range proxy.
  var shuttingDown = false;
  Future<void> shutdown(ProcessSignal _) async {
    if (shuttingDown) return;
    shuttingDown = true;
    await server.close(force: true);
    hls.dispose();
    await producerManager.killAll();
    await proxy.stop();
    exit(0);
  }

  ProcessSignal.sigterm.watch().listen(shutdown);
  ProcessSignal.sigint.watch().listen(shutdown);

  return server;
}
