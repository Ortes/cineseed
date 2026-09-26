import 'dart:io';

/// Runtime configuration, read from environment variables. Secrets are NEVER
/// committed — they come from the server's `.env` (docker --env-file) or the
/// process environment. See `.env.example` for the full list.
class Config {
  final String trackerApiKey;
  final String trackerBaseUrl;
  final String transmissionUrl;
  final String? transmissionUser;
  final String? transmissionPass;
  final String s3Endpoint;
  final String s3Region;
  final String s3Bucket;
  final String s3AccessKey;
  final String s3SecretKey;
  final int streamUrlTtl; // seconds
  final int port;
  final String publicDir;
  final String downloadDir; // final destination (e.g. an rclone mount of the S3 bucket)
  final String incompleteDir; // local disk where Transmission writes during download
  final String? tmdbApiKey; // optional — disables /api/tmdb when empty
  // Live HLS streaming knobs.
  final String ffmpegBin;
  final String ffprobeBin;
  final double hlsSegmentSeconds;
  final int hlsMaxTranscodes;
  final String hlsAudioBitrate;
  // Latency-optimization knobs (caching range proxy).
  final int hlsProxyChunkMb; // upstream fetch granularity
  final int hlsProxyReadahead; // chunks to prefetch ahead of the read head
  final int hlsProxyCacheMb; // global proxy chunk-cache cap
  final int hlsProxyMaxServeMb; // max bytes served per proxy request
  final int hlsProxyMaxConcurrent; // concurrent proxy responses (excess queues)
  // Continuous video producer (Jellyfin-style live segmentation).
  final int hlsThrottleAhead; // pause ffmpeg when this many segments ahead
  final int hlsMaxSessions; // concurrent live video producers
  final int hlsSessionIdleTtl; // seconds a session may idle before eviction
  final String? hlsProducerTemp; // temp root for produced segments (null => system temp)
  // Verbose debug mode: full ffmpeg/producer/session logging + keep all segment
  // files on disk (no cleanup). Exposed to the frontend via GET /api/config.
  final bool debug;

  const Config({
    required this.trackerApiKey,
    required this.trackerBaseUrl,
    required this.transmissionUrl,
    required this.transmissionUser,
    required this.transmissionPass,
    required this.s3Endpoint,
    required this.s3Region,
    required this.s3Bucket,
    required this.s3AccessKey,
    required this.s3SecretKey,
    required this.streamUrlTtl,
    required this.port,
    required this.publicDir,
    required this.downloadDir,
    required this.incompleteDir,
    required this.tmdbApiKey,
    required this.ffmpegBin,
    required this.ffprobeBin,
    required this.hlsSegmentSeconds,
    required this.hlsMaxTranscodes,
    required this.hlsAudioBitrate,
    required this.hlsProxyChunkMb,
    required this.hlsProxyReadahead,
    required this.hlsProxyCacheMb,
    required this.hlsProxyMaxServeMb,
    required this.hlsProxyMaxConcurrent,
    required this.hlsThrottleAhead,
    required this.hlsMaxSessions,
    required this.hlsSessionIdleTtl,
    required this.hlsProducerTemp,
    required this.debug,
  });

  factory Config.fromEnv([Map<String, String>? environment]) {
    final env = environment ?? Platform.environment;

    String required(String key) {
      final v = env[key];
      if (v == null || v.isEmpty) {
        throw StateError('Missing required environment variable: $key');
      }
      return v;
    }

    String optional(String key, String fallback) {
      final v = env[key];
      return (v == null || v.isEmpty) ? fallback : v;
    }

    return Config(
      trackerApiKey: required('CINESEED_TRACKER_APIKEY'),
      trackerBaseUrl: required('CINESEED_TRACKER_BASEURL'),
      transmissionUrl: optional(
          'TRANSMISSION_URL', 'http://localhost:9091/transmission/rpc'),
      transmissionUser: env['TRANSMISSION_USER'],
      transmissionPass: env['TRANSMISSION_PASS'],
      s3Endpoint: required('S3_ENDPOINT'),
      s3Region: optional('S3_REGION', 'us-east-1'),
      s3Bucket: required('S3_BUCKET'),
      s3AccessKey: required('S3_ACCESS_KEY'),
      s3SecretKey: required('S3_SECRET_KEY'),
      streamUrlTtl: int.tryParse(optional('STREAM_URL_TTL', '21600')) ?? 21600,
      port: int.tryParse(optional('PORT', '8080')) ?? 8080,
      publicDir: optional('PUBLIC_DIR', 'public'),
      downloadDir: optional('DOWNLOAD_DIR', '/mnt/torrents'),
      incompleteDir: optional('INCOMPLETE_DIR', ''),
      tmdbApiKey: env['TMDB_API_KEY'],
      ffmpegBin: optional('FFMPEG_BIN', 'ffmpeg'),
      ffprobeBin: optional('FFPROBE_BIN', 'ffprobe'),
      // Minimum PLAYLIST segment duration: keyframe intervals are grouped up
      // to this floor (HlsSession.groupBoundaries). Must stay well above the
      // ~0.2s muxed audio interleave lag or hls.js deadlocks on micro-segments.
      hlsSegmentSeconds:
          double.tryParse(optional('HLS_SEGMENT_SECONDS', '4')) ?? 4,
      hlsMaxTranscodes: int.tryParse(optional('HLS_MAX_TRANSCODES', '3')) ?? 3,
      hlsAudioBitrate: optional('HLS_AUDIO_BITRATE', '192k'),
      hlsProxyChunkMb: int.tryParse(optional('HLS_PROXY_CHUNK_MB', '8')) ?? 8,
      hlsProxyReadahead:
          int.tryParse(optional('HLS_PROXY_READAHEAD', '3')) ?? 3,
      // Kept modest: sized for a swapless ~1 GB box. The old 256 MB default
      // exhausted RAM and froze the whole process in kernel direct-reclaim (PSI
      // full-memory stalls, CPU never full). This is the only sizeable in-memory
      // cache; 64 MB leaves reclaimable headroom for ffmpeg.
      hlsProxyCacheMb:
          int.tryParse(optional('HLS_PROXY_CACHE_MB', '64')) ?? 64,
      hlsProxyMaxServeMb:
          int.tryParse(optional('HLS_PROXY_MAX_SERVE_MB', '16')) ?? 16,
      // Bounds how many chunks live responses can hold references to at once.
      // Excess requests QUEUE (never 503 — ffmpeg has no
      // -reconnect_on_http_error, so a reject would kill the producer).
      hlsProxyMaxConcurrent:
          int.tryParse(optional('HLS_PROXY_MAX_CONCURRENT', '6')) ?? 6,
      hlsThrottleAhead:
          int.tryParse(optional('HLS_THROTTLE_AHEAD', '30')) ?? 30,
      hlsMaxSessions: int.tryParse(optional('HLS_MAX_SESSIONS', '3')) ?? 3,
      // Distinct from STREAM_URL_TTL: how long a session may sit unused before
      // its producer is killed and its proxy chunks freed. Sharing the presign
      // TTL (6 h) kept both alive long after anyone stopped watching.
      hlsSessionIdleTtl:
          int.tryParse(optional('HLS_SESSION_IDLE_TTL', '600')) ?? 600,
      hlsProducerTemp: env['HLS_PRODUCER_TEMP'],
      debug: optional('CINESEED_DEBUG', 'false').toLowerCase() == 'true',
    );
  }
}
