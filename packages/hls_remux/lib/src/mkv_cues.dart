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

  /// Absolute offset of the Segment's data: Cues positions count from here.
  final int segmentStart;

  /// Seconds per timestamp tick (Info's TimecodeScale).
  final double tickSeconds;

  /// The subtitle tracks, in file order: entry `N` is ffmpeg's `0:s:N`.
  final List<MkvTrack> subtitleTracks;

  /// Each subtitle track's cue points (by track number), ascending. mkvmerge
  /// indexes every subtitle block, with its position and duration; a track
  /// missing here has no index.
  final Map<int, List<MkvCueRef>> subtitleCues;

  /// The video track's cue points: where the clusters start, ascending.
  final List<MkvCueRef> clusterCues;

  const MkvCues(
    this.keyframeTimes,
    this.durationSeconds, {
    this.segmentStart = 0,
    this.tickSeconds = 0.001,
    this.subtitleTracks = const [],
    this.subtitleCues = const {},
    this.clusterCues = const [],
  });

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
  static const _idCueClusterPosition = 0xF1;
  static const _idCueRelativePosition = 0xF0;
  static const _idCueDuration = 0xB2;
  static const _idTracks = 0x1654AE6B;
  static const _idTrackEntry = 0xAE;
  static const _idTrackNumber = 0xD7;
  static const _idTrackType = 0x83;
  static const _idCodecId = 0x86;
  static const _idContentEncodings = 0x6D80;
  static const _idContentEncoding = 0x6240;
  static const _idContentCompression = 0x5034;
  static const _idContentCompAlgo = 0x4254;
  static const _idContentCompSettings = 0x4255;
  static const _idContentEncryption = 0x5035;
  static const _trackTypeVideo = 1;
  static const _trackTypeSubtitle = 0x11;

  /// Fetch + parse the Cues. [url] is a presigned S3 GET URL (Range-capable).
  static Future<MkvCues?> fetch(String url, {http.Client? client}) async {
    final c = client ?? http.Client();
    final owns = client == null;
    try {
      final read = httpRangeReader(url, c);
      final segDataStart = await _segmentDataStart(read);
      if (segDataStart == null) return null;
      return await _parseSegment(read, segDataStart);
    } catch (_) {
      // Any parse/range failure → treat as no usable index (HLS-ineligible).
      return null;
    } finally {
      if (owns) c.close();
    }
  }

  /// The Cues element's byte range `[start, end)`, found the way [fetch] finds
  /// it (SeekHead pointers). [read] may return fewer bytes than asked — only
  /// what is downloaded so far; null when that isn't enough to locate the Cues,
  /// and `end` null while the Cues' own header isn't downloaded yet.
  static Future<({int start, int? end})?> locate(ByteRangeReader read) async {
    try {
      final segDataStart = await _segmentDataStart(read);
      if (segDataStart == null) return null;
      final cuesPos = (await _locate(read, segDataStart)).cuesPos;
      if (cuesPos == null) return null;
      final head = await read(cuesPos, 16);
      final el = _readElementHeader(head, 0);
      if (el == null && head.length < 16) return (start: cuesPos, end: null);
      if (el == null || el.id != _idCues) return null;
      return (start: cuesPos, end: cuesPos + el.headerLen + el.size);
    } catch (_) {
      return null;
    }
  }

  /// EBML header, then Segment header → segment data start offset.
  static Future<int?> _segmentDataStart(ByteRangeReader read) async {
    final head = await read(0, 4096);
    final ebml = _readElementHeader(head, 0);
    if (ebml == null || ebml.id != _idEbmlHeader) return null;
    final p = ebml.contentStart + ebml.size; // skip EBML header content

    // The Segment header may sit past the first 4 KiB if the EBML header is
    // large; re-fetch a window anchored at p when needed.
    if (p + 16 > head.length) {
      final seg = _readElementHeader(await read(p, 4096), 0);
      if (seg == null || seg.id != _idSegment) return null;
      return p + seg.headerLen;
    }
    final seg = _readElementHeader(head, p);
    if (seg == null || seg.id != _idSegment) return null;
    return seg.contentStart;
  }

  static Future<MkvCues?> _parseSegment(
    ByteRangeReader read,
    int segDataStart,
  ) async {
    final (:cuesPos, :infoPos, :tracksPos, seekHeadPos: _) = await _locate(
      read,
      segDataStart,
    );
    if (cuesPos == null) return null;

    // The video track number, so we keep ONLY video CuePoints. Matroska Cues
    // index every track (this file: 1 video + several audio + subtitles), and
    // the audio tracks' cue points are dense (~8/s) and are NOT video
    // keyframes. Using them as HLS boundaries makes `ffmpeg -ss <t> -c:v copy`
    // snap back to the real keyframe, so the segment's content/duration no
    // longer match the boundary we assign — tolerated on sequential append but
    // breaks decode on seek. Null → couldn't resolve it; fall back to all cues.
    final tracks = tracksPos != null
        ? await _readTracks(read, tracksPos)
        : const <MkvTrack>[];
    final videoTrack = tracks
        .where((t) => t.type == _trackTypeVideo)
        .firstOrNull
        ?.number;
    final subtitleTracks = [
      for (final t in tracks)
        if (t.type == _trackTypeSubtitle) t,
    ];
    final subtitleCues = <int, List<MkvCueRef>>{};
    final clusterCues = <MkvCueRef>[];

    // TimecodeScale (default 1ms) + optional Duration from Info.
    var timecodeScale = 1000000; // ns per tick
    double? durationTicks;
    if (infoPos != null) {
      final infoBuf = await read(infoPos, 64 * 1024);
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
    final cuesHdrBuf = await read(cuesPos, 16);
    final cuesEl = _readElementHeader(cuesHdrBuf, 0);
    if (cuesEl == null || cuesEl.id != _idCues) return null;
    final cuesBuf = await read(cuesPos, cuesEl.headerLen + cuesEl.size);

    final times = <double>[];
    var co = cuesEl.headerLen; // content start within cuesBuf
    final cend = cuesEl.headerLen + cuesEl.size;
    final scaleSecs = timecodeScale / 1e9;
    while (co + 2 < cend && co + 2 < cuesBuf.length) {
      final cp = _readElementHeader(cuesBuf, co);
      if (cp == null) break;
      if (cp.id == _idCuePoint) {
        // A CuePoint has one CueTime and one CueTrackPositions per track it
        // indexes. Keyframe times come from the video track's only.
        int? cueTimeRaw;
        final positions = <({int track, int? cluster, int? rel, int? dur})>[];
        var pco = cp.contentStart;
        final pend = cp.contentStart + cp.size;
        while (pco + 1 < pend && pco + 1 < cuesBuf.length) {
          final e = _readElementHeader(cuesBuf, pco);
          if (e == null) break;
          if (e.id == _idCueTime) {
            cueTimeRaw = _readUint(cuesBuf, e.contentStart, e.size);
          } else if (e.id == _idCueTrackPositions) {
            int? track, cluster, rel, dur;
            var to = e.contentStart;
            final tend = e.contentStart + e.size;
            while (to + 1 < tend && to + 1 < cuesBuf.length) {
              final f = _readElementHeader(cuesBuf, to);
              if (f == null) break;
              final v = _readUint(cuesBuf, f.contentStart, f.size);
              switch (f.id) {
                case _idCueTrack:
                  track = v;
                case _idCueClusterPosition:
                  cluster = v;
                case _idCueRelativePosition:
                  rel = v;
                case _idCueDuration:
                  dur = v;
              }
              final next = f.contentStart + f.size;
              if (next <= to) break;
              to = next;
            }
            if (track != null) {
              positions.add((
                track: track,
                cluster: cluster,
                rel: rel,
                dur: dur,
              ));
            }
          }
          final next = e.contentStart + e.size;
          if (next <= pco) break;
          pco = next;
        }
        if (cueTimeRaw != null) {
          // videoTrack == null → couldn't resolve the track list, keep all
          // (legacy behaviour). Otherwise keep video-track cues only.
          if (videoTrack == null ||
              positions.any((p) => p.track == videoTrack)) {
            times.add(cueTimeRaw * scaleSecs);
          }
          for (final p in positions) {
            final cluster = p.cluster;
            if (cluster == null) continue;
            final ref = MkvCueRef(cueTimeRaw, cluster, p.rel, p.dur);
            if (p.track == videoTrack) {
              clusterCues.add(ref);
            } else if (subtitleTracks.any((t) => t.number == p.track)) {
              (subtitleCues[p.track] ??= []).add(ref);
            }
          }
        }
      }
      final next = cp.contentStart + cp.size;
      if (next <= co) break;
      co = next;
    }

    if (times.isEmpty) return null;
    times.sort();
    final dur = durationTicks != null ? durationTicks * scaleSecs : null;
    int byTime(MkvCueRef a, MkvCueRef b) => a.time.compareTo(b.time);
    clusterCues.sort(byTime);
    for (final refs in subtitleCues.values) {
      refs.sort(byTime);
    }
    return MkvCues(
      times,
      dur,
      segmentStart: segDataStart,
      tickSeconds: scaleSecs,
      subtitleTracks: subtitleTracks,
      subtitleCues: subtitleCues,
      clusterCues: clusterCues,
    );
  }

  /// Where the Cues, Info and Tracks elements start (absolute offsets).
  static Future<_SeekHeadResult> _locate(
    ByteRangeReader read,
    int segDataStart,
  ) async {
    // Walk the Segment's direct children headers (cheap: only headers are read)
    // to locate SeekHead + Info. Most mkvmerge files put SeekHead first.
    int? cuesPos; // absolute offset of Cues element
    int? infoPos; // absolute offset of Info element
    int? tracksPos; // absolute offset of Tracks element
    int? seekHeadPos2; // secondary SeekHead, followed once

    // Read a generous window covering the front matter (SeekHead/Info/Tracks
    // are small and live before the clusters).
    final front = await read(segDataStart, 256 * 1024);
    var off = 0;
    while (off + 12 < front.length) {
      final el = _readElementHeader(front, off);
      if (el == null) break;
      final absStart = segDataStart + off;
      if (el.id == _idSeekHead) {
        final res = _parseSeekHead(
          front,
          el.contentStart,
          el.contentStart + el.size,
          segDataStart,
        );
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
      final sh = await read(seekHeadPos2, 64 * 1024);
      final el = _readElementHeader(sh, 0);
      if (el != null && el.id == _idSeekHead) {
        final res = _parseSeekHead(
          sh,
          el.contentStart,
          el.contentStart + el.size,
          segDataStart,
        );
        cuesPos ??= res.cuesPos;
        infoPos ??= res.infoPos;
        tracksPos ??= res.tracksPos;
      }
    }

    return (
      cuesPos: cuesPos,
      infoPos: infoPos,
      seekHeadPos: seekHeadPos2,
      tracksPos: tracksPos,
    );
  }

  static _SeekHeadResult _parseSeekHead(
    Uint8List b,
    int start,
    int end,
    int segDataStart,
  ) {
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
    return (
      cuesPos: cuesPos,
      infoPos: infoPos,
      seekHeadPos: seekHeadPos,
      tracksPos: tracksPos,
    );
  }

  /// Reads the Tracks element at [tracksPos]: every track's number (what
  /// CuePoints reference via CueTrack), type, codec and content encoding.
  /// Empty if unparseable.
  static Future<List<MkvTrack>> _readTracks(
    ByteRangeReader read,
    int tracksPos,
  ) async {
    final out = <MkvTrack>[];
    try {
      final buf = await read(tracksPos, 256 * 1024);
      final tracks = _readElementHeader(buf, 0);
      if (tracks == null || tracks.id != _idTracks) return out;
      for (final te in _children(buf, tracks)) {
        if (te.id != _idTrackEntry) continue;
        int? number;
        int? type;
        var codec = '';
        int? compAlgo;
        Uint8List? compSettings;
        var encrypted = false;
        for (final e in _children(buf, te)) {
          switch (e.id) {
            case _idTrackNumber:
              number = _readUint(buf, e.contentStart, e.size);
            case _idTrackType:
              type = _readUint(buf, e.contentStart, e.size);
            case _idCodecId:
              codec = String.fromCharCodes(
                buf,
                e.contentStart,
                e.contentStart + e.size,
              ).replaceAll('\x00', '');
            case _idContentEncodings:
              for (final enc in _children(buf, e)) {
                if (enc.id != _idContentEncoding) continue;
                for (final c in _children(buf, enc)) {
                  if (c.id == _idContentEncryption) encrypted = true;
                  if (c.id != _idContentCompression) continue;
                  compAlgo = 0; // ContentCompAlgo's default: zlib
                  for (final f in _children(buf, c)) {
                    if (f.id == _idContentCompAlgo) {
                      compAlgo = _readUint(buf, f.contentStart, f.size);
                    } else if (f.id == _idContentCompSettings) {
                      compSettings = Uint8List.sublistView(
                        buf,
                        f.contentStart,
                        f.contentStart + f.size,
                      );
                    }
                  }
                }
              }
          }
        }
        if (number != null && type != null) {
          out.add(
            MkvTrack(
              number: number,
              type: type,
              codecId: codec,
              compAlgo: compAlgo,
              compSettings: compSettings,
              encrypted: encrypted,
            ),
          );
        }
      }
    } catch (_) {
      // Treat any parse failure as "unknown" → caller keeps all cues.
    }
    return out;
  }

  /// The child elements of [parent], within what [b] holds.
  static Iterable<_Element> _children(Uint8List b, _Element parent) sync* {
    var o = parent.contentStart;
    final end = parent.contentStart + parent.size;
    while (o + 1 < end && o + 1 < b.length) {
      final e = _readElementHeader(b, o);
      if (e == null) return;
      yield e;
      final next = e.contentStart + e.size;
      if (next <= o) return;
      o = next;
    }
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

typedef _SeekHeadResult = ({
  int? cuesPos,
  int? infoPos,
  int? seekHeadPos,
  int? tracksPos,
});

/// One Matroska track, as the Tracks element describes it.
class MkvTrack {
  const MkvTrack({
    required this.number,
    required this.type,
    required this.codecId,
    this.compAlgo,
    this.compSettings,
    this.encrypted = false,
  });

  /// TrackNumber: what blocks and CuePoints reference.
  final int number;

  /// TrackType: 1 video, 2 audio, 0x11 subtitle.
  final int type;

  /// CodecID, e.g. `S_TEXT/UTF8`.
  final String codecId;

  /// ContentCompAlgo when the blocks are compressed: 0 zlib, 3 header
  /// stripping ([compSettings] is the stripped prefix). Null: not compressed.
  final int? compAlgo;
  final Uint8List? compSettings;

  /// The blocks are encrypted (ContentEncryption): unreadable here.
  final bool encrypted;
}

/// One CueTrackPositions: where a track's block at [time] lives.
class MkvCueRef {
  const MkvCueRef(this.time, this.clusterPos, this.relativePos, this.duration);

  /// CueTime, in ticks.
  final int time;

  /// CueClusterPosition: the Cluster's offset from the Segment's data start.
  final int clusterPos;

  /// CueRelativePosition: the block's offset from the Cluster's data start.
  final int? relativePos;

  /// CueDuration, in ticks.
  final int? duration;
}

/// Reads [length] bytes at [offset] — or fewer, at the end of what is there.
typedef ByteRangeReader = Future<Uint8List> Function(int offset, int length);

/// Reads byte ranges of [url] with HTTP `Range` requests.
ByteRangeReader httpRangeReader(String url, http.Client client) =>
    (offset, length) async {
      final res = await client.get(
        Uri.parse(url),
        headers: {'Range': 'bytes=$offset-${offset + length - 1}'},
      );
      if (res.statusCode == 416) return Uint8List(0); // past the end
      // A 200 is the whole file from byte 0: only right when that was asked.
      if (res.statusCode != 206 && !(res.statusCode == 200 && offset == 0)) {
        throw http.ClientException('Range read failed: HTTP ${res.statusCode}');
      }
      final body = res.bodyBytes;
      return body.length > length
          ? Uint8List.sublistView(body, 0, length)
          : body;
    };
