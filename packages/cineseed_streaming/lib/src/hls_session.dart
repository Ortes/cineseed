import 'dart:async';
import 'dart:typed_data';

import 'local_range_server.dart';
import 'log.dart';
import 'media_source.dart';
import 'mkv_cues.dart';
import 'probe.dart';
import 's3_range_proxy.dart';

/// Immutable plan + mutable per-track caches for one playable file's HLS.
class HlsSession {
  /// Stream id of the file this session plays, as understood by the
  /// [MediaSourceResolver]. Every downstream key derives from it: the range
  /// proxy's upstream registration, and the ffmpeg producer keys
  /// `m:<id>:<track>`. It is therefore per FILE: two episodes of the same
  /// season pack are two independent sessions with their own producers and
  /// cached chunks.
  final String id;
  final String url; // loopback URL (range proxy or local file server)
  final MediaProbe probe;

  /// All keyframe timestamps (cue points), ascending.
  final List<double> keyframes;

  /// PLAYLIST segment boundaries: length = segmentCount + 1, last = duration.
  /// Keyframe-aligned, but GROUPED to a minimum duration (see [groupBoundaries])
  /// so no playlist entry is shorter than the muxed audio interleave lag —
  /// sub-lag fragments deadlock hls.js (the buffered end, capped by the audio
  /// track, lands inside the PREVIOUS fragment; hls.js advances one fragment,
  /// finds it already buffered, and never requests the next one).
  final List<double> boundaries;

  /// PRODUCER segment boundaries: every keyframe (the only cut rule ffmpeg
  /// reproduces identically from any `-ss` start). The producer's files are
  /// numbered in this space; playlist entry `i` is served by concatenating
  /// producer files `groupStart[i] .. groupStart[i+1] - 1`.
  final List<double> producerBoundaries;

  /// Maps playlist boundary index -> producer boundary index.
  /// Length = segmentCount + 1; strictly increasing; last points at the last
  /// producer boundary.
  final List<int> groupStart;

  /// When the current upstream URL expires (null: never). The manager
  /// re-resolves the source shortly before; the loopback URL ffmpeg reads stays
  /// constant, only the proxy's upstream is refreshed.
  DateTime? sourceExpiresAt;

  DateTime lastAccess;

  // Lazily-built, cached artifacts.
  Uint8List? videoInit;
  Future<Uint8List>? videoInitFuture; // dedupes concurrent init builds
  int? videoTimescale;
  String? videoCodecString;

  /// `'s:<order>:<i>'` -> WebVTT segment, bounded LRU.
  ///
  /// Kept bounded because a session stays alive as long as it is being watched:
  /// as an unbounded map this grew by one entry per subtitle segment per track
  /// for the whole film and was only ever released when the session itself was
  /// evicted. Cues are cheap to re-extract, so a modest window is enough to
  /// serve hls.js's re-requests.
  final _vtt = <String, String>{};

  static const _maxVttSegments = 64;

  String? vttCached(String key) {
    final v = _vtt.remove(key);
    if (v == null) return null;
    _vtt[key] = v; // most-recently-used
    return v;
  }

  void cacheVtt(String key, String value) {
    _vtt.remove(key);
    _vtt[key] = value;
    while (_vtt.length > _maxVttSegments) {
      _vtt.remove(_vtt.keys.first);
    }
  }

  HlsSession({
    required this.id,
    required this.url,
    required this.probe,
    required this.keyframes,
    required this.boundaries,
    required this.producerBoundaries,
    required this.groupStart,
    this.sourceExpiresAt,
  }) : lastAccess = DateTime.now();

  int get segmentCount => boundaries.length - 1;
  double segStart(int i) => boundaries[i];
  double segEnd(int i) => boundaries[i + 1];
  double segDuration(int i) => boundaries[i + 1] - boundaries[i];
  bool isLastSegment(int i) => i == segmentCount - 1;

  /// Segment boundaries = EVERY keyframe (plus [duration] as the final one).
  /// Interior boundaries are therefore always real keyframes (clean copy cuts).
  ///
  /// Why every keyframe and not a coarser ~[target]-second grouping: the
  /// continuous producer starts ffmpeg with `-ss` at the requested segment, and
  /// ffmpeg's `-hls_time` segmenter anchors its cut grid at *that run's* start
  /// PTS — which, after any seek, is not a multiple of [target]. A grid anchored
  /// at absolute 0 (what this used to compute) and ffmpeg's run-anchored grid
  /// then pick *different* keyframes as cuts, so the file served as `i.m4s` no
  /// longer spans the time range the playlist declares for segment `i`. (Proven:
  /// two runs over the same region, seeded from different `-ss` points, cut at
  /// different keyframes.) The browser places each fMP4 segment by its own tfdt,
  /// so that mismatch accumulates as timeline drift and out-of-order appends,
  /// ending in a decode-order break the platform decoder rejects.
  ///
  /// Cutting at every keyframe is the one rule that is independent of the `-ss`
  /// anchor — every keyframe is always a cut — so the producer (run with a
  /// sub-frame `-hls_time`) reproduces exactly these boundaries from any start,
  /// guaranteeing `i.m4s` == playlist segment `i`. Keyframe spacing already
  /// averages ~[target]s in practice, so the segment count is comparable.
  /// [target] is no longer used (kept for the caller's signature).
  static List<double> computeBoundaries(
    List<double> keyframes,
    double duration,
    double target,
  ) {
    if (keyframes.isEmpty) return [0, duration];
    final b = <double>[keyframes.first < 0.5 ? 0.0 : keyframes.first];
    for (final k in keyframes) {
      if (k <= b.last) continue; // keep strictly increasing; drop first/dupes
      if (k >= duration - 0.05) break; // no micro-segment glued to the end
      b.add(k);
    }
    if (duration > b.last + 0.05) {
      b.add(duration);
    } else if (b.length == 1) {
      b.add(duration);
    }
    return b;
  }

  /// Groups the every-keyframe [fine] boundaries into playlist boundaries of at
  /// least [minDur] seconds, returning (playlistBoundaries, groupStart).
  ///
  /// Rapid-cut scenes put keyframes a few frames apart; a playlist entry per
  /// keyframe then yields 0.08–0.17s segments. Muxed fMP4 fragments carry their
  /// audio ~0.2s behind the video (AAC encoder latency at the cut), and the
  /// MSE buffered range of a muxed SourceBuffer ends at the audio/video
  /// INTERSECTION — so appending a fragment shorter than that lag never moves
  /// the buffered end past the fragment's own start. hls.js then maps the
  /// buffered end to the PREVIOUS fragment, advances exactly one (already
  /// buffered), and stops requesting: playback freezes with no error (proven on
  /// a real film with three 0.125s fragments in a row). Grouping keeps every
  /// playlist entry comfortably above the lag; the producer still cuts at every
  /// keyframe (the only `-ss`-anchor-independent rule), and the server serves a
  /// group by concatenating its producer files (valid CMAF-style multi-moof).
  static (List<double>, List<int>) groupBoundaries(
    List<double> fine,
    double minDur,
  ) {
    if (fine.length <= 2) return (List.of(fine), [0, fine.length - 1]);
    final gs = <int>[0];
    var cur = 0;
    while (cur < fine.length - 1) {
      var j = cur + 1;
      while (j < fine.length - 1 && fine[j] - fine[cur] < minDur) {
        j++;
      }
      gs.add(j);
      cur = j;
    }
    // A short tail group would recreate the micro-segment problem at EOF —
    // merge it into the previous group.
    if (gs.length > 2 && fine[gs.last] - fine[gs[gs.length - 2]] < minDur) {
      gs.removeAt(gs.length - 2);
    }
    return ([for (final i in gs) fine[i]], gs);
  }
}

/// Builds + caches [HlsSession]s. Returns null when an id isn't HLS-eligible
/// (the resolver has no source for it, no cues, probe failed).
class HlsSessionManager {
  final MediaSourceResolver resolver;

  /// Reads [HttpMediaSource]s (caching, read-ahead).
  final S3RangeProxy proxy;

  /// Serves [FileMediaSource]s. Required only if the resolver returns them.
  final LocalRangeServer? localFiles;
  final String ffprobeBin;
  final double targetSegmentSeconds;

  /// How long a session may sit unused before it is evicted (killing its
  /// producer and dropping its cached proxy chunks).
  ///
  /// Deliberately unrelated to the source's own expiry: tying the two held a
  /// finished session's ffmpeg producer and up to the full proxy cache for the
  /// presigned-URL lifetime — 6 h in production — whether or not anyone was
  /// still watching.
  final Duration idleTtl;

  /// Cap on cached sessions. [maxSessions] bounded only [ProducerManager], so
  /// this map could grow one entry per distinct stream id between sweeps.
  final int maxSessions;

  /// Called once a session is built and cached — used to pre-warm the video
  /// init segment (and thus the master playlist's CODECS) while the warm proxy
  /// cache is hot, so the first `master.m3u8` request doesn't pay for it.
  final void Function(HlsSession session)? onReady;

  /// Called when a session is evicted (TTL) — used to kill its live video
  /// producer before the proxy cache is dropped. Receives the stream id.
  final void Function(String id)? onEvict;

  final _cache = <String, HlsSession>{};
  final Map<String, Future<HlsSession?>> _building = {};
  Timer? _sweepTimer;

  HlsSessionManager({
    required this.resolver,
    required this.proxy,
    this.localFiles,
    this.ffprobeBin = 'ffprobe',
    this.targetSegmentSeconds = 6,
    this.idleTtl = const Duration(minutes: 10),
    this.maxSessions = 3,
    this.onReady,
    this.onEvict,
  });

  /// Starts the periodic idle sweep. Without it, eviction only ever ran as a
  /// side effect of an incoming HLS request — so once playback stopped, nothing
  /// released the session's proxy chunks or killed its ffmpeg producer.
  void startSweeping({Duration every = const Duration(minutes: 1)}) {
    _sweepTimer ??= Timer.periodic(every, (_) => _evictExpired());
  }

  void dispose() {
    _sweepTimer?.cancel();
    _sweepTimer = null;
  }

  HlsSession? peek(String id) => _cache[id];

  Future<HlsSession?> get(String id) async {
    _evictExpired();
    final cached = _cache.remove(id);
    if (cached != null) {
      _cache[id] = cached; // re-insert: keeps _cache ordered LRU-first
      cached.lastAccess = DateTime.now();
      await _maybeRefreshUrl(cached);
      return cached;
    }
    return _building.putIfAbsent(id, () => _build(id)).whenComplete(() {
      _building.remove(id);
    });
  }

  /// Re-resolve + re-register the upstream URL shortly before it expires, so a
  /// long-running session's continuous ffmpeg (reading via the stable loopback
  /// URL) keeps getting fresh chunks. Best-effort: a failure leaves the existing
  /// upstream in place. Cached chunks are unaffected.
  Future<void> _maybeRefreshUrl(HlsSession s) async {
    final expiresAt = s.sourceExpiresAt;
    if (expiresAt == null ||
        DateTime.now().isBefore(
          expiresAt.subtract(const Duration(minutes: 5)),
        )) {
      return;
    }
    try {
      final fresh = await resolver.resolve(s.id);
      if (fresh is! HttpMediaSource) {
        Log.d('hls', '${s.id} url refresh FAILED: resolver returned $fresh');
        return;
      }
      proxy.register(s.id, fresh.url);
      s.sourceExpiresAt = fresh.expiresAt;
      Log.d('hls', '${s.id} upstream URL refreshed');
    } catch (e) {
      // Best-effort: leave the existing upstream in place. Surface the cause in
      // debug (observability only — control flow is unchanged).
      Log.d('hls', '${s.id} url refresh FAILED: $e');
    }
  }

  Future<HlsSession?> _build(String id) async {
    final source = await resolver.resolve(id);
    if (source == null) return null;

    // Every read (probe, Cues, and later ffmpeg) goes through a loopback URL:
    // the caching range proxy for remote sources, the file server for local
    // ones.
    final url = switch (source) {
      HttpMediaSource(:final url) => proxy.register(id, url),
      FileMediaSource(:final path) =>
        (localFiles ??
                (throw StateError(
                  'FileMediaSource for $id but no LocalRangeServer given',
                )))
            .register(id, path),
    };

    // probe + Cues are independent reads → run concurrently. Both also warm the
    // proxy's header/index chunks that every segment ffmpeg re-reads.
    final probeF = MediaProbe.run(url, ffprobe: ffprobeBin);
    final cuesF = MkvCues.fetch(url);
    final probe = await probeF;
    if (probe == null || probe.video == null) return null;
    final cues = await cuesF;
    if (cues == null) return null; // no usable index → ineligible

    final duration =
        cues.durationSeconds ?? probe.duration ?? cues.keyframeTimes.last;
    final producerBoundaries = HlsSession.computeBoundaries(
      cues.keyframeTimes,
      duration,
      targetSegmentSeconds,
    );
    final (boundaries, groupStart) = HlsSession.groupBoundaries(
      producerBoundaries,
      targetSegmentSeconds,
    );

    final session = HlsSession(
      id: id,
      url: url,
      probe: probe,
      keyframes: cues.keyframeTimes,
      boundaries: boundaries,
      producerBoundaries: producerBoundaries,
      groupStart: groupStart,
      sourceExpiresAt: switch (source) {
        HttpMediaSource(:final expiresAt) => expiresAt,
        FileMediaSource() => null,
      },
    );
    _cache[id] = session;
    _enforceCap();
    Log.d(
      'hls',
      '$id session built: ${source.label} '
          'dur=${duration.toStringAsFixed(1)}s segs=${session.segmentCount} '
          'video=${probe.video?.codec} audio=${probe.audio.length} '
          'subs=${probe.subtitles.length}',
    );
    onReady?.call(session); // pre-warm video init (fire-and-forget)
    return session;
  }

  void _evictExpired() {
    final now = DateTime.now();
    _cache.removeWhere((id, s) {
      if (now.difference(s.lastAccess) > idleTtl) {
        Log.d('hls', '$id session evicted (idle > $idleTtl)');
        _release(id);
        return true;
      }
      return false;
    });
    _enforceCap();
  }

  /// Drops the least-recently-used sessions past [maxSessions].
  void _enforceCap() {
    while (_cache.length > maxSessions) {
      // _cache is insertion-ordered and re-inserted on access (see get), so the
      // first key is the least recently used.
      final lru = _cache.keys.first;
      Log.d('hls', '$lru session evicted (over cap $maxSessions)');
      _cache.remove(lru);
      _release(lru);
    }
  }

  void _release(String id) {
    onEvict?.call(id); // kill the live video producer first
    proxy.forget(id); // then free the file's cached chunks
    localFiles?.forget(id);
  }
}
