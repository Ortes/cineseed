import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../src/log.dart';
import 'mp4_boxes.dart';
import 'segment_ref.dart';

/// Tunables for the continuous segment producer. Plain data, no external deps —
/// this whole file is intended to be extraction-ready as part of a standalone
/// "stream video from S3" library.
class ProducerConfig {
  final String ffmpegBin;
  final String tempRoot; // parent dir for per-session subdirs
  final double
  targetSeconds; // nominal segment length (kept for config compat);
  // the producer cuts at every keyframe regardless — see _launch's -hls_time
  final int throttleAheadSegments; // pause ffmpeg when this far ahead of client
  final int retainBehindSegments; // keep this many consumed segments behind the
  // client before deleting; a backward seek past them restarts the producer
  final Duration pollInterval; // disk scan / waiter resolution cadence
  final Duration
  segmentTimeout; // max wait for one segment (< hls.js fragLoadingTimeOut)
  final Duration idleKillDelay; // kill after this long with no active requests
  final int
  restartReorderWindow; // serve-by-wait vs restart threshold (segments)
  // Verbose debug: ffmpeg at -loglevel verbose with live stderr passthrough,
  // lifecycle logging, and segment temp dirs kept on disk (never deleted).
  final bool debug;

  const ProducerConfig({
    required this.ffmpegBin,
    required this.tempRoot,
    this.targetSeconds = 6,
    this.throttleAheadSegments = 30,
    this.retainBehindSegments = 50,
    this.pollInterval = const Duration(milliseconds: 100),
    this.segmentTimeout = const Duration(seconds: 18),
    this.idleKillDelay = const Duration(seconds: 60),
    this.restartReorderWindow = 3,
    this.debug = false,
  });
}

enum _State { running, throttled, dead }

/// One long-lived ffmpeg process per (session, track) that produces fMP4 HLS
/// segments continuously to a temp dir. The track is defined entirely by
/// [outputArgs] (e.g. `-map 0:v:0 -c:v copy -tag:v hvc1` for video, or
/// `-map 0:a:0 -c:a aac -b:a 192k -ac 6` for audio), so the same machinery
/// drives video and audio.
///
/// Unlike per-segment `-ss` seeks, a continuous run preserves open-GOP RASL
/// leading pictures at every interior boundary (the browser's single MSE
/// decoder uses the previous segment still in its buffer), so playback is
/// gapless; and because video and audio both ride one true source timeline
/// (`-copyts`) they stay in sync. Timestamps are absolute by construction; a
/// per-run verification + constant-offset patch covers the case where a
/// mid-file `-ss` origin comes out shifted. Absolute tfdt across restarts is
/// guaranteed by `-hls_segment_options movflags=+frag_discont` (see _launch).
class SegmentProducer {
  final String label; // for logs/keys, e.g. 'v:<hash>' or 'a:<hash>:<track>'
  final String url; // stable loopback proxy URL
  final List<double> boundaries; // segmentCount + 1 entries
  final int timescale; // track timescale (ticks/sec)
  final int startSegment; // playlist index ffmpeg started at
  final List<String> outputArgs; // -map/-c args defining the track
  final ProducerConfig config;

  late final Directory _tempDir;
  Process? _process;
  _State _state = _State.running;
  final bool _useSetsid = Platform.isLinux;

  int _highWater = -1; // highest produced segment index on disk
  int _floor = 0; // lowest segment index still on disk (pruned below this)
  int _clientSegment = 0; // last index a client asked for
  int _refCount = 0;
  Timer? _scanTimer;
  Timer? _idleTimer;
  final Map<int, List<Completer<SegmentRef?>>> _waiters = {};

  // tfdt normalization (computed once, when the first segment appears).
  bool _tfdtChecked = false;
  int _tfdtCorrection = 0; // subtracted from each segment's tfdt before serving

  final StringBuffer _stderr = StringBuffer();

  SegmentProducer._({
    required this.label,
    required this.url,
    required this.boundaries,
    required this.timescale,
    required this.startSegment,
    required this.outputArgs,
    required this.config,
  });

  int get segmentCount => boundaries.length - 1;
  bool get isAlive => _state != _State.dead;
  int get highWater => _highWater;
  String get tempPath => _tempDir.path;
  File _segFile(int i) => File('${_tempDir.path}/$i.m4s');

  /// True if the running producer can serve [i] without a restart: it's at or
  /// behind the production frontier (plus a small reorder window for in-flight
  /// segments), and at/above the current floor (segments below it were pruned as
  /// the client advanced, so a backward seek past the floor must restart ffmpeg).
  bool canServe(int i) =>
      i >= _floor && i <= _highWater + config.restartReorderWindow;

  static Future<SegmentProducer> start({
    required String label,
    required String url,
    required List<double> boundaries,
    required int timescale,
    required int startSegment,
    required List<String> outputArgs,
    required ProducerConfig config,
  }) async {
    final p = SegmentProducer._(
      label: label,
      url: url,
      boundaries: boundaries,
      timescale: timescale,
      startSegment: startSegment,
      outputArgs: outputArgs,
      config: config,
    );
    await p._launch();
    return p;
  }

  Future<void> _launch() async {
    final safe = label.replaceAll(RegExp(r'[^A-Za-z0-9_]'), '_');
    _tempDir = await Directory(config.tempRoot)
        .create(recursive: true)
        .then(
          (_) => Directory(
            '${config.tempRoot}/vp_${safe}_${startSegment}_${DateTime.now().microsecondsSinceEpoch}',
          ).create(recursive: true),
        );
    _floor = startSegment;

    // Seek to the MIDPOINT of the target segment, not its start boundary.
    // `-ss <t> -noaccurate_seek` lands on the keyframe at-or-before t; seeking
    // to the start boundary can round onto the PREVIOUS keyframe (verified:
    // `-ss` on an exact keyframe time landed one keyframe early), which would
    // shift `-start_number` numbering by one. The midpoint sits strictly inside
    // [start, next), so the seek always lands on this segment's own start
    // keyframe → file `startSegment`.m4s begins exactly at boundaries[startSegment].
    final seekStart =
        (boundaries[startSegment] + boundaries[startSegment + 1]) / 2;
    final args = <String>[
      '-nostdin', '-y', '-loglevel', config.debug ? 'verbose' : 'error',
      '-rw_timeout', '30000000', // 30s; don't hang forever on a stalled socket
      // The loopback proxy caps each response at maxServeBytes (16 MiB) then
      // closes the connection. Without reconnect, ffmpeg treats that as EOF and
      // exits cleanly after only ~3-5 segments, so the "continuous" producer
      // actually dies and restarts every ~16 MiB — and each `-ss` restart makes
      // ffmpeg 5.1 re-emit fMP4 tfdt from 0 (run-relative), so the muxed decode
      // timeline jumps backwards mid-playback and the browser desyncs (out-of-
      // order appends, growing AV gaps, eventual platform-decoder abort). These
      // flags make ffmpeg reopen the proxy at the next offset and keep reading,
      // so ONE run streams the whole file with a single continuous timeline.
      // (Verified against the live proxy: reconnects at each +16 MiB boundary.)
      '-reconnect', '1',
      '-reconnect_at_eof', '1',
      '-reconnect_streamed', '1',
      '-reconnect_delay_max', '5',
      '-ss', seekStart.toStringAsFixed(6),
      '-noaccurate_seek', // copy can't decode to an exact frame; land on the keyframe
      '-i', url,
      ...outputArgs, // -map/-c args defining this track (video copy or audio aac)
      '-copyts', // keep absolute source timestamps so segments tile + A/V syncs
      '-avoid_negative_ts', 'disabled',
      '-f', 'hls',
      // Cut at EVERY keyframe (sub-frame target → split on each one). This is the
      // only segmentation rule independent of this run's `-ss` start, so the
      // produced segment indices line up with the every-keyframe playlist
      // (HlsSession.computeBoundaries) no matter where we seek. A video copy is
      // only ever split on keyframes, so this never cuts mid-GOP.
      '-hls_time', '0.01',
      '-hls_segment_type', 'fmp4',
      // The hls muxer rebases each run's fMP4 baseMediaDecodeTime (tfdt) to 0
      // after a mid-file `-ss` — `-copyts` does NOT survive into the tfdt, on
      // every ffmpeg up to at least 8.1. frag_discont makes the mp4 segment
      // muxer take the tfdt from the packets' real (absolute, -copyts) DTS
      // instead. Without it, hls.js re-aligns each restarted run via
      // sourceBuffer.timestampOffset with a ~0.2s residual error; the first
      // cluster of 0.125s micro-segments (3-frame GOPs) after a seek then
      // lands entirely behind the buffered end, hls.js marks the fragment
      // buffered without the buffer advancing, never requests the next one,
      // and playback freezes (proven on a real film, 3 consecutive micro-segments).
      '-hls_segment_options', 'movflags=+frag_discont',
      '-hls_fmp4_init_filename', 'init.mp4',
      '-hls_segment_filename', '${_tempDir.path}/%d.m4s',
      '-hls_playlist_type', 'vod',
      '-hls_list_size', '0',
      '-hls_flags', 'temp_file', // atomic rename → never read a partial .m4s
      '-start_number', '$startSegment',
      '${_tempDir.path}/out.m3u8',
    ];

    final exe = _useSetsid ? 'setsid' : config.ffmpegBin;
    final fullArgs = _useSetsid ? [config.ffmpegBin, ...args] : args;
    Log.d(
      'vp',
      '$label launch seg>=$startSegment ss=${seekStart.toStringAsFixed(3)} '
          'dir=${_tempDir.path}\n    ${config.ffmpegBin} ${args.join(' ')}',
    );
    final proc = await Process.start(exe, fullArgs);
    _process = proc;

    // Drain stderr (keep a small tail for diagnostics). Never leave it unread.
    // In debug, also stream it live (prefixed) so ffmpeg's verbose output is
    // interleaved into the backend log as it happens.
    proc.stderr.transform(const SystemEncoding().decoder).listen((chunk) {
      _stderr.write(chunk);
      if (_stderr.length > 4096) {
        final tail = _stderr.toString();
        _stderr
          ..clear()
          ..write(tail.substring(tail.length - 4096));
      }
      if (config.debug) stderr.write('[ffmpeg:$label] $chunk');
    });
    proc.stdout.drain<void>();

    // Reap on exit (listening to exitCode prevents a zombie).
    unawaited(proc.exitCode.then(_onExit));

    _scanTimer = Timer.periodic(config.pollInterval, (_) => _scan());
  }

  void _scan() {
    if (_state == _State.dead) return;
    int maxIdx = _highWater;
    // Sliding-window cleanup: delete segments the client has already passed,
    // keeping [retainBehindSegments] behind the playhead. Without this, ffmpeg's
    // `-hls_list_size 0` retains every segment for the whole film, so the temp
    // dir grows unbounded and fills the disk mid-playback. Disk stays bounded to
    // ~(retainBehind + throttleAhead) segments per track. Debug keeps everything
    // for post-mortem. Segments below the new floor sit outside canServe(), so a
    // backward seek into them restarts the producer instead of 404ing.
    final pruneBelow = config.debug
        ? -1
        : _clientSegment - config.retainBehindSegments;
    try {
      for (final e in _tempDir.listSync()) {
        if (e is! File) continue;
        final name = e.uri.pathSegments.last;
        if (!name.endsWith('.m4s')) continue;
        final idx = int.tryParse(name.substring(0, name.length - 4));
        if (idx == null) continue;
        if (idx > maxIdx) maxIdx = idx;
        if (idx < pruneBelow) {
          try {
            e.deleteSync();
          } catch (_) {}
        }
      }
    } catch (_) {
      return; // temp dir vanished mid-scan (kill race) — next tick is a no-op
    }
    if (pruneBelow > _floor) _floor = pruneBelow;
    if (maxIdx > _highWater) {
      Log.d(
        'vp',
        '$label produced seg$_highWater→$maxIdx '
            '(client@$_clientSegment, ahead=${maxIdx - _clientSegment})',
      );
      _highWater = maxIdx;
      _maybeCheckTfdt();
      // Resolve any waiters whose segment is now on disk. Each waiter gets its
      // OWN ref: a ref owns a file handle that its stream closes, so sharing one
      // between two responses would have the first close the fd under the second.
      final ready = _waiters.keys.where((i) => i <= _highWater).toList();
      for (final i in ready) {
        final completers = _waiters.remove(i)!;
        for (final c in completers) {
          if (c.isCompleted) continue;
          _openAndPatch(i).then(c.complete, onError: (_) => c.complete(null));
        }
      }
    }
    _checkThrottle();
  }

  /// On the first produced segment, check whether ffmpeg's tfdt matches the
  /// expected absolute decode time. A continuous from-0 run matches (offset ~0,
  /// no patch). A mid-file `-ss` run can come out with a shifted origin; if the
  /// offset is gross (> 0.5s) we patch every segment of this run by the constant.
  void _maybeCheckTfdt() {
    if (_tfdtChecked || _highWater < startSegment) return;
    _tfdtChecked = true;
    final f = _segFile(startSegment);
    if (!f.existsSync()) return;
    // Header only — the tfdt and traf count both live in the leading moof, so
    // there is no reason to pull a multi-MB mdat into the heap to read them.
    final bytes = _readHead(f);
    if (bytes == null) return;
    final raw = Mp4Boxes.readTfdt(bytes);
    if (raw == null) return;
    final expected = (boundaries[startSegment] * timescale).round();
    final offset = raw - expected;
    if (offset.abs() <= (timescale * 0.5)) return;
    // A muxed segment carries two tracks on two timescales; a single constant
    // (in the video timescale) can't be subtracted from the audio traf. But the
    // origin offset is the same wall-clock shift for both tracks (one `-ss`, one
    // `-copyts` mux), so A/V stays in sync without any patch — leave it to
    // `-copyts` and just record the (rare) shift for diagnostics.
    if (Mp4Boxes.trafCount(bytes) > 1) {
      stderr.writeln(
        '[vp] $label seg$startSegment tfdt offset '
        '${(offset / timescale).toStringAsFixed(3)}s (muxed — not patching, '
        'A/V sync preserved)',
      );
      return;
    }
    _tfdtCorrection = offset; // subtract per segment → first lands at expected
    stderr.writeln(
      '[vp] $label seg$startSegment tfdt offset '
      '${(offset / timescale).toStringAsFixed(3)}s — normalizing run',
    );
  }

  /// Returns the init segment (`init.mp4`) bytes once ffmpeg has written it,
  /// polling up to [ProducerConfig.segmentTimeout]. The init is position-
  /// independent (identical regardless of the run's `-ss` start), so serving it
  /// from whichever producer instance is alive is always correct. For a muxed
  /// run it contains both the video and audio tracks, guaranteeing the served
  /// init matches the served segments exactly.
  Future<Uint8List?> awaitInit() async {
    final f = File('${_tempDir.path}/init.mp4');
    final deadline = DateTime.now().add(config.segmentTimeout);
    while (DateTime.now().isBefore(deadline)) {
      if (f.existsSync()) {
        // readAsBytesSync already returns a Uint8List; the old
        // Uint8List.fromList() around it just copied the init a second time.
        final b = f.readAsBytesSync();
        if (b.isNotEmpty) return b;
      }
      if (_state == _State.dead) break;
      await Future<void>.delayed(config.pollInterval);
    }
    return f.existsSync() && f.lengthSync() > 0 ? f.readAsBytesSync() : null;
  }

  /// Reads just the leading `moof` of [f], or null if it has none.
  Uint8List? _readHead(File f) {
    RandomAccessFile? raf;
    try {
      raf = f.openSync();
      final len = f.lengthSync();
      final probe = raf.readSync(len < 65536 ? len : 65536);
      final end = Mp4Boxes.moofEnd(probe);
      return end == null ? null : Uint8List.sublistView(probe, 0, end);
    } catch (_) {
      return null;
    } finally {
      try {
        raf?.closeSync();
      } catch (_) {}
    }
  }

  /// Opens segment [i] for streaming, patching its `tfdt` if this run needs a
  /// correction. Only the `moof` header is read into memory — the `mdat` streams
  /// straight off disk (see [SegmentRef]).
  Future<SegmentRef?> _openAndPatch(int i) async {
    final f = _segFile(i);
    if (!f.existsSync()) return null;
    final ref = await SegmentRef.open(f, correction: _tfdtCorrection);
    if (ref == null) return null;
    // Decisive alignment signal: where the playlist says segment i starts vs.
    // where the served bytes actually start (first traf tfdt). The contract is
    // `i.m4s` spans [boundaries[i], boundaries[i+1]); a non-zero/growing drift
    // is the playlist↔producer mismatch that desyncs hls.js and ends in a
    // platform-decoder abort. After the every-keyframe fix this should be ~0.
    if (Log.enabled && i >= 0 && i < boundaries.length) {
      final raw = ref.tfdt;
      if (raw != null && timescale > 0) {
        final actual = raw / timescale;
        final drift = actual - boundaries[i];
        Log.d(
          'vp',
          '$label serve seg$i expected=${boundaries[i].toStringAsFixed(3)} '
              'actual_tfdt=${actual.toStringAsFixed(3)} '
              'drift=${drift >= 0 ? '+' : ''}${drift.toStringAsFixed(3)}s',
        );
      }
    }
    return ref;
  }

  /// Returns segment [i] ready to stream, waiting (polling) until ffmpeg produces
  /// it. Returns null on timeout or producer death (the caller 404s; hls.js
  /// retries). The caller owns the returned ref's file handle.
  Future<SegmentRef?> awaitSegment(int i) async {
    if (i < startSegment || i >= segmentCount) return null;
    if (i <= _highWater) return _openAndPatch(i);
    if (_state == _State.dead) {
      return _segFile(i).existsSync() ? _openAndPatch(i) : null;
    }
    final c = Completer<SegmentRef?>();
    _waiters.putIfAbsent(i, () => []).add(c);
    Timer(config.segmentTimeout, () async {
      if (!c.isCompleted) {
        _waiters[i]?.remove(c);
        c.complete(_segFile(i).existsSync() ? await _openAndPatch(i) : null);
      }
    });
    return c.future;
  }

  void noteRequest(int i) {
    _clientSegment = i;
    _checkThrottle();
  }

  void retain() {
    _refCount++;
    _idleTimer?.cancel();
    _idleTimer = null;
  }

  void release() {
    if (_refCount > 0) _refCount--;
    if (_refCount == 0 && _state != _State.dead) {
      _idleTimer?.cancel();
      _idleTimer = Timer(config.idleKillDelay, () => unawaited(kill()));
    }
  }

  /// Pause ffmpeg (SIGSTOP) when it has raced too far ahead of the client, and
  /// resume (SIGCONT) once the client catches up. Essential for stream-copy
  /// over S3: without it ffmpeg would write the entire film to disk in seconds.
  void _checkThrottle() {
    final proc = _process;
    if (proc == null || _state == _State.dead) return;
    final ahead = _highWater - _clientSegment;
    if (_state == _State.running && ahead >= config.throttleAheadSegments) {
      proc.kill(ProcessSignal.sigstop);
      _state = _State.throttled;
      Log.d(
        'vp',
        '$label SIGSTOP (ahead=$ahead >= ${config.throttleAheadSegments})',
      );
    } else if (_state == _State.throttled &&
        ahead < config.throttleAheadSegments ~/ 2) {
      proc.kill(ProcessSignal.sigcont);
      _state = _State.running;
      Log.d('vp', '$label SIGCONT (ahead=$ahead)');
    }
  }

  void _onExit(int code) {
    if (_state == _State.dead) return;
    Log.d('vp', '$label ffmpeg exited code=$code (highWater=$_highWater)');
    if (code != 0) {
      stderr.writeln(
        '[vp] $label ffmpeg exit=$code: '
        '${_stderr.toString().trim()}',
      );
    }
    // One final scan so segments written just before exit resolve, then fail
    // the rest. (EOF: ffmpeg exits 0 after writing the last segment.)
    _scan();
    _state = _State.dead;
    for (final completers in _waiters.values) {
      for (final c in completers) {
        if (!c.isCompleted) c.complete(null);
      }
    }
    _waiters.clear();
  }

  /// Graceful stop: ask ffmpeg to quit, give it a moment, then SIGKILL the
  /// process group, then delete the temp dir.
  Future<void> kill() async {
    if (_state == _State.dead && _process == null) return;
    final proc = _process;
    final wasThrottled = _state == _State.throttled;
    _state = _State.dead;
    _scanTimer?.cancel();
    _idleTimer?.cancel();
    for (final completers in _waiters.values) {
      for (final c in completers) {
        if (!c.isCompleted) c.complete(null);
      }
    }
    _waiters.clear();

    if (proc != null) {
      try {
        if (wasThrottled) {
          proc.kill(ProcessSignal.sigcont); // unpause to accept 'q'
        }
        proc.stdin.write('q\n');
        await proc.stdin.flush();
      } catch (_) {}
      try {
        await proc.exitCode.timeout(const Duration(seconds: 3));
      } catch (_) {
        // Still alive — hard-kill the whole group so child readers die too.
        if (_useSetsid) {
          Process.killPid(-proc.pid, ProcessSignal.sigkill);
        } else {
          proc.kill(ProcessSignal.sigkill);
        }
      }
    }
    if (config.debug) {
      // Keep segment files for post-mortem inspection; only the ffmpeg process
      // is reaped. (Startup sweep is also skipped in debug — see ProducerManager.)
      Log.d('vp', '$label killed — KEEP segments at ${_tempDir.path}');
    } else {
      try {
        await _tempDir.delete(recursive: true);
      } catch (_) {}
    }
    _process = null;
  }
}
