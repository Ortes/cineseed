import 'dart:async';
import 'dart:io';

import 'package:hls_remux/hls_remux.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as io;
import 'package:shelf_cors_headers/shelf_cors_headers.dart';
import 'package:shelf_router/shelf_router.dart';
import 'package:shelf_static/shelf_static.dart';

import 'api.dart';
import 'config.dart';
import 'media/torrent_media_resolver.dart';
import 'storage/s3_offloader.dart';
import 'storage/s3_signer.dart';
import 'torrent/torrent_client.dart';
import 'torrent/transmission_client.dart';
import 'tracker/torznab_tracker.dart';
import 'tracker/tracker_connector.dart';
import 'tracker/tmdb_client.dart';

/// A running Cineseed server. [close] stops accepting connections, kills every
/// live ffmpeg producer (+ its temp dir) and stops the range proxy.
class CineseedServer {
  CineseedServer._(this.http, this._onClose);

  final HttpServer http;
  final Future<void> Function() _onClose;
  Future<void>? _closing;

  Future<void> close() => _closing ??= _onClose();
}

/// Wires the tracker + torrent client + storage into a shelf handler and
/// serves it.
///
/// Every dependency defaults to the implementation [config] describes; pass
/// one to swap it (another torrent client, indexer, …) without forking.
/// Without S3 ([s3] null and none in [config]) films stay on the local disk.
Future<CineseedServer> startServer(
  Config config, {
  TrackerConnector? tracker,
  TorrentClient? client,
  S3Signer? s3,
  TmdbClient? tmdb,
}) async {
  Log.prefix = 'cineseed';
  Log.enabled = config.debug;
  if (config.debug) {
    Log.d('boot', 'CINESEED_DEBUG on: verbose logging + segments kept on disk');
  }

  tracker ??= TorznabTracker(
    baseUrl: config.trackerBaseUrl,
    apiKey: config.trackerApiKey,
  );
  client ??= TransmissionClient(
    url: config.transmissionUrl,
    user: config.transmissionUser,
    pass: config.transmissionPass,
  );
  final s3Config = config.s3;
  final signer =
      s3 ??
      (s3Config == null
          ? null
          : S3Signer(
              endpoint: s3Config.endpoint,
              region: s3Config.region,
              bucket: s3Config.bucket,
              accessKey: s3Config.accessKey,
              secretKey: s3Config.secretKey,
              defaultTtl: config.streamUrlTtl,
            ));
  Log.w(
    'boot',
    signer == null
        ? 'storage: local disk only (no S3 configured)'
        : 'storage: S3 offload, post-upload dir ${config.downloadDir}',
  );
  final offload = signer == null
      ? null
      : S3Offloader(
          client: client,
          signer: signer,
          postUploadDir: config.downloadDir,
        );
  // Serves local files to ffmpeg for HLS when there is no S3.
  final localFiles = signer == null ? LocalRangeServer() : null;
  await localFiles?.start();
  tmdb ??= (config.tmdbApiKey != null && config.tmdbApiKey!.isNotEmpty)
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
    resolver: TorrentMediaResolver(
      client: client,
      signer: signer,
      ttl: Duration(seconds: config.streamUrlTtl),
      downloadDir: config.downloadDir,
      incompleteDir: config.incompleteDir,
    ),
    proxy: proxy,
    localFiles: localFiles,
    ffprobeBin: config.ffprobeBin,
    targetSegmentSeconds: config.hlsSegmentSeconds,
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

  final api = buildApiRouter(
    tracker: tracker,
    client: client,
    offload: offload,
    downloadDir: config.downloadDir,
    incompleteDir: config.incompleteDir,
    hls: hls,
    segments: segments,
    tmdb: tmdb,
    debug: config.debug,
  );
  final root = Router()..mount('/api', api.router.call);

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

  return CineseedServer._(server, () async {
    await server.close(force: true);
    api.dispose();
    hls.dispose();
    await producerManager.killAll();
    await proxy.stop();
    await localFiles?.stop();
  });
}
