import 'dart:io';
import 'dart:typed_data';

import 'mp4_boxes.dart';

/// A produced fMP4 segment ready to be served, without its `mdat` ever entering
/// the heap.
///
/// Segments are stream-copied video, so on a high-bitrate remux one playlist
/// entry runs to several MB; reading whole segments into `Uint8List` (and, for a
/// grouped entry, concatenating N of them into one more buffer) put a multiple of
/// that on the heap per in-flight request, with no bound. Instead this holds:
///
///  * [head] — the leading `moof` box only, read into memory so its `tfdt` can be
///    patched. Kilobytes.
///  * [file] — an **already-open** handle to the segment, streamed from [head]'s
///    length onward.
///
/// The handle is opened when the ref is created, not when streaming starts. The
/// producer prunes consumed segments off disk on a sliding window, and an open fd
/// keeps reading fine across `unlink` — so this also closes a race where a
/// pruned segment could break a read that was already promised.
///
/// Every ref owns an fd, so exactly one of [stream] (which closes on completion
/// *or* cancellation) or [dispose] must be called. A leaked handle is not
/// harmless here: it keeps the file "in use".
class SegmentRef {
  SegmentRef({required this.file, required this.head, required this.total});

  final RandomAccessFile file;

  /// The patched `moof` box. Emitted before any bytes read from [file].
  final Uint8List head;

  /// Full on-disk segment length, i.e. `head.length + mdat length`.
  final int total;

  bool _taken = false;

  /// Opens [f] and reads just enough of it to expose (and optionally patch) the
  /// `tfdt`. Returns null if the segment is missing, empty, or has no readable
  /// `moof` — the caller 404s and hls.js retries.
  ///
  /// [correction], when non-zero, is subtracted from the `tfdt` to normalise a
  /// mid-file `-ss` run's shifted origin.
  static Future<SegmentRef?> open(File f, {int correction = 0}) async {
    RandomAccessFile? raf;
    try {
      final total = await f.length();
      if (total <= 0) return null;
      raf = await f.open();
      // 64 KiB covers a moof for any realistic segment (its trun sample tables
      // are a few KB per track); re-read only if a segment proves otherwise.
      var probe = await raf.read(total < 65536 ? total : 65536);
      var end = Mp4Boxes.moofEnd(probe);
      if (end == null && probe.length < total) {
        await raf.setPosition(0);
        probe = await raf.read(total);
        end = Mp4Boxes.moofEnd(probe);
      }
      if (end == null) {
        // No parseable moof. Harmless when nothing needs patching — stream the
        // file verbatim, as the previous read-it-all path did. But a run that
        // needs a tfdt correction cannot apply one, and serving an unpatched
        // segment would desync the MSE timeline, so fail and let hls.js retry.
        if (correction != 0) {
          await raf.close();
          return null;
        }
        await raf.setPosition(0);
        return SegmentRef(file: raf, head: Uint8List(0), total: total);
      }
      final head = Uint8List.sublistView(probe, 0, end);
      if (correction != 0) {
        final raw = Mp4Boxes.readTfdt(head);
        if (raw != null) Mp4Boxes.patchTfdt(head, raw - correction);
      }
      await raf.setPosition(end);
      return SegmentRef(file: raf, head: head, total: total);
    } catch (_) {
      try {
        await raf?.close();
      } catch (_) {}
      return null;
    }
  }

  /// The absolute decode time this segment will actually be served with, for the
  /// playlist-vs-producer drift check. Reads the (already patched) head.
  int? get tfdt => Mp4Boxes.readTfdt(head);

  /// Number of `traf` boxes — 1 for a single track, 2 for a muxed segment.
  int get trafCount => Mp4Boxes.trafCount(head);

  /// Emits the whole segment: the patched header, then the rest straight off
  /// disk. Closes the handle on completion, error, or subscription cancellation
  /// (a client disconnecting mid-segment).
  Stream<List<int>> stream() async* {
    _taken = true;
    try {
      yield head;
      var pos = head.length;
      const readSize = 256 * 1024;
      while (pos < total) {
        final want = (total - pos) < readSize ? (total - pos) : readSize;
        final bytes = await file.read(want);
        if (bytes.isEmpty) break;
        yield bytes;
        pos += bytes.length;
      }
    } finally {
      try {
        await file.close();
      } catch (_) {}
    }
  }

  /// Releases the handle for a ref that will never be streamed.
  Future<void> dispose() async {
    if (_taken) return;
    _taken = true;
    try {
      await file.close();
    } catch (_) {}
  }
}

/// One playlist entry's worth of produced segments, streamed back-to-back.
///
/// A grouped entry spans several producer files (see `HlsSession.groupBoundaries`).
/// Each is a self-contained `moof+mdat` with an absolute tfdt, so emitting them in
/// order is a valid multi-fragment (CMAF-chunk-style) segment that hls.js appends
/// as one — no concatenation buffer required.
///
/// Owns its parts' file handles: call [stream] or [dispose], exactly once.
class MuxedSegment {
  MuxedSegment(this.parts);

  final List<SegmentRef> parts;

  /// Total bytes, known up front from the on-disk lengths — so the response can
  /// still carry an exact `Content-Length` without buffering anything.
  int get total => parts.fold<int>(0, (n, p) => n + p.total);

  Stream<List<int>> stream() async* {
    for (final p in parts) {
      yield* p.stream();
    }
  }

  Future<void> dispose() async {
    for (final p in parts) {
      await p.dispose();
    }
  }
}
