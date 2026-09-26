import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'log.dart';
import 'hls_session.dart';
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
/// segments exactly. SUBTITLE windows stay separate (text, no sync concern) and
/// are still built with the ephemeral muxer below; [videoInit] is kept only to
/// derive the master playlist's video CODECS string and the video timescale.
class SegmentGenerator {
  final TranscodePool pool;
  final ProducerManager producerManager;
  final String ffmpegBin;
  final String audioBitrate;
  final double readMargin; // extra input seconds for subtitle windows
  final Duration vttTimeout; // wall-clock cap on one subtitle-window extraction
  final bool debug; // verbose ffmpeg (init/subtitle muxers) + keep temp dirs

  /// In-flight WebVTT segment extractions, keyed `s:<track>:<i>`.
  final Map<String, Future<(String, bool)>> _vttInflight = {};

  SegmentGenerator({
    required this.pool,
    required this.producerManager,
    this.ffmpegBin = 'ffmpeg',
    this.audioBitrate = '192k',
    this.readMargin = 1.5,
    // Under hls.js's default fragLoadPolicy TTFB cap (9 s) — the body is only
    // sent once ffmpeg exits, so extraction time *is* the time to first byte.
    this.vttTimeout = const Duration(seconds: 6),
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

  // --- subtitles (windowed extract, cached) ---

  /// Extracts the WebVTT cues for one media-aligned window (segment [i] of
  /// subtitle track [subOrder]).
  ///
  /// The `-t` bound MUST be an output option: as an *input* option it never
  /// terminates a subtitle-only mapping, so ffmpeg demuxes the whole remote MKV
  /// (measured: 45 s locally, ~2 min from the server, for a 10 s window — well
  /// past hls.js's 9 s TTFB cap, so it retries a few times then drops the track
  /// and no subtitle ever shows). On the output side the muxer stops as soon as
  /// a cue passes the limit (~1 s), and the cues are actually windowed.
  ///
  /// Output-side `-t` only advances on emitted cues though, so on a *gap*
  /// (silent intro, or a sparse/forced track) ffmpeg reads forward hunting for
  /// the next cue — measured 10–20 s locally on the forced track. So we also
  /// cap the wall-clock and kill it, keeping whatever was written: cues are
  /// emitted in order, so anything inside the window is already out, and empty
  /// is the correct answer for a gap. The kill stays under hls.js's fragment
  /// timeout, and the output is trimmed to the last complete cue so a SIGKILL
  /// mid-write can't hand hls.js a half-written cue.
  ///
  /// Cached per (track, segment) — but a *killed* run is served without being
  /// cached: it is the one case where the answer may be short (a slow cold read
  /// of a window that does have cues), so the next request re-runs it against a
  /// then-warm proxy cache instead of pinning an empty segment forever.
  /// Concurrent requests share one run.
  Future<String?> vttSegment(HlsSession s, int subOrder, int i) async {
    if (subOrder < 0 || subOrder >= s.probe.subtitles.length) return null;
    if (!s.probe.subtitles[subOrder].isText) return null;
    if (i < 0 || i >= s.segmentCount) return null;

    final key = 's:$subOrder:$i';
    final cached = s.vttCached(key);
    if (cached != null) return cached;

    final fut = _vttInflight[key] ??= () async {
      final start = s.segStart(i);
      final dur = s.segDuration(i);
      return pool.run(() => _extractVttWindow(s, subOrder, start, dur));
    }();

    try {
      final (text, killed) = await fut;
      if (!killed) s.cacheVtt(key, text);
      return text;
    } finally {
      _vttInflight.remove(key);
    }
  }

  /// Returns the window's WebVTT and whether the wall-clock cap killed ffmpeg
  /// (see [vttSegment]: a killed run is not cached).
  Future<(String, bool)> _extractVttWindow(
    HlsSession s,
    int subOrder,
    double start,
    double dur,
  ) async {
    final proc = await Process.start(ffmpegBin, [
      '-nostdin', '-loglevel', debug ? 'verbose' : 'error',
      '-rw_timeout', '30000000',
      // Reconnect when the proxy closes the connection at its maxServeBytes
      // cap. NOT -reconnect_at_eof: the windows near the end of the file hit
      // real EOF while the muxer waits for the cue that ends them, and treating
      // that as an error made ffmpeg reconnect in a loop (measured 10.9 s vs
      // 2.7 s for identical cues). The proxy always sends a Content-Range with
      // the total size, so the input stays seekable and a short 206 is resumed
      // with a fresh range request — the EOF retry buys nothing here.
      '-reconnect', '1',
      '-reconnect_streamed', '1',
      '-reconnect_delay_max', '5',
      '-ss', start.toStringAsFixed(3),
      '-i', s.url,
      '-map', '0:s:$subOrder',
      // A little past the window so a boundary-straddling cue is captured;
      // hls.js de-duplicates cues shared with the next segment. Output-side —
      // see the doc comment: an input-side -t reads the whole file.
      '-t', (dur + readMargin).toStringAsFixed(3),
      // Shift cues back onto the programme timeline. `-ss` resets timestamps
      // to 0 at the seek point; this re-adds the segment start so hls.js
      // places cues at the right time instead of stacking every segment at 0.
      '-output_ts_offset', start.toStringAsFixed(3),
      // Write every cue through to the pipe as it is muxed, so the cues already
      // past the muxer survive a SIGKILL instead of dying in the AVIO buffer.
      '-flush_packets', '1',
      '-f', 'webvtt', 'pipe:1',
    ]);
    final out = BytesBuilder(copy: false);
    final stdoutDone = proc.stdout.forEach(out.add);
    unawaited(proc.stderr.drain<void>());
    var killed = false;
    final killer = Timer(vttTimeout, () {
      killed = true;
      Log.d(
        'hls',
        's:$subOrder @${start.toStringAsFixed(1)}s vtt extract '
            'hit ${vttTimeout.inSeconds}s cap — killing',
      );
      proc.kill(ProcessSignal.sigkill);
    });
    await proc.exitCode;
    killer.cancel();
    await stdoutDone;
    final text = utf8.decode(out.takeBytes(), allowMalformed: true);
    // Always hand back a valid body so hls.js treats a gap as loaded-empty.
    return (
      text.contains('WEBVTT') ? trimPartialCue(text) : 'WEBVTT\n\n',
      killed,
    );
  }

  /// A `-->` timing line plus at least one complete text line, at the end.
  static final _wholeCue = RegExp(r'-->[^\n]*\n(?:[^\n]+\n)+$');

  /// Drops a trailing incomplete cue block. WebVTT blocks are separated by a
  /// blank line; a SIGKILL (or a truncated pipe) can cut one mid-write, and
  /// hls.js throws while parsing that. The block after the last blank line is
  /// only kept when it is already whole.
  static String trimPartialCue(String vtt) {
    final lastBreak = vtt.lastIndexOf('\n\n');
    if (lastBreak < 0) return vtt;
    final tail = vtt.substring(lastBreak + 2);
    if (tail.isEmpty || _wholeCue.hasMatch(tail)) return vtt;
    return vtt.substring(0, lastBreak + 2);
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
