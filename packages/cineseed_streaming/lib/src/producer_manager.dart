import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'log.dart';
import 'segment_producer.dart';
import 'segment_ref.dart';

/// Owns continuous [SegmentProducer]s keyed by stream — `m:<hash>:<track>` for a
/// muxed (video+audio) Jellyfin-style stream — and decides, per requested
/// segment, whether to serve from the running producer, wait for it, or
/// kill-and-restart at a new position (seek or audio-track switch). Key-agnostic:
/// callers pass the ffmpeg `outputArgs`, boundaries and timescale, so it has no
/// dependency on the Cineseed session model (extraction-ready).
class ProducerManager {
  final ProducerConfig config;
  final int maxSessions; // distinct session hashes kept alive

  final Map<String, SegmentProducer> _active = {}; // key -> producer
  final Map<String, DateTime> _lastUse = {};
  final Map<String, Future<void>> _locks = {}; // per-key start/restart mutex

  ProducerManager({required this.config, this.maxSessions = 3});

  // 'v:<hash>' / 'a:<hash>:<track>' → '<hash>'
  static String _hashOf(String key) {
    final parts = key.split(':');
    return parts.length >= 2 ? parts[1] : key;
  }

  /// Delete leftover per-track temp dirs from a previous (crashed) run. In debug
  /// mode the leftovers are preserved (and logged) so segment evidence survives
  /// a restart.
  Future<void> sweepStaleTempDirs() async {
    final root = Directory(config.tempRoot);
    if (!root.existsSync()) return;
    for (final e in root.listSync()) {
      if (e is Directory &&
          e.uri.pathSegments
              .where((s) => s.isNotEmpty)
              .last
              .startsWith('vp_')) {
        if (config.debug) {
          Log.d('pm', 'KEEP stale temp dir (debug): ${e.path}');
          continue;
        }
        try {
          await e.delete(recursive: true);
        } catch (_) {}
      }
    }
  }

  /// Serve segment [i] of the track identified by [key]. Returns null (→ 404;
  /// hls.js retries) on timeout/producer death/out-of-range.
  Future<SegmentRef?> getSegment({
    required String key,
    required String url,
    required List<double> boundaries,
    required int timescale,
    required List<String> outputArgs,
    required int i,
  }) async {
    if (i < 0 || i >= boundaries.length - 1) return null;
    _lastUse[key] = DateTime.now();

    // Fast path: a live producer that already covers (or is about to cover) i.
    final existing = _active[key];
    if (existing != null && existing.isAlive && existing.canServe(i)) {
      return _serve(existing, i);
    }

    // Slow path: (re)start under a per-key lock (held only across kill+start).
    final producer = await _withLock(key, () async {
      var p = _active[key];
      if (p == null || !p.isAlive || !p.canServe(i)) {
        if (p != null) {
          Log.d(
            'pm',
            '$key restart for seg$i '
                '(was@${p.startSegment}..${p.highWater}, alive=${p.isAlive})',
          );
          await p.kill();
          _active.remove(key);
        } else {
          Log.d('pm', '$key start for seg$i');
        }
        await _enforceCap(_hashOf(key));
        await _killOtherTracks(key);
        p = await SegmentProducer.start(
          label: key,
          url: url,
          boundaries: boundaries,
          timescale: timescale,
          startSegment: i,
          outputArgs: outputArgs,
          config: config,
        );
        _active[key] = p;
      }
      return p;
    });
    return _serve(producer, i);
  }

  /// Returns the init segment for the track identified by [key], starting a
  /// producer at segment 0 if none is alive. The init is position-independent,
  /// so an already-running producer (even one restarted at a seek point) serves
  /// the same bytes. For a muxed track the init carries both tracks.
  Future<Uint8List?> getInit({
    required String key,
    required String url,
    required List<double> boundaries,
    required int timescale,
    required List<String> outputArgs,
  }) async {
    _lastUse[key] = DateTime.now();
    final existing = _active[key];
    if (existing != null && existing.isAlive) {
      final init = await existing.awaitInit();
      if (init != null) return init;
    }
    final producer = await _withLock(key, () async {
      var p = _active[key];
      if (p == null || !p.isAlive) {
        await _enforceCap(_hashOf(key));
        await _killOtherTracks(key);
        p = await SegmentProducer.start(
          label: key,
          url: url,
          boundaries: boundaries,
          timescale: timescale,
          startSegment: 0,
          outputArgs: outputArgs,
          config: config,
        );
        _active[key] = p;
      }
      return p;
    });
    return producer.awaitInit();
  }

  Future<SegmentRef?> _serve(SegmentProducer p, int i) async {
    p.retain();
    p.noteRequest(i);
    try {
      return await p.awaitSegment(i);
    } finally {
      p.release();
    }
  }

  /// Kill every producer (video + audio renditions) for a session.
  Future<void> killSession(String hash) async {
    final keys = _active.keys.where((k) => _hashOf(k) == hash).toList();
    if (keys.isNotEmpty) Log.d('pm', 'killSession $hash → ${keys.join(', ')}');
    final dying = <Future<void>>[];
    for (final k in keys) {
      final p = _active.remove(k);
      _lastUse.remove(k);
      if (p != null) dying.add(p.kill());
    }
    await Future.wait(dying);
  }

  Future<void> killAll() async {
    final producers = _active.values.toList();
    _active.clear();
    _lastUse.clear();
    await Future.wait(producers.map((p) => p.kill()));
  }

  // Evict the least-recently-used OTHER session (all its producers) until the
  // new session fits within maxSessions distinct hashes.
  /// Kills producers for the same hash but a *different* track.
  ///
  /// A muxed producer carries video plus exactly one audio track, so only one
  /// track per session is ever being watched — switching audio track starts a
  /// producer for the new key and orphans the old one. Nothing else reclaims it:
  /// [_enforceCap] groups by hash, and the orphan shares the hash it is told to
  /// keep, so it survives every sweep.
  ///
  /// Left alive it is not merely idle. It keeps racing ahead until it is
  /// [ProducerConfig.throttleAheadSegments] past a client that will never come
  /// back, SIGSTOPs itself, and then stays stopped forever — `_checkThrottle`
  /// only resumes on a request that by definition never arrives. The stopped
  /// ffmpeg holds its proxy connections open, starving the upstream pool: reads
  /// for the *live* track then queue past `connectionTimeout` and seeks 404.
  Future<void> _killOtherTracks(String key) async {
    final hash = _hashOf(key);
    final stale = _active.keys
        .where((k) => k != key && _hashOf(k) == hash)
        .toList();
    for (final k in stale) {
      Log.d('pm', 'kill orphaned track $k (switched to $key)');
      final p = _active.remove(k);
      _lastUse.remove(k);
      if (p != null) await p.kill();
    }
  }

  Future<void> _enforceCap(String keepHash) async {
    while (true) {
      final hashes = _active.keys.map(_hashOf).toSet();
      if (hashes.contains(keepHash) || hashes.length < maxSessions) break;
      String? victim;
      DateTime? oldest;
      for (final h in hashes) {
        var t = DateTime.fromMillisecondsSinceEpoch(0);
        for (final e in _lastUse.entries) {
          if (_hashOf(e.key) == h && e.value.isAfter(t)) t = e.value;
        }
        if (oldest == null || t.isBefore(oldest)) {
          oldest = t;
          victim = h;
        }
      }
      if (victim == null) break;
      Log.d(
        'pm',
        'evict LRU session $victim (cap=$maxSessions, keep=$keepHash)',
      );
      await killSession(victim);
    }
  }

  Future<T> _withLock<T>(String key, Future<T> Function() body) async {
    final prev = _locks[key] ?? Future<void>.value();
    final gate = Completer<void>();
    _locks[key] = gate.future;
    try {
      await prev;
      return await body();
    } finally {
      gate.complete();
      if (identical(_locks[key], gate.future)) _locks.remove(key);
    }
  }
}
