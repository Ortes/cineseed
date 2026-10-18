import 'dart:io';
import 'dart:typed_data';

import 'mp4_boxes.dart';

/// Relabels an HEVC CRA picture as BLA_W_LP (the spec's splice point) wherever
/// the in-band VPS/SPS/PPS it carries differ from the previous IRAP picture's.
///
/// Some x265 encodes re-send a parameter set mid-stream with new contents under
/// the same id (seen: the PPS's default reference-list lengths, at some CRAs).
/// Chrome builds a new VideoToolbox format at any IRAP picture whose parameter
/// sets changed, and the decoder that gets it no longer holds the pictures the
/// CRA's RASL frames reference: the first one fails with
/// kVTVideoDecoderReferenceMissingErr (-17694) and playback dies — the source
/// file played directly fails the same way. A BLA picture's RASL frames are
/// never output, and Chrome drops them before VideoToolbox sees them. CRA and
/// BLA share the slice-header syntax, so the relabel is one byte per slice NAL
/// and costs only those few RASL frames, which Chrome couldn't decode anyway.
///
/// Chrome puts the init segment's parameter sets in front of every keyframe and
/// lets the in-band ones override them, so comparing the in-band ones alone is
/// exact when each type uses a single id, and errs towards relabelling if not.
///
/// Feed a run's files in decode order: the comparison carries across files. The
/// first IRAP picture seen is never relabelled — nothing precedes it.
class CraRelabeler {
  CraRelabeler(this.trackId, this.nalLengthSize);

  final int trackId;
  final int nalLengthSize;
  List<Uint8List>? _previous; // in-band parameter sets of the last IRAP picture

  static const _blaWLp = 16, _cra = 21, _vps = 32, _pps = 34;

  /// Relabels [f] in place; returns how many pictures were relabelled.
  int process(File f) {
    RandomAccessFile? raf;
    var relabelled = 0;
    try {
      raf = f.openSync(mode: FileMode.append); // read-write, keeps the contents
      final len = raf.lengthSync();
      var pos = 0;
      while (pos + 8 <= len) {
        raf.setPositionSync(pos);
        final h = raf.readSync(16);
        var size = ByteData.sublistView(h).getUint32(0);
        if (size == 1) size = ByteData.sublistView(h).getUint64(8);
        if (size < 8) break;
        if (String.fromCharCodes(h, 4, 8) == 'moof') {
          raf.setPositionSync(pos);
          final moof = raf.readSync(size);
          for (final (offset, n) in Mp4Boxes.sampleRanges(moof, pos, trackId)) {
            if (_sample(raf, offset, n)) relabelled++;
          }
        }
        pos += size;
      }
    } on FileSystemException {
      // Gone already — nothing will be served from it.
    } finally {
      raf?.closeSync();
    }
    return relabelled;
  }

  /// Walks one sample's NAL units to its first slice, relabelling the picture
  /// if it is a CRA whose parameter sets changed. Returns whether it was.
  bool _sample(RandomAccessFile raf, int offset, int size) {
    final params = <Uint8List>[];
    final end = offset + size;
    var relabel = false;
    var p = offset;
    while (p + nalLengthSize + 2 <= end) {
      raf.setPositionSync(p);
      final h = raf.readSync(nalLengthSize + 2);
      var n = 0;
      for (var i = 0; i < nalLengthSize; i++) {
        n = (n << 8) | h[i];
      }
      final type = (h[nalLengthSize] >> 1) & 0x3f;
      final body = p + nalLengthSize;
      if (type >= _vps && type <= _pps) {
        raf.setPositionSync(body);
        params.add(raf.readSync(n));
      } else if (type < _vps) {
        // A slice. The first one decides; later ones share the picture's type.
        if (!relabel) {
          if (type < 16 || type > 23) return false; // not IRAP
          final prev = _previous;
          _previous = params;
          relabel = type == _cra && prev != null && !_same(prev, params);
          if (!relabel) return false;
        }
        if (type == _cra) {
          raf.setPositionSync(body);
          raf.writeByteSync((h[nalLengthSize] & 0x81) | (_blaWLp << 1));
        }
      }
      p = body + n;
    }
    return relabel;
  }

  static bool _same(List<Uint8List> a, List<Uint8List> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].length != b[i].length) return false;
      for (var j = 0; j < a[i].length; j++) {
        if (a[i][j] != b[i][j]) return false;
      }
    }
    return true;
  }
}
