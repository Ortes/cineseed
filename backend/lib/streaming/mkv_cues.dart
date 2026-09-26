import 'dart:typed_data';

import 'package:http/http.dart' as http;

/// Reads the Matroska **Cues** index (keyframe seek points) from a remote MKV
/// over HTTP Range — *without ever reading the whole file*.
///
/// Why: our completed files live on S3 (presigned URL). A full keyframe scan
/// would download the entire movie. The Cues element lists seekable keyframe
/// timestamps and is reachable in 2–3 small ranged reads via the SeekHead
/// pointer at the front of the Segment. Each Cue time is a keyframe we can
/// `ffmpeg -ss` to cheaply, and is therefore a valid HLS segment boundary.
///
/// Returns `null` when the file has no usable Cues/SeekHead → the caller marks
/// the file HLS-ineligible.
class MkvCues {
  /// Sorted keyframe timestamps in seconds (ascending, starting at ~0).
  final List<double> keyframeTimes;

  /// Total duration in seconds if found in Info (else null).
  final double? durationSeconds;

  const MkvCues(this.keyframeTimes, this.durationSeconds);

  // --- EBML element IDs (full IDs, length-descriptor bits kept) ---
  static const _idEbmlHeader = 0x1A45DFA3;
  static const _idSegment = 0x18538067;
  static const _idSeekHead = 0x114D9B74;
  static const _idSeek = 0x4DBB;
  static const _idSeekId = 0x53AB;
  static const _idSeekPosition = 0x53AC;
  static const _idInfo = 0x1549A966;
  static const _idTimecodeScale = 0x2AD7B1;
  static const _idDuration = 0x4489;
  static const _idCues = 0x1C53BB6B;
  static const _idCuePoint = 0xBB;
  static const _idCueTime = 0xB3;
  static const _idCueTrackPositions = 0xB7;
  static const _idCueTrack = 0xF7;
  static const _idTracks = 0x1654AE6B;
  static const _idTrackEntry = 0xAE;
  static const _idTrackNumber = 0xD7;
  static const _idTrackType = 0x83;
  static const _trackTypeVideo = 1;

  /// Fetch + parse the Cues. [url] is a presigned S3 GET URL (Range-capable).
  static Future<MkvCues?> fetch(String url, {http.Client? client}) async {
    final c = client ?? http.Client();
    final owns = client == null;
    try {
      final reader = _RangeReader(url, c);

      // 1) EBML header, then Segment header → segment data start offset.
      var head = await reader.read(0, 4096);
      var p = 0;
      final ebml = _readElementHeader(head, p);
      if (ebml == null || ebml.id != _idEbmlHeader) return null;
      p = ebml.contentStart + ebml.size; // skip EBML header content

      // The Segment header may sit past the first 4 KiB if the EBML header is
      // large; re-fetch a window anchored at p when needed.
      if (p + 16 > head.length) {
        head = await reader.read(p, 4096);
        final seg = _readElementHeader(head, 0);
        if (seg == null || seg.id != _idSegment) return null;
        return await _parseSegment(reader, p + seg.headerLen);
      }
      final seg = _readElementHeader(head, p);
      if (seg == null || seg.id != _idSegment) return null;
      return await _parseSegment(reader, seg.contentStart);
    } catch (_) {
      // Any parse/range failure → treat as no usable index (HLS-ineligible).
      return null;
    } finally {
      if (owns) c.close();
    }
  }

  static Future<MkvCues?> _parseSegment(
      _RangeReader reader, int segDataStart) async {
    // Walk the Segment's direct children headers (cheap: only headers are read)
    // to locate SeekHead + Info. Most mkvmerge files put SeekHead first.
    int? cuesPos; // absolute offset of Cues element
    int? infoPos; // absolute offset of Info element
    int? tracksPos; // absolute offset of Tracks element
    int? seekHeadPos2; // secondary SeekHead, followed once

    // Read a generous window covering the front matter (SeekHead/Info/Tracks
    // are small and live before the clusters).
    final front = await reader.read(segDataStart, 256 * 1024);
    var off = 0;
    while (off + 12 < front.length) {
      final el = _readElementHeader(front, off);
      if (el == null) break;
      final absStart = segDataStart + off;
      if (el.id == _idSeekHead) {
        final res = _parseSeekHead(
            front, el.contentStart, el.contentStart + el.size, segDataStart);
        cuesPos ??= res.cuesPos;
        infoPos ??= res.infoPos;
        tracksPos ??= res.tracksPos;
        seekHeadPos2 ??= res.seekHeadPos;
      } else if (el.id == _idInfo) {
        infoPos = absStart;
      } else if (el.id == _idCues) {
        cuesPos = absStart;
      } else if (el.id == _idTracks) {
        tracksPos = absStart;
      }
      // Stop once we've left the front matter (hit a Cluster) and know Cues.
      if (cuesPos != null && infoPos != null && tracksPos != null) break;
      final next = el.contentStart - segDataStart + el.size;
      if (next <= off) break;
      off = next;
    }

    // Follow a secondary SeekHead if the first only pointed at it.
    if (cuesPos == null && seekHeadPos2 != null) {
      final sh = await reader.read(seekHeadPos2, 64 * 1024);
      final el = _readElementHeader(sh, 0);
      if (el != null && el.id == _idSeekHead) {
        final res = _parseSeekHead(
            sh, el.contentStart, el.contentStart + el.size, segDataStart);
        cuesPos ??= res.cuesPos;
        infoPos ??= res.infoPos;
        tracksPos ??= res.tracksPos;
      }
    }

    if (cuesPos == null) return null;

    // The video track number, so we keep ONLY video CuePoints. Matroska Cues
    // index every track (this file: 1 video + several audio + subtitles), and
    // the audio tracks' cue points are dense (~8/s) and are NOT video
    // keyframes. Using them as HLS boundaries makes `ffmpeg -ss <t> -c:v copy`
    // snap back to the real keyframe, so the segment's content/duration no
    // longer match the boundary we assign — tolerated on sequential append but
    // breaks decode on seek. Null → couldn't resolve it; fall back to all cues.
    final videoTrack =
        tracksPos != null ? await _readVideoTrackNumber(reader, tracksPos) : null;

    // TimecodeScale (default 1ms) + optional Duration from Info.
    var timecodeScale = 1000000; // ns per tick
    double? durationTicks;
    if (infoPos != null) {
      final infoBuf = await reader.read(infoPos, 64 * 1024);
      final info = _readElementHeader(infoBuf, 0);
      if (info != null && info.id == _idInfo) {
        var io = info.contentStart;
        final end = info.contentStart + info.size;
        while (io + 3 < end && io + 3 < infoBuf.length) {
          final e = _readElementHeader(infoBuf, io);
          if (e == null) break;
          if (e.id == _idTimecodeScale) {
            timecodeScale = _readUint(infoBuf, e.contentStart, e.size);
          } else if (e.id == _idDuration) {
            durationTicks = _readFloat(infoBuf, e.contentStart, e.size);
          }
          final next = e.contentStart + e.size;
          if (next <= io) break;
          io = next;
        }
      }
    }

    // Read the Cues element (header first for its size, then the whole thing).
    final cuesHdrBuf = await reader.read(cuesPos, 16);
    final cuesEl = _readElementHeader(cuesHdrBuf, 0);
    if (cuesEl == null || cuesEl.id != _idCues) return null;
    final cuesBuf = await reader.read(cuesPos, cuesEl.headerLen + cuesEl.size);

    final times = <double>[];
    var co = cuesEl.headerLen; // content start within cuesBuf
    final cend = cuesEl.headerLen + cuesEl.size;
    final scaleSecs = timecodeScale / 1e9;
    while (co + 2 < cend && co + 2 < cuesBuf.length) {
      final cp = _readElementHeader(cuesBuf, co);
      if (cp == null) break;
      if (cp.id == _idCuePoint) {
        // A CuePoint has one CueTime and a CueTrackPositions (with CueTrack).
        // Keep it only if it indexes the video track.
        int? cueTimeRaw;
        int? cueTrack;
        var pco = cp.contentStart;
        final pend = cp.contentStart + cp.size;
        while (pco + 1 < pend && pco + 1 < cuesBuf.length) {
          final e = _readElementHeader(cuesBuf, pco);
          if (e == null) break;
          if (e.id == _idCueTime) {
            cueTimeRaw = _readUint(cuesBuf, e.contentStart, e.size);
          } else if (e.id == _idCueTrackPositions) {
            var to = e.contentStart;
            final tend = e.contentStart + e.size;
            while (to + 1 < tend && to + 1 < cuesBuf.length) {
              final f = _readElementHeader(cuesBuf, to);
              if (f == null) break;
              if (f.id == _idCueTrack) {
                cueTrack = _readUint(cuesBuf, f.contentStart, f.size);
                break;
              }
              final next = f.contentStart + f.size;
              if (next <= to) break;
              to = next;
            }
          }
          final next = e.contentStart + e.size;
          if (next <= pco) break;
          pco = next;
        }
        // videoTrack == null → couldn't resolve the track list, keep all
        // (legacy behaviour). Otherwise keep video-track cues only.
        if (cueTimeRaw != null &&
            (videoTrack == null || cueTrack == videoTrack)) {
          times.add(cueTimeRaw * scaleSecs);
        }
      }
      final next = cp.contentStart + cp.size;
      if (next <= co) break;
      co = next;
    }

    if (times.isEmpty) return null;
    times.sort();
    final dur = durationTicks != null ? durationTicks * scaleSecs : null;
    return MkvCues(times, dur);
  }

  static _SeekHeadResult _parseSeekHead(
      Uint8List b, int start, int end, int segDataStart) {
    int? cuesPos, infoPos, seekHeadPos, tracksPos;
    var off = start;
    while (off + 2 < end && off + 2 < b.length) {
      final seek = _readElementHeader(b, off);
      if (seek == null) break;
      if (seek.id == _idSeek) {
        int? sid;
        int? spos;
        var so = seek.contentStart;
        final send = seek.contentStart + seek.size;
        while (so + 2 < send && so + 2 < b.length) {
          final e = _readElementHeader(b, so);
          if (e == null) break;
          if (e.id == _idSeekId) {
            sid = _readUint(b, e.contentStart, e.size);
          } else if (e.id == _idSeekPosition) {
            spos = _readUint(b, e.contentStart, e.size);
          }
          final next = e.contentStart + e.size;
          if (next <= so) break;
          so = next;
        }
        if (sid != null && spos != null) {
          final abs = segDataStart + spos;
          if (sid == _idCues) cuesPos = abs;
          if (sid == _idInfo) infoPos = abs;
          if (sid == _idSeekHead) seekHeadPos = abs;
          if (sid == _idTracks) tracksPos = abs;
        }
      }
      final next = seek.contentStart + seek.size;
      if (next <= off) break;
      off = next;
    }
    return _SeekHeadResult(cuesPos, infoPos, seekHeadPos, tracksPos);
  }

  /// Reads the Tracks element at [tracksPos] and returns the TrackNumber of the
  /// first video track (TrackType == 1), or null if none/unparseable. The
  /// number is what CuePoints reference via CueTrack.
  static Future<int?> _readVideoTrackNumber(
      _RangeReader reader, int tracksPos) async {
    try {
      final buf = await reader.read(tracksPos, 256 * 1024);
      final tracks = _readElementHeader(buf, 0);
      if (tracks == null || tracks.id != _idTracks) return null;
      var o = tracks.contentStart;
      final end = tracks.contentStart + tracks.size;
      while (o + 2 < end && o + 2 < buf.length) {
        final te = _readElementHeader(buf, o);
        if (te == null) break;
        if (te.id == _idTrackEntry) {
          int? number;
          int? type;
          var to = te.contentStart;
          final tend = te.contentStart + te.size;
          while (to + 1 < tend && to + 1 < buf.length) {
            final e = _readElementHeader(buf, to);
            if (e == null) break;
            if (e.id == _idTrackNumber) {
              number = _readUint(buf, e.contentStart, e.size);
            } else if (e.id == _idTrackType) {
              type = _readUint(buf, e.contentStart, e.size);
            }
            final next = e.contentStart + e.size;
            if (next <= to) break;
            to = next;
          }
          if (type == _trackTypeVideo && number != null) return number;
        }
        final next = te.contentStart + te.size;
        if (next <= o) break;
        o = next;
      }
    } catch (_) {
      // Treat any parse failure as "unknown" → caller keeps all cues.
    }
    return null;
  }

  // --- EBML primitives ---

  /// Reads an element header (ID + size) at [o]. Returns null if out of bounds.
  static _Element? _readElementHeader(Uint8List b, int o) {
    if (o < 0 || o + 1 > b.length) return null;
    final idLen = _vintLen(b[o]);
    if (idLen == 0 || o + idLen > b.length) return null;
    var id = 0;
    for (var i = 0; i < idLen; i++) {
      id = (id << 8) | b[o + i];
    }
    final sizeOff = o + idLen;
    if (sizeOff + 1 > b.length) return null;
    final sizeLen = _vintLen(b[sizeOff]);
    if (sizeLen == 0 || sizeOff + sizeLen > b.length) return null;
    var size = b[sizeOff] & (0xFF >> sizeLen);
    var allOnes = size == (0xFF >> sizeLen);
    for (var i = 1; i < sizeLen; i++) {
      final byte = b[sizeOff + i];
      if (byte != 0xFF) allOnes = false;
      size = (size << 8) | byte;
    }
    final headerLen = idLen + sizeLen;
    return _Element(
      id: id,
      headerLen: headerLen,
      contentStart: o + headerLen,
      size: allOnes ? 0 : size, // unknown size → treat as 0 (front matter only)
    );
  }

  /// Length in bytes of a VINT given its first byte (position of the high bit).
  static int _vintLen(int first) {
    for (var len = 1; len <= 8; len++) {
      if (first & (0x100 >> len) != 0) return len;
    }
    return 0;
  }

  static int _readUint(Uint8List b, int off, int len) {
    var v = 0;
    for (var i = 0; i < len && off + i < b.length; i++) {
      v = (v << 8) | b[off + i];
    }
    return v;
  }

  static double _readFloat(Uint8List b, int off, int len) {
    final bd = ByteData.sublistView(b, off, off + len);
    if (len == 4) return bd.getFloat32(0);
    if (len == 8) return bd.getFloat64(0);
    return _readUint(b, off, len).toDouble();
  }
}

class _Element {
  final int id;
  final int headerLen;
  final int contentStart;
  final int size;
  const _Element({
    required this.id,
    required this.headerLen,
    required this.contentStart,
    required this.size,
  });
}

class _SeekHeadResult {
  final int? cuesPos;
  final int? infoPos;
  final int? seekHeadPos;
  final int? tracksPos;
  const _SeekHeadResult(
      this.cuesPos, this.infoPos, this.seekHeadPos, this.tracksPos);
}

/// Fetches byte ranges from a URL via HTTP `Range` requests.
class _RangeReader {
  final String url;
  final http.Client client;
  _RangeReader(this.url, this.client);

  Future<Uint8List> read(int offset, int length) async {
    final res = await client.get(
      Uri.parse(url),
      headers: {'Range': 'bytes=$offset-${offset + length - 1}'},
    );
    if (res.statusCode != 206 && res.statusCode != 200) {
      throw http.ClientException('Range read failed: HTTP ${res.statusCode}');
    }
    return res.bodyBytes;
  }
}
