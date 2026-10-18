import 'dart:io';
import 'dart:typed_data';

import 'package:hls_remux/hls_remux.dart';
import 'package:test/test.dart';

// HEVC NAL unit types.
const trailR = 1, raslN = 8, blaWLp = 16, idr = 19, cra = 21;
const vps = 32, sps = 33, pps = 34, aud = 35;

List<int> u32(int v) => [v >> 24 & 255, v >> 16 & 255, v >> 8 & 255, v & 255];

List<int> box(String type, List<int> payload) => [
  ...u32(8 + payload.length),
  ...type.codeUnits,
  ...payload,
];

/// A length-prefixed (4-byte) NAL unit of [type] with [payload].
List<int> nal(int type, [List<int> payload = const [0xAF]]) => [
  ...u32(2 + payload.length),
  type << 1,
  1,
  ...payload,
];

/// An init segment whose HEVC track is [trackId], NAL size prefix 4 bytes.
Uint8List init(int trackId) {
  final hvcc = List<int>.filled(23, 0)..[21] = 0x03; // lengthSizeMinusOne = 3
  final hvc1 = box('hvc1', [...List.filled(78, 0), ...box('hvcC', hvcc)]);
  final stsd = box('stsd', [...u32(0), ...u32(1), ...hvc1]);
  final tkhd = box('tkhd', [...u32(0), ...u32(0), ...u32(0), ...u32(trackId)]);
  final mdia = box('mdia', box('minf', box('stbl', stsd)));
  return Uint8List.fromList(box('moov', box('trak', [...tkhd, ...mdia])));
}

/// One fMP4 fragment (moof+mdat) of [samples] on track [trackId].
Uint8List fragment(int trackId, List<List<int>> samples) {
  List<int> moof(int dataOffset) => box(
    'moof',
    box('traf', [
      ...box('tfhd', [...u32(0x020000), ...u32(trackId)]),
      ...box('trun', [
        ...u32(0x000201), // data-offset + sample-size present
        ...u32(samples.length),
        ...u32(dataOffset),
        for (final s in samples) ...u32(s.length),
      ]),
    ]),
  );
  final head = moof(0);
  final mdat = box('mdat', [for (final s in samples) ...s]);
  return Uint8List.fromList([...moof(head.length + 8), ...mdat]);
}

/// A keyframe sample: AUD, VPS, SPS, PPS([ppsBody]), then two slice segments.
List<int> keyframe(int type, List<int> ppsBody) => [
  ...nal(aud),
  ...nal(vps, [1]),
  ...nal(sps, [2]),
  ...nal(pps, ppsBody),
  ...nal(type),
  ...nal(type),
];

/// The NAL unit types of each track-1 sample in [f], in order.
List<List<int>> types(File f) {
  final b = f.readAsBytesSync();
  final moofLen = ByteData.sublistView(b).getUint32(0);
  return [
    for (final (off, size) in Mp4Boxes.sampleRanges(
      b.sublist(0, moofLen),
      0,
      1,
    ))
      [
        for (
          var p = off;
          p < off + size;
          p += 4 + ByteData.sublistView(b).getUint32(p)
        )
          (b[p + 4] >> 1) & 0x3f,
      ],
  ];
}

void main() {
  late Directory tmp;
  setUp(() async => tmp = await Directory.systemTemp.createTemp('cra_'));
  tearDown(() => tmp.delete(recursive: true));

  File write(String name, Uint8List bytes) =>
      File('${tmp.path}/$name')..writeAsBytesSync(bytes);

  test('hevcTrack reads the track id and NAL length size', () {
    expect(Mp4Boxes.hevcTrack(init(7)), (trackId: 7, nalLengthSize: 4));
    expect(Mp4Boxes.hevcTrack(Uint8List(0)), isNull);
  });

  test('relabels only CRAs whose parameter sets changed', () {
    final r = CraRelabeler(1, 4);
    final rasl = nal(raslN), trail = nal(trailR);
    final files = [
      [
        keyframe(cra, [0xA0]),
        rasl,
        trail,
      ], // first: nothing to compare with
      [
        keyframe(cra, [0xA0]),
        rasl,
        trail,
      ], // same PPS
      [
        keyframe(cra, [0xB0]),
        rasl,
        trail,
      ], // PPS changed → BLA
      [
        keyframe(cra, [0xB0]),
        rasl,
        trail,
      ], // same as the previous one
      [
        keyframe(idr, [0xA0]),
        trail,
      ], // changed, but an IDR resets anyway
      [
        keyframe(cra, [0xA0]),
        rasl,
        trail,
      ], // same as the IDR
    ];
    final counts = <int>[];
    for (final (i, samples) in files.indexed) {
      final f = write('$i.m4s', fragment(1, samples));
      final before = f.lengthSync();
      counts.add(r.process(f));
      expect(f.lengthSync(), before, reason: 'patched in place');
    }
    expect(counts, [0, 0, 1, 0, 0, 0]);
    expect(types(File('${tmp.path}/2.m4s')), [
      [aud, vps, sps, pps, blaWLp, blaWLp],
      [raslN],
      [trailR],
    ]);
    expect(types(File('${tmp.path}/1.m4s')).first.last, cra);
  });

  test('ignores other tracks', () {
    final r = CraRelabeler(1, 4);
    r.process(
      write(
        'a.m4s',
        fragment(2, [
          keyframe(cra, [0xA0]),
        ]),
      ),
    );
    r.process(
      write(
        'b.m4s',
        fragment(2, [
          keyframe(cra, [0xB0]),
        ]),
      ),
    );
    final b = File('${tmp.path}/b.m4s').readAsBytesSync();
    expect(
      b,
      fragment(2, [
        keyframe(cra, [0xB0]),
      ]),
    );
  });
}
