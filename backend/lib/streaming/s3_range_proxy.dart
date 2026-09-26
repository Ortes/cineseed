import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';

/// A loopback HTTP proxy that sits between ffmpeg/ffprobe/MkvCues and the
/// presigned S3 URL, turning high-latency remote reads into warm-cache reads.
///
/// Why this exists (measured on Scaleway S3): the provider charges a fixed
/// time-to-first-byte **per range request**, so ffmpeg re-opening the remote
/// MKV and re-reading the same header/index regions (EBML header, Tracks, Cues
/// near EOF) on **every** segment costs ~6 sequential round-trips. A long
/// sequential read fared even worse (a 60 s window took 160 s) because ffmpeg
/// issues dozens of small high-TTFB requests.
///
/// TTFB measured from a same-region server: 0.08–0.20 s per request (an order
/// of magnitude worse off-network). It still dominates: fetching a 32 MiB
/// span took 1.09 s in 4x8 MiB requests versus 3.21 s in 16x2 MiB, so the
/// per-request cost, not throughput, sets [chunkSize]. Keep chunks large.
///
/// The proxy fixes both: it serves ffmpeg's range requests from an aligned,
/// byte-bounded **chunk cache** over a single keep-alive upstream connection,
/// and **reads ahead** so sequential bytes are prefetched before ffmpeg asks.
/// The invariant header/index chunks stay hot (re-touched on every open), so
/// after the first segment only the new cluster bytes hit the network.
///
/// Bytes are immutable, so the cache is keyed by torrent hash and survives a
/// presigned-URL refresh (just call [register] again with the new URL).
class S3RangeProxy {
  final int chunkSize;
  final int readAheadChunks;
  final int maxCacheBytes;

  /// When true, logs each request (range served + duration) to stderr.
  final bool debug;

  /// Maximum bytes served per request. ffmpeg opens open-ended ranges
  /// (`bytes=X-`) but reads only its segment then stops — without a cap the
  /// proxy would try to stream X→EOF and drag the whole file through (measured:
  /// a single far seek took 210 s). Returning a shorter-than-requested 206 is
  /// valid HTTP: the client re-requests the remainder, which is cache-warm.
  final int maxServeBytes;

  final Duration upstreamTimeout;

  /// Maximum responses concurrently inside [_stream]. Excess inbound requests
  /// **queue FIFO** rather than being rejected: ffmpeg is launched without
  /// `-reconnect_on_http_error`, so a 503 at connection-open would kill the
  /// producer instead of triggering a retry, whereas it happily tolerates added
  /// latency up to its `-rw_timeout` (30 s). Bounding this bounds how many
  /// chunks can be referenced by live responses at once.
  final int maxConcurrent;

  /// Abandons a response whose client has stopped reading for this long.
  ///
  /// This is what makes per-chunk flushing (and therefore buffer reuse) safe:
  /// ffmpeg routinely stops reading an open-ended response without closing the
  /// socket, and without a bound such a response would hold both its
  /// [maxConcurrent] slot and a pooled buffer forever.
  ///
  /// The reference point is a **loopback** consumer, not ffmpeg's 30 s
  /// `-rw_timeout`: ffmpeg runs on 127.0.0.1, so a flush that has not drained in
  /// seconds means it has stopped reading, not that it is slow. Sizing this
  /// against `-rw_timeout` (20 s) put it *above* the 18 s segment timeout, so
  /// six abandoned readers — one ordinary seek — starved every real read for
  /// long enough that the producer could not deliver a segment at all
  /// (measured: 19.5 s for a cache-warm 1 KiB read; see the starvation test).
  final Duration writeIdleTimeout;

  final HttpClient _client;
  HttpServer? _server;

  // hash -> per-file state (upstream URL + learned total size).
  final Map<String, _Entry> _entries = {};
  // Global LRU of chunks across all files, keyed "hash:chunkIndex".
  final LinkedHashMap<String, _Chunk> _lru = LinkedHashMap();

  /// Every chunk-sized buffer in the process comes from here, so total chunk
  /// memory is exactly `slots x chunkSize` — bounded by construction rather
  /// than by a GC knob or a kernel limit.
  ///
  /// Reuse (not the cap) is what actually bounds RSS. Measured with an identical
  /// 64 MiB live set and the same pages touched: recycling buffers held 78 MB,
  /// while allocating a fresh buffer per fetch reached 110 MB — Dart retains the
  /// pages of discarded large buffers, so churn, not retention, was this
  /// process's dominant cost (143 MB RSS for a nominal 64 MiB cache).
  late final _BufferPool _pool;

  int _active = 0; // responses inside _stream
  final List<Completer<void>> _slotWaiters = [];

  S3RangeProxy({
    this.chunkSize = 8 << 20, // 8 MiB
    this.readAheadChunks = 3,
    this.maxCacheBytes = 64 << 20, // 64 MiB
    this.maxServeBytes = 16 << 20, // 16 MiB
    this.maxConcurrent = 6,
    this.writeIdleTimeout = const Duration(seconds: 3),
    this.upstreamTimeout = const Duration(seconds: 30),
    this.debug = false,
  }) : _client = (HttpClient()
         ..connectionTimeout = const Duration(seconds: 10)
         // Do NOT tie this to the buffer pool. Memory is already bounded by the
         // pool (a fetch waits for a slot before it reads), so a smaller
         // connection pool buys nothing and starves reads instead: at 4, two
         // concurrent producers plus read-ahead exhausted it, so fetches queued
         // past `connectionTimeout` and surfaced as 10 s stalls and 404s when
         // seeking — the segment could not be produced before hls.js gave up.
         ..maxConnectionsPerHost = 8
         ..idleTimeout = const Duration(seconds: 30)) {
    final slots = maxCacheBytes ~/ chunkSize;
    _pool = _BufferPool(chunkSize, slots < 2 ? 2 : slots);
  }

  int get port => _server!.port;
  bool get running => _server != null;

  /// Bytes of *completed* chunks currently held.
  int get cachedBytes {
    var n = 0;
    for (final c in _lru.values) {
      n += c.bytes ?? 0;
    }
    return n;
  }

  /// Bytes held by buffers handed out to in-flight fetches.
  int get reservedBytes {
    var n = 0;
    for (final c in _lru.values) {
      if (c.bytes == null && c.buf != null) n += chunkSize;
    }
    return n;
  }

  /// Chunk-sized buffers ever allocated x chunkSize — the hard ceiling on this
  /// component's memory, independent of request volume.
  int get pooledBytes => _pool.createdBytes;

  Future<void> start() async {
    if (_server != null) return;
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server!.listen(_handle, onError: (_) {});
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
    _client.close(force: true);
  }

  /// Registers (or refreshes) the upstream URL for [hash] and returns the
  /// loopback URL to hand to ffmpeg/ffprobe/MkvCues. Cached chunks persist.
  String register(String hash, String upstreamUrl) {
    (_entries[hash] ??= _Entry()).upstreamUrl = upstreamUrl;
    return 'http://127.0.0.1:$port/$hash';
  }

  void forget(String hash) {
    // Mark before removing: an in-flight response holds its [_Entry] directly
    // and would otherwise keep re-populating the LRU under a hash nothing will
    // ever forget again, orphaning those chunks.
    _entries.remove(hash)?.forgotten = true;
    _lru.removeWhere((k, v) {
      if (k.startsWith('$hash:')) {
        _drop(v);
        return true;
      }
      return false;
    });
  }

  // --- request handling ---

  Future<void> _handle(HttpRequest req) async {
    final res = req.response;
    try {
      final hash = req.uri.pathSegments.isNotEmpty
          ? req.uri.pathSegments.first
          : '';
      final e = _entries[hash];
      if (e == null) {
        res.statusCode = HttpStatus.notFound;
        await res.close();
        return;
      }
      final total = await _ensureTotal(hash, e);
      if (total == null) {
        res.statusCode = HttpStatus.badGateway;
        await res.close();
        return;
      }

      final rangeHeader = req.headers.value(HttpHeaders.rangeHeader);
      int start;
      int end;
      if (rangeHeader != null) {
        final parsed = parseRange(rangeHeader, total);
        if (parsed == null) {
          res.statusCode = HttpStatus.requestedRangeNotSatisfiable;
          res.headers.set(HttpHeaders.contentRangeHeader, 'bytes */$total');
          await res.close();
          return;
        }
        start = parsed.$1;
        end = parsed.$2;
      } else {
        start = 0;
        end = total - 1;
      }
      // Cap the served window (see [maxServeBytes]). A capped or ranged response
      // is a 206 with Content-Range; only an uncapped full-file GET is 200.
      if (end - start + 1 > maxServeBytes) end = start + maxServeBytes - 1;
      if (rangeHeader != null || start > 0 || end < total - 1) {
        res.statusCode = HttpStatus.partialContent; // 206
        res.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes $start-$end/$total',
        );
      } else {
        res.statusCode = HttpStatus.ok;
      }
      res.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
      res.headers.contentType = ContentType.binary;
      res.headers.contentLength = end - start + 1;

      if (req.method == 'HEAD') {
        await res.close();
        return;
      }
      final sw = debug ? (Stopwatch()..start()) : null;
      // Queue (never reject) past maxConcurrent — see [maxConcurrent].
      await _acquireSlot();
      try {
        await _stream(hash, e, total, start, end, res);
      } finally {
        _releaseSlot();
      }
      if (debug) {
        stderr.writeln(
          '[proxy] ${req.headers.value(HttpHeaders.rangeHeader)} '
          '-> $start-$end (${((end - start + 1) / 1024).round()}KiB) '
          'in ${sw!.elapsedMilliseconds}ms cache=${(cachedBytes / 1048576).round()}MiB '
          'pooled=${(pooledBytes / 1048576).round()}MiB active=$_active',
        );
      }
    } catch (e2) {
      if (debug) stderr.writeln('[proxy] ERR $e2');
      // Client disconnect (ffmpeg seeks → closes the connection) or upstream
      // error. Read-ahead futures keep warming the cache. Best-effort close.
      try {
        await res.close();
      } catch (_) {}
    }
  }

  Future<void> _stream(
    String hash,
    _Entry e,
    int total,
    int start,
    int end,
    HttpResponse res,
  ) async {
    final firstChunk = start ~/ chunkSize;
    final lastChunk = end ~/ chunkSize;
    // Read ahead a little past the (capped) window so the client's next
    // sequential request is cache-warm. Best-effort: `wait: false` means
    // speculative fetches are skipped when the byte budget is tight rather than
    // queueing ahead of the real reads below.
    for (var j = lastChunk + 1; j <= lastChunk + readAheadChunks; j++) {
      if (j * chunkSize < total) {
        final f = _pinChunk(hash, e, j, wait: false);
        if (f != null) {
          unawaited(f.then(_unpin, onError: (_) {}));
        }
      }
    }
    // One chunk in flight at a time, each flushed before the next is requested.
    //
    // Flushing per chunk is what lets buffers be pooled: `sublistView` hands the
    // socket a *view* into a pooled buffer with no copy, and only a completed
    // flush proves those bytes have been handed to the OS, making the buffer
    // safe to recycle. The historical objection to flushing — ffmpeg stops
    // reading an open-ended response without closing, so a flush could block
    // forever — is exactly what [writeIdleTimeout] now bounds.
    //
    // It also means we hold no pin while awaiting the next chunk's buffer, which
    // eliminates hold-and-wait and with it any possibility of pool deadlock.
    for (var idx = firstChunk; idx <= lastChunk; idx++) {
      final c = await _pinChunk(hash, e, idx)!;
      var stalled = false;
      try {
        final bytes = c.view;
        final chunkStart = idx * chunkSize;
        final lo = (idx == firstChunk ? start - chunkStart : 0).clamp(
          0,
          bytes.length,
        );
        final hi = (idx == lastChunk ? end - chunkStart + 1 : bytes.length)
            .clamp(lo, bytes.length);
        if (hi > lo) {
          res.add(Uint8List.sublistView(bytes, lo, hi));
          final flushed = res.flush();
          try {
            await flushed.timeout(writeIdleTimeout);
          } on TimeoutException {
            // The client stopped reading. `timeout` does not cancel the write
            // behind it, so the socket may still ship these bytes: the buffer
            // must leave the pool rather than be recycled (see [_forfeit]).
            stalled = true;
            unawaited(flushed.catchError((_) {}));
            rethrow;
          }
        }
      } finally {
        if (stalled) {
          _forfeit(c);
        } else {
          _unpin(c);
        }
      }
    }
    await res.close().timeout(writeIdleTimeout);
  }

  /// Waits for a free response slot. FIFO, so a queued request cannot be starved
  /// by later arrivals.
  Future<void> _acquireSlot() async {
    while (_active >= maxConcurrent) {
      final w = Completer<void>();
      _slotWaiters.add(w);
      await w.future;
    }
    _active++;
  }

  void _releaseSlot() {
    _active--;
    if (_slotWaiters.isNotEmpty) {
      final w = _slotWaiters.removeAt(0); // FIFO
      if (!w.isCompleted) w.complete();
    }
  }

  Future<int?> _ensureTotal(String hash, _Entry e) async {
    if (e.total != null) return e.total;
    try {
      _unpin(await _pinChunk(hash, e, 0)!);
    } catch (_) {
      return null;
    }
    return e.total;
  }

  /// Bytes chunk [idx] must contain: a full [chunkSize], or the short final
  /// chunk when the total size is known. Computed before the fetch so the
  /// destination buffer is allocated exactly once, at exactly the right size.
  int _expectedLen(_Entry e, int idx) {
    final start = idx * chunkSize;
    final total = e.total;
    if (total == null) return chunkSize;
    final remaining = total - start;
    return remaining < chunkSize ? remaining : chunkSize;
  }

  /// Returns the cache entry for chunk [idx] of [hash] with its buffer **pinned**
  /// (fetching, deduped, if absent). The caller must [_unpin] it.
  ///
  /// A pin only prevents the buffer from being *recycled* while a response is
  /// mid-write; it does not prevent the chunk leaving the cache.
  ///
  /// When [wait] is false the caller gets null rather than queueing for a pool
  /// buffer — used by read-ahead, which is speculative by definition and must
  /// never block a real read.
  Future<_Chunk>? _pinChunk(
    String hash,
    _Entry e,
    int idx, {
    bool wait = true,
  }) {
    if (e.forgotten) {
      return Future.error(StateError('$hash forgotten'));
    }
    final key = '$hash:$idx';
    final existing = _lru.remove(key);
    if (existing != null) {
      _lru[key] = existing; // most-recently-used
      existing.pins++;
      return existing.future.then(
        (_) => existing,
        onError: (Object err) {
          _unpin(existing);
          throw err;
        },
      );
    }
    final c = _Chunk()..pins = 1;
    // Insert *then* evict, before requesting a buffer. The cache legitimately
    // holds every slot, and eviction is the only thing that returns a buffer to
    // the pool — so a fetch that asked for one first would wait on an eviction
    // that only its own completion could trigger.
    _lru[key] = c;
    _evict();
    if (!wait && !_pool.hasFree) {
      _lru.remove(key);
      c.pins = 0;
      return null;
    }
    c.future = _run(c, e, idx).then(
      (_) {
        // forget() or eviction may have dropped this entry mid-flight; only the
        // current occupant of the key belongs in the cache.
        if (_lru[key] != c) {
          _maybeRecycle(c);
        } else {
          _evict();
        }
        return c;
      },
      onError: (Object err) {
        if (_lru[key] == c) _lru.remove(key); // never cache failures
        c.bytes = null;
        // Out of the cache, so it must be marked dropped: _maybeRecycle only ever
        // returns a *dropped* chunk's buffer. Without this every failed fetch lost
        // one pool buffer for good, and a single loss wedged the whole proxy — the
        // LRU still believed it had room, so nothing was evicted and the next new
        // chunk waited in _pool.take() forever.
        _drop(c);
        _unpin(c);
        throw err;
      },
    );
    return c.future;
  }

  /// Acquires a pool buffer (waiting if needed), fills it, and records the valid
  /// length. Deadlock-free: callers hold no other pin while awaiting a buffer
  /// (see [_stream]), so there is no hold-and-wait cycle — the worst case is
  /// serialization, never a wedged state.
  Future<void> _run(_Chunk c, _Entry e, int idx) async {
    final buf = await _pool.take();
    c.buf = buf;
    final len = await _fetchUpstream(e, idx, buf);
    c.bytes = len;
  }

  void _unpin(_Chunk c) {
    if (c.pins > 0) c.pins--;
    _maybeRecycle(c);
  }

  /// Gives up on a chunk whose buffer a stalled response may still be writing
  /// from, releasing that response's [maxConcurrent] slot immediately.
  ///
  /// [writeIdleTimeout] abandons the response but cannot cancel the socket write
  /// under it, so this buffer can never be handed out again. It is written off
  /// with the pool at once — a replacement is created on demand, so both the slot
  /// and the full complement of pool buffers stay available — and dropped for the
  /// GC when the socket finally lets go.
  ///
  /// Without this the only options were to recycle a buffer under a live write
  /// (corruption) or to hold the slot for the whole timeout, which is what let
  /// six abandoned readers starve every real read past the segment timeout.
  /// Forfeits are transient and bounded by [maxConcurrent], since a stalled
  /// response holds exactly one chunk.
  void _forfeit(_Chunk c) {
    if (!c.forfeited) {
      c.forfeited = true;
      if (c.buf != null) _pool.writeOff();
    }
    // Out of the cache too: the next reader must fetch into a pool buffer.
    _lru.removeWhere((_, v) => identical(v, c));
    if (c.pins > 0) c.pins--;
    c.dropped = true;
    _maybeRecycle(c);
  }

  /// Returns a buffer to the pool once the chunk is both out of the cache and no
  /// longer being written by any response. A forfeited buffer is only dropped —
  /// it was already written off, and reusing it would race a pending write.
  void _maybeRecycle(_Chunk c) {
    if (!c.dropped || c.pins > 0) return;
    final buf = c.buf;
    if (buf == null) return;
    c.buf = null;
    if (c.forfeited) return;
    _pool.give(buf);
  }

  /// Marks [c] as no longer cached, recycling its buffer if nothing is using it.
  void _drop(_Chunk c) {
    c.dropped = true;
    _maybeRecycle(c);
  }

  /// Fetches chunk [idx], retrying transient upstream drops (S3 occasionally
  /// closes connections under concurrent load) so a single drop doesn't fail a
  /// whole segment.
  ///
  /// Fills [dest] and returns the number of valid bytes. A retry rewrites [dest]
  /// from offset 0, and nothing observes it as valid until the whole chain
  /// resolves — so a partially-written buffer can never be served. Note this is
  /// why a short read *must* be an error (see [_fillExact]): a reused buffer's
  /// tail still holds a previous chunk's bytes, which would otherwise be served
  /// as if they belonged here.
  Future<int> _fetchUpstream(_Entry e, int idx, Uint8List dest) async {
    for (var attempt = 0; ; attempt++) {
      try {
        return await _fetchOnce(e, idx, dest);
      } catch (err) {
        if (attempt >= 2) rethrow;
        if (debug) stderr.writeln('[fetch] $idx retry ${attempt + 1} ($err)');
        await Future<void>.delayed(Duration(milliseconds: 150 * (attempt + 1)));
      }
    }
  }

  Future<int> _fetchOnce(_Entry e, int idx, Uint8List dest) async {
    final start = idx * chunkSize;
    final reqEnd = start + chunkSize - 1; // S3 clamps to EOF
    final sw = debug ? (Stopwatch()..start()) : null;
    if (debug) stderr.writeln('[fetch] $idx getUrl...');
    final req = await _client.getUrl(Uri.parse(e.upstreamUrl));
    if (debug) {
      stderr.writeln('[fetch] $idx got conn @${sw!.elapsedMilliseconds}ms');
    }
    req.headers.set(HttpHeaders.rangeHeader, 'bytes=$start-$reqEnd');
    final resp = await req.close().timeout(
      upstreamTimeout,
      onTimeout: () {
        req.abort();
        throw TimeoutException('upstream headers', upstreamTimeout);
      },
    );
    if (debug) {
      stderr.writeln('[fetch] $idx headers @${sw!.elapsedMilliseconds}ms');
    }
    if (resp.statusCode != HttpStatus.partialContent &&
        resp.statusCode != HttpStatus.ok) {
      await resp.drain<void>();
      throw HttpException('upstream HTTP ${resp.statusCode}');
    }
    final cr = resp.headers.value(HttpHeaders.contentRangeHeader);
    if (cr != null) {
      final slash = cr.lastIndexOf('/');
      if (slash >= 0) {
        final t = int.tryParse(cr.substring(slash + 1).trim());
        if (t != null) e.total = t;
      }
    }
    // Content-Range may have taught us the true total only now, so the tail
    // chunk's expected length is derived here rather than before the request.
    final want = _expectedLen(e, idx);
    final n = await _fillExact(
      resp.timeout(upstreamTimeout),
      dest,
      want > 0 ? want : chunkSize,
    );
    if (debug) {
      stderr.writeln('[fetch] $idx done ${n}B @${sw!.elapsedMilliseconds}ms');
    }
    // Only meaningful for chunk 0: a 200 means upstream ignored our Range, so
    // these bytes start at file offset 0. Attributing their length to `total`
    // for idx > 0 would record a size for data we did not actually fetch.
    if (e.total == null && resp.statusCode == HttpStatus.ok && idx == 0) {
      e.total = n;
    }
    return n;
  }

  /// Evicts oldest completed chunks until the *total* budget (completed +
  /// in-flight reservations) fits under [maxCacheBytes].
  ///
  /// A chunk still referenced by a live response may be evicted here; that is
  /// safe because chunks are plain GC-managed buffers, not recycled slabs — the
  /// response keeps its own reference alive. It stops being *counted*, which is
  /// the accepted residual: bounded by maxConcurrent x chunks-per-response, and
  /// unlikely in practice since a chunk a live response just touched is MRU.
  /// Trims the cache to the pool's slot count, oldest completed chunk first.
  ///
  /// Chunks currently being written by a response are skipped: dropping one
  /// would recycle its buffer under the socket. They are transient (one per
  /// active response) so this cannot stall eviction indefinitely.
  void _evict() {
    while (_lru.length > _pool.slots) {
      String? victim;
      for (final entry in _lru.entries) {
        if (entry.value.bytes != null && entry.value.pins == 0) {
          victim = entry.key; // oldest completed, unpinned chunk
          break;
        }
      }
      if (victim == null) break; // only in-flight or in-use chunks remain
      _drop(_lru.remove(victim)!);
    }
  }

  /// Reads exactly [expectedLen] bytes of [resp] into [dest], returning the
  /// count. Replaces a `BytesBuilder(copy: false)` + `takeBytes()` pair, which
  /// concatenated the socket's fragments into a *second* full-size buffer.
  ///
  /// A shortfall or overflow throws, so it flows into [_fetchUpstream]'s retry
  /// path and is never cached. This check is load-bearing now that buffers are
  /// reused: a short read left uncaught would expose the tail of whatever chunk
  /// previously occupied [dest]. There is no legitimate short read — the length
  /// is derived from the object's own size.
  static Future<int> _fillExact(
    Stream<List<int>> resp,
    Uint8List dest,
    int expectedLen,
  ) async {
    if (expectedLen > dest.length) {
      throw HttpException('chunk $expectedLen exceeds buffer ${dest.length}');
    }
    var off = 0;
    await for (final d in resp) {
      if (off + d.length > expectedLen) {
        throw HttpException('upstream overflow: got >${expectedLen}B');
      }
      dest.setRange(off, off + d.length, d);
      off += d.length;
    }
    if (off != expectedLen) {
      throw HttpException('upstream short read: ${off}B of ${expectedLen}B');
    }
    return off;
  }

  /// Parses an HTTP `Range` header (first range only) against [total].
  /// Returns inclusive `(start, end)` or null if unsatisfiable/malformed.
  static (int, int)? parseRange(String header, int total) {
    if (total <= 0 || !header.startsWith('bytes=')) return null;
    final spec = header.substring(6).split(',').first.trim();
    final dash = spec.indexOf('-');
    if (dash < 0) return null;
    final startStr = spec.substring(0, dash).trim();
    final endStr = spec.substring(dash + 1).trim();
    int start;
    int end;
    if (startStr.isEmpty) {
      // Suffix range: bytes=-N → last N bytes.
      final n = int.tryParse(endStr);
      if (n == null || n <= 0) return null;
      start = n >= total ? 0 : total - n;
      end = total - 1;
    } else {
      start = int.tryParse(startStr) ?? 0;
      end = endStr.isEmpty ? total - 1 : (int.tryParse(endStr) ?? (total - 1));
    }
    if (start < 0 || start >= total) return null;
    if (end > total - 1) end = total - 1;
    if (end < start) return null;
    return (start, end);
  }
}

class _Entry {
  String upstreamUrl = '';
  int? total;

  /// Set by [S3RangeProxy.forget]; an in-flight response holding this object
  /// must stop repopulating the cache for a file nothing will forget again.
  bool forgotten = false;
}

class _Chunk {
  late Future<_Chunk> future;
  Uint8List? buf; // pooled backing buffer (chunkSize), null once recycled
  int? bytes; // valid length; null while the fetch is in flight
  int pins = 0; // responses currently writing from [buf]
  bool dropped = false; // no longer in the cache; recycle when unpinned
  bool forfeited = false; // a stalled write may still touch [buf]: never reuse

  /// The valid prefix of the pooled buffer. A view, never a copy.
  Uint8List get view => Uint8List.sublistView(buf!, 0, bytes!);
}

/// Fixed set of reusable chunk-sized buffers.
///
/// Buffers are created lazily (an untouched `Uint8List` costs no resident pages,
/// so there is nothing to gain from allocating all slots up front) but never
/// released — reuse is the entire point.
class _BufferPool {
  _BufferPool(this.chunkSize, this.slots);

  final int chunkSize;
  final int slots;

  final List<Uint8List> _free = [];
  final List<Completer<Uint8List>> _waiters = [];
  int _created = 0;

  int get createdBytes => _created * chunkSize;

  /// Whether a buffer can be had without waiting.
  bool get hasFree => _free.isNotEmpty || _created < slots;

  Uint8List? tryTake() {
    if (_free.isNotEmpty) return _free.removeLast();
    if (_created < slots) {
      _created++;
      return Uint8List(chunkSize);
    }
    return null;
  }

  Future<Uint8List> take() {
    final b = tryTake();
    if (b != null) return Future.value(b);
    final w = Completer<Uint8List>();
    _waiters.add(w); // FIFO: a queued fetch cannot be starved by later arrivals
    return w.future;
  }

  void give(Uint8List b) {
    if (_waiters.isNotEmpty) {
      _waiters.removeAt(0).complete(b);
      return;
    }
    _free.add(b);
  }

  /// Writes off one buffer that can never come back (a stalled socket write may
  /// still reference it). A replacement is created immediately if anyone is
  /// waiting, and otherwise on demand, so [slots] usable buffers remain — the
  /// cap stays a cap on *live* buffers, with forfeits as short-lived garbage.
  void writeOff() {
    if (_created > 0) _created--;
    if (_waiters.isNotEmpty && _created < slots) {
      _created++;
      _waiters.removeAt(0).complete(Uint8List(chunkSize));
    }
  }
}
