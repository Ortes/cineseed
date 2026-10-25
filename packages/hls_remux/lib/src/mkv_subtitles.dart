import 'dart:convert';
import 'dart:io' show zlib;
import 'dart:typed_data';

import 'mkv_cues.dart';

/// One subtitle cue on the programme timeline.
typedef SubtitleCue = ({double start, double end, String text});

/// Builds the WebVTT for one window of a Matroska text subtitle track straight
/// from the file's blocks — no ffmpeg.
///
/// mkvmerge indexes every subtitle block in the Cues with its exact position
/// and duration, so a window is a handful of small reads ([indexed]). A track
/// the Cues don't index is read by walking the window's clusters ([scan]),
/// which are the same bytes the video producer reads.
///
/// Either way the answer is exact: it holds every cue shown during the window
/// (cues that started earlier included), and it is empty only when the window
/// truly has none. A failed read throws.
class MkvSubtitles {
  static const _idCluster = 0x1F43B675;
  static const _idTimecode = 0xE7;
  static const _idSimpleBlock = 0xA3;
  static const _idBlockGroup = 0xA0;
  static const _idBlock = 0xA1;
  static const _idBlockDuration = 0x9B;

  /// Cue points without a CueDuration: how far back a cue may start and still
  /// be on screen at the window's start.
  static const _lookback = 10.0;

  /// The WebVTT for `[start, end)` of [track].
  static Future<String> window(
    MkvCues index,
    MkvTrack track,
    double start,
    double end, {
    required ByteRangeReader direct,
    required ByteRangeReader scan,
  }) async {
    if (track.encrypted) return toWebVtt(const []);
    final refs = index.subtitleCues[track.number] ?? const <MkvCueRef>[];
    final indexable =
        refs.isNotEmpty && refs.every((r) => r.relativePos != null);
    final cues = indexable
        ? await indexed(index, track, start, end, direct)
        : await MkvSubtitles.scan(index, track, start, end, scan);
    return toWebVtt(cues);
  }

  /// Reads the window's cues block by block, from the Cues' positions.
  static Future<List<SubtitleCue>> indexed(
    MkvCues index,
    MkvTrack track,
    double start,
    double end,
    ByteRangeReader read,
  ) async {
    final tick = index.tickSeconds;
    final refs = index.subtitleCues[track.number] ?? const <MkvCueRef>[];
    final wanted = [
      for (final r in refs)
        if (r.time * tick < end &&
            (r.duration != null
                ? (r.time + r.duration!) * tick > start
                : r.time * tick >= start - _lookback))
          r,
    ];
    // Each cluster's header, read once: blocks count from its data start.
    final clusterData = <int, Future<int>>{};
    Future<int> dataStart(int clusterPos) async {
      final at = index.segmentStart + clusterPos;
      final h = _header(await read(at, 16), 0);
      if (h == null || h.id != _idCluster) {
        throw FormatException('no Cluster at $at');
      }
      return at + h.headerLen;
    }

    final cues = await Future.wait(
      wanted.map((r) async {
        final at =
            await (clusterData[r.clusterPos] ??= dataStart(r.clusterPos)) +
            r.relativePos!;
        var b = await read(at, 2048);
        final h = _header(b, 0);
        if (h == null || h.size < 0) throw FormatException('no block at $at');
        if (h.headerLen + h.size > b.length) {
          b = await read(at, h.headerLen + h.size);
        }
        final block = _block(b, h);
        if (block == null || block.track != track.number) {
          throw FormatException('block at $at is not track ${track.number}');
        }
        final duration = block.duration ?? r.duration;
        return _cue(track, r.time * tick, duration, tick, block.payload);
      }),
    );
    return [
      for (final c in cues)
        if (c != null && c.start < end && c.end > start) c,
    ];
  }

  /// Reads the window's cues by walking its clusters: from the last cluster
  /// starting at or before `start - lookback` to the first one starting at or
  /// after [end].
  static Future<List<SubtitleCue>> scan(
    MkvCues index,
    MkvTrack track,
    double start,
    double end,
    ByteRangeReader read,
  ) async {
    final tick = index.tickSeconds;
    final clusters = index.clusterCues;
    if (clusters.isEmpty) throw StateError('no cluster positions in the Cues');
    var from = clusters.first.clusterPos;
    int? to;
    for (final c in clusters) {
      final t = c.time * tick;
      if (t <= start - _lookback) from = c.clusterPos;
      if (t >= end) {
        to = c.clusterPos;
        break;
      }
    }
    final cursor = _Cursor(read, index.segmentStart + from);
    final stop = to == null ? null : index.segmentStart + to;
    final cues = <SubtitleCue>[];
    int? clusterTime;
    while (stop == null || cursor.pos < stop) {
      final h = await cursor.header();
      if (h == null) break; // end of file
      switch (h.id) {
        case _idCluster:
          cursor.enter(h); // walk its children (its size may be unknown)
        case _idTimecode:
          clusterTime = _uint(await cursor.take(h), 0, h.size);
        case _idSimpleBlock || _idBlockGroup:
          if (h.size < 0) throw FormatException('unknown-size block');
          // Only subtitle blocks are read whole; others are skipped by their
          // track number, which leads a Block's body.
          final peek = await cursor.peek(h, h.id == _idBlockGroup ? 16 : 8);
          if (!_isTrack(peek, h.id, track.number)) {
            cursor.skip(h);
            break;
          }
          final block = _block(await cursor.takeWhole(h), h);
          if (block == null || clusterTime == null) break;
          final t = (clusterTime + block.timecode) * tick;
          if (t >= end) return cues; // blocks are in time order per track
          final c = _cue(track, t, block.duration, tick, block.payload);
          if (c != null && c.end > start) cues.add(c);
        default:
          // Cues, Tags, Void… between clusters; unknown size: walk into it.
          if (h.size < 0) {
            cursor.enter(h);
          } else {
            cursor.skip(h);
          }
      }
    }
    return cues;
  }

  static SubtitleCue? _cue(
    MkvTrack track,
    double start,
    int? durationTicks,
    double tick,
    Uint8List payload,
  ) {
    if (durationTicks == null) return null; // a text cue always carries one
    final text = cueText(track.codecId, _decode(track, payload));
    if (text.isEmpty) return null;
    return (start: start, end: start + durationTicks * tick, text: text);
  }

  /// Undoes the track's ContentCompression.
  static Uint8List _decode(MkvTrack track, Uint8List payload) =>
      switch (track.compAlgo) {
        null => payload,
        0 => Uint8List.fromList(zlib.decode(payload)),
        3 => Uint8List.fromList([...?track.compSettings, ...payload]),
        final a => throw UnsupportedError('ContentCompAlgo $a'),
      };

  // --- WebVTT ---

  /// A WebVTT document holding [cues].
  static String toWebVtt(List<SubtitleCue> cues) {
    final out = StringBuffer('WEBVTT\n\n');
    for (final c in [...cues]..sort((a, b) => a.start.compareTo(b.start))) {
      out
        ..write('${_ts(c.start)} --> ${_ts(c.end)}\n')
        ..write(c.text)
        ..write('\n\n');
    }
    return out.toString();
  }

  static String _ts(double s) {
    final ms = (s * 1000).round();
    String p(int v, int w) => v.toString().padLeft(w, '0');
    return '${p(ms ~/ 3600000, 2)}:${p(ms ~/ 60000 % 60, 2)}:'
        '${p(ms ~/ 1000 % 60, 2)}.${p(ms % 1000, 3)}';
  }

  /// A block's text as WebVTT cue text: italic, bold and underline survive;
  /// other markup (SRT `<font>`, ASS styling) is dropped.
  static String cueText(String codecId, Uint8List payload) {
    // Some muxers pad the text with NULs.
    final raw = utf8
        .decode(payload, allowMalformed: true)
        .replaceAll('\x00', '');
    final ass = codecId == 'S_TEXT/ASS' || codecId == 'S_TEXT/SSA';
    // Keep <i> <b> <u> (without attributes), drop every other tag and any ASS
    // override block an SRT may carry, and escape what WebVTT reserves.
    final text = (ass ? _assToHtml(_assText(raw)) : raw)
        .replaceAll('\r\n', '\n')
        .replaceAll(RegExp(r'\{\\[^}]*\}'), '')
        .replaceAllMapped(RegExp(r'<(/?)([a-zA-Z]+)[^>]*>|([&<>])'), (m) {
          final ch = m[3];
          if (ch != null) {
            return const {'&': '&amp;', '<': '&lt;', '>': '&gt;'}[ch]!;
          }
          final tag = m[2]!.toLowerCase();
          return const {'i', 'b', 'u'}.contains(tag) ? '<${m[1]}$tag>' : '';
        });
    return text
        .split('\n')
        .map((l) => l.trimRight())
        .where((l) => l.trim().isNotEmpty) // a blank line would end the cue
        .join('\n');
  }

  /// Matroska stores an ASS/SSA event as `ReadOrder,Layer,Style,Name,MarginL,
  /// MarginR,MarginV,Effect,Text`: the text is everything after the 8th comma.
  static String _assText(String event) {
    var i = -1;
    for (var n = 0; n < 8; n++) {
      i = event.indexOf(',', i + 1);
      if (i < 0) return event;
    }
    return event.substring(i + 1);
  }

  /// ASS override tags to HTML-ish tags; drawings (`\p1`…) are dropped.
  static String _assToHtml(String text) {
    final out = StringBuffer();
    final open = <String>{};
    var drawing = false;
    var i = 0;
    while (i < text.length) {
      final ch = text[i];
      if (ch == '{') {
        final close = text.indexOf('}', i);
        if (close < 0) break;
        for (final m in RegExp(
          r'\\([a-z]+)(\d*)',
        ).allMatches(text.substring(i + 1, close))) {
          final tag = m[1]!, arg = m[2]!;
          if (tag == 'p') drawing = arg.isNotEmpty && arg != '0';
          if (tag != 'i' && tag != 'b' && tag != 'u') continue;
          final on = arg.isNotEmpty && arg != '0'; // \b700 is bold too
          if (on && open.add(tag)) out.write('<$tag>');
          if (!on && open.remove(tag)) out.write('</$tag>');
        }
        i = close + 1;
        continue;
      }
      if (ch == r'\' && i + 1 < text.length) {
        final next = text[i + 1];
        if (next == 'N' || next == 'n' || next == 'h') {
          if (!drawing) out.write(next == 'h' ? ' ' : '\n');
          i += 2;
          continue;
        }
      }
      if (!drawing) out.write(ch);
      i++;
    }
    for (final tag in open.toList().reversed) {
      out.write('</$tag>');
    }
    return out.toString();
  }

  // --- Matroska blocks ---

  /// Whether a SimpleBlock/BlockGroup whose body starts with [peek] belongs to
  /// [track].
  static bool _isTrack(Uint8List peek, int id, int track) {
    var o = 0;
    if (id == _idBlockGroup) {
      // The Block is normally the group's first child; if not, read it whole.
      final b = _header(peek, 0);
      if (b == null || b.id != _idBlock) return true;
      o = b.headerLen;
    }
    final n = _vint(peek, o);
    return n == null || n.value == track;
  }

  /// Parses a SimpleBlock or BlockGroup [h] at the start of [b].
  static ({int track, int timecode, int? duration, Uint8List payload})? _block(
    Uint8List b,
    _Header h,
  ) {
    final end = h.headerLen + h.size;
    var body = (start: h.headerLen, end: end);
    int? duration;
    if (h.id == _idBlockGroup) {
      ({int start, int end})? block;
      var o = h.headerLen;
      while (o < end) {
        final c = _header(b, o);
        if (c == null || c.size < 0) return null;
        final cs = o + c.headerLen;
        if (c.id == _idBlock) block = (start: cs, end: cs + c.size);
        if (c.id == _idBlockDuration) duration = _uint(b, cs, c.size);
        o = cs + c.size;
      }
      if (block == null) return null;
      body = block;
    }
    final track = _vint(b, body.start);
    if (track == null) return null;
    final p = body.start + track.len;
    if (p + 3 > body.end) return null;
    final timecode = ByteData.sublistView(b, p, p + 2).getInt16(0);
    final flags = b[p + 2];
    if (flags & 0x06 != 0) return null; // laced: never used for text
    return (
      track: track.value,
      timecode: timecode,
      duration: duration,
      payload: Uint8List.sublistView(b, p + 3, body.end),
    );
  }

  // --- EBML ---

  /// An element header at [o] of [b]; size -1 when unknown. Null if [b] is too
  /// short to hold it.
  static _Header? _header(Uint8List b, int o) {
    if (o >= b.length) return null;
    final idLen = _vintLen(b[o]);
    if (idLen == 0 || o + idLen >= b.length) return null;
    var id = 0;
    for (var i = 0; i < idLen; i++) {
      id = (id << 8) | b[o + i];
    }
    final size = _vint(b, o + idLen);
    if (size == null) return null;
    final unknown = size.value == (1 << (7 * size.len)) - 1;
    return _Header(id, idLen + size.len, unknown ? -1 : size.value);
  }

  static ({int value, int len})? _vint(Uint8List b, int o) {
    if (o >= b.length) return null;
    final len = _vintLen(b[o]);
    if (len == 0 || o + len > b.length) return null;
    var v = b[o] & (0xFF >> len);
    for (var i = 1; i < len; i++) {
      v = (v << 8) | b[o + i];
    }
    return (value: v, len: len);
  }

  static int _vintLen(int first) {
    for (var len = 1; len <= 8; len++) {
      if (first & (0x100 >> len) != 0) return len;
    }
    return 0;
  }

  static int _uint(Uint8List b, int o, int len) {
    var v = 0;
    for (var i = 0; i < len; i++) {
      v = (v << 8) | b[o + i];
    }
    return v;
  }
}

class _Header {
  const _Header(this.id, this.headerLen, this.size);
  final int id;
  final int headerLen;
  final int size; // -1: unknown
}

/// Walks elements forward from an absolute offset, reading 1 MiB slices.
class _Cursor {
  _Cursor(this._read, this.pos);

  static const _slice = 1 << 20;

  final ByteRangeReader _read;
  int pos;
  int _bufStart = 0;
  Uint8List _buf = Uint8List(0);

  Future<Uint8List> _at(int offset, int length) async {
    if (offset < _bufStart || offset + length > _bufStart + _buf.length) {
      _bufStart = offset;
      _buf = await _read(offset, length > _slice ? length : _slice);
    }
    final from = offset - _bufStart;
    final to = (from + length).clamp(from, _buf.length);
    return Uint8List.sublistView(_buf, from, to);
  }

  /// The header at [pos], or null at the end of the file.
  Future<_Header?> header() async =>
      MkvSubtitles._header(await _at(pos, 12), 0);

  /// Steps into [h]'s children.
  void enter(_Header h) => pos += h.headerLen;

  /// Steps over [h].
  void skip(_Header h) => pos += h.headerLen + h.size;

  /// The first [n] bytes of [h]'s body.
  Future<Uint8List> peek(_Header h, int n) => _at(pos + h.headerLen, n);

  /// [h]'s body; steps over it.
  Future<Uint8List> take(_Header h) async {
    final b = await _at(pos + h.headerLen, h.size);
    skip(h);
    return b;
  }

  /// [h] with its header (so it parses at offset 0); steps over it.
  Future<Uint8List> takeWhole(_Header h) async {
    final b = await _at(pos, h.headerLen + h.size);
    skip(h);
    return b;
  }
}
