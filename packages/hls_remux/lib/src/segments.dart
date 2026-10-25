import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'log.dart';
import 'hls_session.dart';
import 'mkv_cues.dart';
import 'mkv_subtitles.dart';
import 'mp4_boxes.dart';
import 'producer_manager.dart';
import 'segment_producer.dart';
import 'segment_ref.dart';
import 'transcode_pool.dart';

/// Generates HLS init/media segments on demand by driving ffmpeg against the
/// session's presigned S3 URL.
///
/// Jellyfin-style MUXED model: one continuous per-session ffmpeg run (see
/// [ProducerManager]/[SegmentProducer]) copies the video and transcodes the
/// chosen audio track to AAC into a *single* fMP4 stream, keyed
/// `m:<hash>:<track>`. Muxing both tracks in one process is what guarantees A/V
/// sync — the muxer interleaves them on one timeline — and running continuously
/// preserves open-GOP RASL leading pictures (no per-segment seek drops them) so
/// playback is gapless. Switching audio language restarts the producer at a new
/// track (a brief rebuffer; an acceptable trade for guaranteed sync). The
/// served init comes from the producer's own `init.mp4` so it matches the
/// segments exactly. SUBTITLE windows stay separate (text, no sync concern):
/// they are read straight from the MKV. [videoInit] is kept only to derive the
/// master playlist's video CODECS string and the video timescale.
class SegmentGenerator {
  final TranscodePool pool;
  final ProducerManager producerManager;
  final String ffmpegBin;
  final String audioBitrate;
  final bool debug; // verbose ffmpeg (init muxer) + keep temp dirs

  /// In-flight WebVTT segment reads, keyed `s:<track>:<i>`.
  final Map<String, Future<String>> _vttInflight = {};

  /// Reads the session URL for subtitle cluster scans.
  final http.Client _http = http.Client();

  SegmentGenerator({
    required this.pool,
    required this.producerManager,
    this.ffmpegBin = 'ffmpeg',
    this.audioBitrate = '192k',
    this.debug = false,
  });

  // --- init segments ---

  Future<Uint8List> videoInit(HlsSession s) {
    if (s.videoInit != null) return Future.value(s.videoInit!);
    // Dedupe concurrent builds (pre-warm on session-ready + the master/init
    // request can race) so we only run ffmpeg once.
    return s.videoInitFuture ??= _buildVideoInit(s);
  }

  Future<Uint8List> _buildVideoInit(HlsSession s) async {
    final isHevc = (s.probe.video?.codec ?? '').toLowerCase() == 'hevc';
    final (init, _) = await pool.run(
      () => _runMuxer(
        url: s.url,
        start: 0,
        durationLimit: 0.2,
        hlsTime: 9999,
        mapArgs: [
          '-map',
          '0:v:0',
          '-c:v',
          'copy',
          if (isHevc) ...['-tag:v', 'hvc1'],
        ],
      ),
    );
    s.videoInit = init;
    s.videoTimescale = Mp4Boxes.readTimescale(init);
    s.videoCodecString = isHevc ? Mp4Boxes.hevcCodecString(init) : _avcCodec(s);
    return init;
  }

  /// Muxed init (video + the chosen audio [track]) served from the continuous
  /// producer's own `init.mp4`, so it matches the producer's segments exactly.
  /// Keyed `m:<hash>:<track>`. Requires [videoInit] first for the video
  /// timescale used by the producer's tfdt verification.
  Future<Uint8List?> muxedInit(HlsSession s, int track) async {
    if (track < 0 || track >= s.probe.audio.length) return null;
    await videoInit(s);
    return producerManager.getInit(
      key: 'm:${s.id}:$track',
      url: s.url,
      boundaries: s.producerBoundaries,
      timescale: s.videoTimescale ?? 90000,
      outputArgs: _muxedArgs(s, track),
      audioGrid: _audioGrid(s, track),
    );
  }

  // --- media segments (continuous muxed producer) ---

  /// Jellyfin-style muxed segment: one continuous ffmpeg copies the video and
  /// transcodes the chosen audio [track] to AAC into a single fMP4 stream, keyed
  /// `m:<hash>:<track>`. Muxing both tracks in one process is what guarantees
  /// A/V sync (the muxer interleaves them on one timeline); running continuously
  /// preserves open-GOP RASL leading pictures so playback is gapless. Switching
  /// audio language restarts the producer at a new track (a brief rebuffer).
  /// Playlist entry [i] spans producer files `groupStart[i]..groupStart[i+1]-1`
  /// (boundaries are grouped to a minimum duration — see
  /// [HlsSession.groupBoundaries]); the files are fetched in order from the
  /// continuous producer and concatenated. Each is a self-contained
  /// `moof+mdat` with an absolute tfdt, so the concatenation is a valid
  /// multi-fragment (CMAF-chunk-style) segment that hls.js appends as one.
  /// The parts are returned as [SegmentRef]s and streamed back-to-back rather
  /// than concatenated: a grouped entry used to allocate one buffer per part plus
  /// another for the whole group, so peak heap scaled with segment size times
  /// concurrent requests, unbounded. Now only each part's `moof` header is in
  /// memory. The caller MUST consume or dispose the result exactly once.
  Future<MuxedSegment?> muxedSegment(HlsSession s, int track, int i) async {
    if (track < 0 || track >= s.probe.audio.length) return null;
    if (i < 0 || i + 1 >= s.groupStart.length) return null;
    await videoInit(s); // ensures videoTimescale is known for tfdt verify
    final parts = <SegmentRef>[];
    for (var k = s.groupStart[i]; k < s.groupStart[i + 1]; k++) {
      final ref = await producerManager.getSegment(
        key: 'm:${s.id}:$track',
        url: s.url,
        boundaries: s.producerBoundaries,
        timescale: s.videoTimescale ?? 90000,
        outputArgs: _muxedArgs(s, track),
        audioGrid: _audioGrid(s, track),
        i: k,
      );
      if (ref == null) {
        // 404 → hls.js retries the whole entry. Release the handles already
        // taken, or they leak for every failed entry.
        for (final p in parts) {
          await p.dispose();
        }
        return null;
      }
      parts.add(ref);
    }
    return MuxedSegment(parts);
  }

  /// ffmpeg map/codec args for a muxed (video copy + AAC audio) stream.
  List<String> _muxedArgs(HlsSession s, int track) {
    final isHevc = (s.probe.video?.codec ?? '').toLowerCase() == 'hevc';
    final a = s.probe.audio[track];
    return [
      '-map',
      '0:v:0',
      '-c:v',
      'copy',
      if (isHevc) ...['-tag:v', 'hvc1'],
      ..._audioMapArgs(a.order, a),
    ];
  }

  AudioGrid _audioGrid(HlsSession s, int track) {
    final a = s.probe.audio[track];
    return AudioGrid(sampleRate: a.sampleRate, origin: a.startTime);
  }

  // --- subtitles (read from the MKV, cached) ---

  /// The WebVTT for segment [i] of subtitle track [subOrder], read straight
  /// from the file's subtitle blocks (see [MkvSubtitles]). Cached per (track,
  /// segment); concurrent requests share one read.
  ///
  /// A failed read throws rather than answer an empty segment: hls.js keeps a
  /// 200 for good and never asks again, so a short answer would hide those
  /// cues for the rest of the session. An error is a 5xx, which it retries.
  Future<String?> vttSegment(HlsSession s, int subOrder, int i) async {
    if (subOrder < 0 || subOrder >= s.probe.subtitles.length) return null;
    if (!s.probe.subtitles[subOrder].isText) return null;
    if (i < 0 || i >= s.segmentCount) return null;
    final tracks = s.cues.subtitleTracks;
    if (tracks.length != s.probe.subtitles.length) {
      Log.w(
        'hls',
        '${s.id}: ${tracks.length} subtitle tracks in Tracks, '
            '${s.probe.subtitles.length} probed — no subtitles',
      );
      return null;
    }

    final key = 's:$subOrder:$i';
    final cached = s.vttCached(key);
    if (cached != null) return cached;

    final fut = _vttInflight[key] ??= MkvSubtitles.window(
      s.cues,
      tracks[subOrder],
      s.segStart(i),
      s.segEnd(i),
      direct: s.subtitleBytes,
      scan: httpRangeReader(s.url, _http),
    );
    try {
      final text = await fut;
      s.cacheVtt(key, text);
      return text;
    } finally {
      _vttInflight.remove(key);
    }
  }

  // --- helpers ---

  List<String> _audioMapArgs(int order, audio) => [
    '-map',
    '0:a:$order',
    '-c:a',
    'aac',
    '-b:a',
    audioBitrate,
    '-ac',
    '${audio.channels}',
  ];

  /// Runs ffmpeg's HLS fMP4 muxer in a temp dir; returns (initBytes, seg0Bytes).
  /// Used only to build the init segments (video + audio); media segments come
  /// from the continuous [SegmentProducer]s.
  Future<(Uint8List, Uint8List?)> _runMuxer({
    required String url,
    required double start,
    required double durationLimit,
    required double hlsTime,
    required List<String> mapArgs,
  }) async {
    final dir = await Directory.systemTemp.createTemp('hls_');
    try {
      final args = <String>[
        '-nostdin', '-y', '-loglevel', debug ? 'verbose' : 'error',
        // Don't hang forever if the proxy/upstream stalls. (No -multiple_requests:
        // ffmpeg should close+reopen on each seek so the proxy's per-request
        // window ends cleanly instead of being held open by keep-alive.)
        '-rw_timeout', '30000000', // 30 s in microseconds
        '-ss', _fmt(start),
        '-i', url,
        if (durationLimit > 0) ...['-t', _fmt(durationLimit)],
        ...mapArgs,
        '-f', 'hls',
        '-hls_time', _fmt(hlsTime),
        '-hls_segment_type', 'fmp4',
        '-hls_fmp4_init_filename', 'init.mp4',
        '-hls_segment_filename', '${dir.path}/seg%d.m4s',
        '-hls_list_size', '0',
        '-hls_flags', 'independent_segments',
        '${dir.path}/out.m3u8',
      ];
      final dbg = Log.enabled;
      final sw = dbg ? (Stopwatch()..start()) : null;
      Log.d('seg', 'init/mux ffmpeg start ss=$start dur=$durationLimit');
      final res = await Process.run(ffmpegBin, args);
      if (dbg) {
        Log.d(
          'seg',
          'init/mux ffmpeg exit=${res.exitCode} ss=$start '
              'in ${sw!.elapsedMilliseconds}ms',
        );
        if (res.exitCode == 0 && '${res.stderr}'.trim().isNotEmpty) {
          stderr.write('[ffmpeg:seg] ${res.stderr}');
        }
      }
      if (res.exitCode != 0) {
        throw ProcessException(ffmpegBin, args, '${res.stderr}', res.exitCode);
      }
      final init = File('${dir.path}/init.mp4');
      final seg0 = File('${dir.path}/seg0.m4s');
      final initBytes = init.existsSync()
          ? Uint8List.fromList(init.readAsBytesSync())
          : Uint8List(0);
      final segBytes = seg0.existsSync()
          ? Uint8List.fromList(seg0.readAsBytesSync())
          : null;
      return (initBytes, segBytes);
    } finally {
      // Always clean up the temp dir (and any extra segments the muxer wrote) —
      // unless debug mode is keeping everything on disk for inspection.
      if (debug) {
        Log.d('seg', 'KEEP init/mux temp dir: ${dir.path}');
      } else {
        try {
          await dir.delete(recursive: true);
        } catch (_) {}
      }
    }
  }

  String _avcCodec(HlsSession s) {
    // Minimal fallback for H.264 sources; refined codec string would parse
    // avcC.
    return 'avc1.640028';
  }

  static String _fmt(double v) => v.toStringAsFixed(6);
}
