import 'dart:typed_data';

/// Minimal ISO-BMFF (MP4) box helpers for the HLS pipeline.
///
/// Two jobs, both validated against real ffmpeg output during the gate test:
///  * [patchTfdt] — independently-generated fMP4 segments all start at
///    decode-time 0 (the HLS muxer normalises each window). To make them tile
///    on the MSE timeline we rewrite the `tfdt` baseMediaDecodeTime to the
///    segment's absolute start (boundary × track timescale).
///  * [readTimescale] / [hevcCodecString] — read the track timescale and build
///    the RFC 6381 codec string from the init segment for the master playlist.
class Mp4Boxes {
  /// Rewrites the `moof>traf>tfdt` baseMediaDecodeTime in [seg] (in place).
  /// Keeps the existing version/width (v1=64-bit, v0=32-bit). No-op if absent.
  static void patchTfdt(Uint8List seg, int baseMediaDecodeTime) {
    final loc = _findTfdt(seg);
    if (loc == null) return;
    final (off, version) = loc;
    final bd = ByteData.sublistView(seg);
    if (version == 1) {
      bd.setUint64(off, baseMediaDecodeTime);
    } else {
      bd.setUint32(off, baseMediaDecodeTime);
    }
  }

  /// Reads the `moof>traf>tfdt` baseMediaDecodeTime from a media segment, or
  /// null if absent. Inverse of [patchTfdt]; used to verify a continuously-muxed
  /// segment's absolute decode time and, if a mid-file ffmpeg seek produced an
  /// offset origin, compute a constant per-run correction.
  static int? readTfdt(Uint8List seg) {
    final loc = _findTfdt(seg);
    if (loc == null) return null;
    final (off, version) = loc;
    final bd = ByteData.sublistView(seg);
    return version == 1 ? bd.getUint64(off) : bd.getUint32(off);
  }

  /// Counts the `moof>traf` boxes in a media segment. A single-track segment has
  /// one; a muxed (video+audio) segment has two. Used to tell whether a per-run
  /// tfdt correction (a single constant in one timescale) is safe to apply: it is
  /// only for single-track segments, since a muxed segment carries two tracks on
  /// two timescales and any origin offset is uniform across both (so A/V sync is
  /// preserved without patching).
  static int trafCount(Uint8List seg) {
    final moof = _findIn(seg, 0, seg.length, _moof);
    if (moof == null) return 0;
    var count = 0;
    var i = moof.contentStart;
    while (i + 8 <= moof.end && i + 8 <= seg.length) {
      var size = _u32(seg, i);
      if (size == 1) {
        size = ByteData.sublistView(seg).getUint64(i + 8).toInt();
      } else if (size == 0) {
        size = moof.end - i;
      }
      final t = String.fromCharCodes(seg, i + 4, i + 8);
      if (t == _traf) count++;
      if (size <= 0) break;
      i += size;
    }
    return count;
  }

  /// End offset of the leading `moof` box, or null if it is absent or extends
  /// past [d].
  ///
  /// Lets a caller read just the segment's header — everything [readTfdt],
  /// [patchTfdt] and [trafCount] need lives inside `moof` — and stream the far
  /// larger `mdat` straight from disk instead of buffering the whole segment.
  static int? moofEnd(Uint8List d) {
    final moof = _findIn(d, 0, d.length, _moof);
    if (moof == null || moof.end > d.length) return null;
    return moof.end;
  }

  /// Reads the media timescale from `moov>trak>mdia>mdhd` of an init segment.
  static int? readTimescale(Uint8List init) {
    final mdhd = _find(init, [_moov, _trak, _mdia, _mdhd]);
    if (mdhd == null) return null;
    final o = mdhd.contentStart;
    final version = init[o];
    // v0: [ver+flags=4][create=4][modify=4][timescale=4]
    // v1: [ver+flags=4][create=8][modify=8][timescale=4]
    final tsOff = version == 1 ? o + 4 + 8 + 8 : o + 4 + 4 + 4;
    return ByteData.sublistView(init).getUint32(tsOff);
  }

  /// Builds the RFC 6381 codec string for an HEVC init segment, e.g.
  /// `hvc1.1.6.L120.90`. Returns null if not HEVC.
  static String? hevcCodecString(Uint8List init) {
    final stsd = _find(init, [_moov, _trak, _mdia, _minf, _stbl, _stsd]);
    if (stsd == null) return null;
    // stsd: [ver+flags=4][entry_count=4] then sample entries.
    var p = stsd.contentStart + 8;
    if (p + 8 > init.length) return null;
    final entrySize = _u32(init, p);
    final entryType = String.fromCharCodes(init, p + 4, p + 8);
    final fourcc = (entryType == 'hvc1' || entryType == 'hev1') ? entryType : null;
    if (fourcc == null) return null;
    // VisualSampleEntry: 8 (size+type) + 78 fixed bytes, then child boxes.
    final hvcc = _findIn(init, p + 8 + 78, p + entrySize, _hvcC);
    if (hvcc == null) return null;
    final o = hvcc.contentStart;
    // HEVCDecoderConfigurationRecord
    // [0]=configurationVersion
    // [1]=profile_space(2)|tier(1)|profile_idc(5)
    final b1 = init[o + 1];
    final profileSpace = (b1 >> 6) & 0x3;
    final tier = (b1 >> 5) & 0x1;
    final profileIdc = b1 & 0x1f;
    final compat = _u32(init, o + 2);
    final constraint = init.sublist(o + 6, o + 12);
    final levelIdc = init[o + 12];

    final ps = const {0: '', 1: 'A', 2: 'B', 3: 'C'}[profileSpace] ?? '';
    // Compatibility flags are written bit-reversed in the codec string
    // (0x60000000 → "6").
    final compatRev = _reverse32(compat);
    final sb = StringBuffer()
      ..write(fourcc)
      ..write('.')
      ..write('$ps$profileIdc')
      ..write('.')
      ..write(compatRev.toRadixString(16).toUpperCase())
      ..write('.')
      ..write(tier == 1 ? 'H' : 'L')
      ..write(levelIdc);
    // Constraint bytes, trailing zeros trimmed, each as 2-hex.
    var lastNonZero = constraint.length - 1;
    while (lastNonZero >= 0 && constraint[lastNonZero] == 0) {
      lastNonZero--;
    }
    for (var i = 0; i <= lastNonZero; i++) {
      sb.write('.');
      sb.write(constraint[i].toRadixString(16).toUpperCase().padLeft(2, '0'));
    }
    return sb.toString();
  }

  // --- box walking ---

  static const _moov = 'moov';
  static const _trak = 'trak';
  static const _mdia = 'mdia';
  static const _mdhd = 'mdhd';
  static const _minf = 'minf';
  static const _stbl = 'stbl';
  static const _stsd = 'stsd';
  static const _hvcC = 'hvcC';
  static const _moof = 'moof';
  static const _traf = 'traf';
  static const _tfdt = 'tfdt';

  static (int, int)? _findTfdt(Uint8List d) {
    final moof = _findIn(d, 0, d.length, _moof);
    if (moof == null) return null;
    final traf = _findIn(d, moof.contentStart, moof.end, _traf);
    if (traf == null) return null;
    final tfdt = _findIn(d, traf.contentStart, traf.end, _tfdt);
    if (tfdt == null) return null;
    final version = d[tfdt.contentStart];
    return (tfdt.contentStart + 4, version); // value starts after ver+flags
  }

  /// Finds a nested box by a path of fourcc types from the top level.
  static _Box? _find(Uint8List d, List<String> path) {
    var start = 0, end = d.length;
    _Box? box;
    for (final type in path) {
      box = _findIn(d, start, end, type);
      if (box == null) return null;
      start = box.contentStart;
      end = box.end;
    }
    return box;
  }

  /// Finds the first child box of [type] within [start, end).
  static _Box? _findIn(Uint8List d, int start, int end, String type) {
    var i = start;
    while (i + 8 <= end && i + 8 <= d.length) {
      var size = _u32(d, i);
      var headerLen = 8;
      if (size == 1) {
        // 64-bit largesize
        size = ByteData.sublistView(d).getUint64(i + 8).toInt();
        headerLen = 16;
      } else if (size == 0) {
        size = end - i;
      }
      final t = String.fromCharCodes(d, i + 4, i + 8);
      if (t == type) {
        return _Box(contentStart: i + headerLen, end: i + size);
      }
      if (size <= 0) break;
      i += size;
    }
    return null;
  }

  static int _u32(Uint8List d, int o) =>
      (d[o] << 24) | (d[o + 1] << 16) | (d[o + 2] << 8) | d[o + 3];

  static int _reverse32(int v) {
    var r = 0;
    for (var i = 0; i < 32; i++) {
      r = (r << 1) | ((v >> i) & 1);
    }
    return r & 0xFFFFFFFF;
  }
}

class _Box {
  final int contentStart;
  final int end;
  const _Box({required this.contentStart, required this.end});
}
