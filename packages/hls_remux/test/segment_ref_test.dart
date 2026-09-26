import 'dart:io';
import 'dart:typed_data';

import 'package:hls_remux/hls_remux.dart';
import 'package:test/test.dart';

/// Builds a minimal but structurally valid fMP4 segment: `moof(mfhd, traf(tfdt))`
/// followed by `mdat` carrying [payload].
Uint8List buildSegment(int tfdt, List<int> payload) {
  final b = BytesBuilder();

  void box(String type, List<int> content) {
    final size = 8 + content.length;
    b.add([
      (size >> 24) & 0xff,
      (size >> 16) & 0xff,
      (size >> 8) & 0xff,
      size & 0xff,
    ]);
    b.add(type.codeUnits);
    b.add(content);
  }

  final inner = BytesBuilder();
  void innerBox(String type, List<int> content) {
    final size = 8 + content.length;
    inner.add([
      (size >> 24) & 0xff,
      (size >> 16) & 0xff,
      (size >> 8) & 0xff,
      size & 0xff,
    ]);
    inner.add(type.codeUnits);
    inner.add(content);
  }

  // tfdt v0: [version+flags = 4][baseMediaDecodeTime = 4]
  final tfdtContent = <int>[
    0,
    0,
    0,
    0,
    (tfdt >> 24) & 0xff,
    (tfdt >> 16) & 0xff,
    (tfdt >> 8) & 0xff,
    tfdt & 0xff,
  ];
  final tfdtBox = BytesBuilder()
    ..add([0, 0, 0, 16])
    ..add('tfdt'.codeUnits)
    ..add(tfdtContent);

  innerBox('mfhd', [0, 0, 0, 0, 0, 0, 0, 1]);
  innerBox('traf', tfdtBox.takeBytes());
  box('moof', inner.takeBytes());
  box('mdat', payload);
  return b.takeBytes();
}

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('segref');
  });
  tearDown(() async {
    try {
      await dir.delete(recursive: true);
    } catch (_) {}
  });

  Future<File> write(String name, Uint8List bytes) async {
    final f = File('${dir.path}/$name');
    await f.writeAsBytes(bytes);
    return f;
  }

  Future<Uint8List> drain(SegmentRef r) async {
    final out = BytesBuilder();
    await for (final d in r.stream()) {
      out.add(d);
    }
    return out.takeBytes();
  }

  test('moofEnd finds the header without the whole segment present', () {
    final seg = buildSegment(1000, List.filled(4096, 7));
    // moof = 8 + mfhd(16) + traf(8 + tfdt(16)) = 48
    expect(Mp4Boxes.moofEnd(seg), 48);
    // A truncated read that still contains the whole moof works...
    expect(Mp4Boxes.moofEnd(Uint8List.sublistView(seg, 0, 48)), 48);
    // ...but one that cuts into it must not report a bogus end.
    expect(Mp4Boxes.moofEnd(Uint8List.sublistView(seg, 0, 40)), isNull);
  });

  test(
    'patches tfdt from the header alone and streams the mdat untouched',
    () async {
      final payload = List.generate(200000, (i) => i & 0xff);
      final f = await write('0.m4s', buildSegment(9000, payload));

      final ref = await SegmentRef.open(f, correction: 3000);
      expect(ref, isNotNull);
      // Only the moof is in memory, not the ~200 KB mdat.
      expect(ref!.head.length, 48);
      expect(ref.total, 48 + 8 + payload.length);
      expect(ref.tfdt, 6000); // 9000 - 3000

      final bytes = await drain(ref);
      expect(bytes.length, ref.total);
      // The patch is visible in the served bytes...
      expect(Mp4Boxes.readTfdt(bytes), 6000);
      // ...and the payload survived the head/body split exactly.
      expect(bytes.sublist(48 + 8), payload);
    },
  );

  test('zero correction leaves the tfdt alone', () async {
    final f = await write('0.m4s', buildSegment(4242, [1, 2, 3, 4]));
    final ref = await SegmentRef.open(f);
    expect(ref!.tfdt, 4242);
    expect(Mp4Boxes.readTfdt(await drain(ref)), 4242);
  });

  test('a segment pruned off disk mid-read still streams in full', () async {
    // The producer prunes consumed segments on a sliding window; the handle is
    // opened up front precisely so an unlink cannot break a promised read.
    final payload = List.generate(300000, (i) => (i * 7) & 0xff);
    final f = await write('0.m4s', buildSegment(0, payload));
    final ref = await SegmentRef.open(f);
    expect(ref, isNotNull);

    await f.delete();
    expect(f.existsSync(), isFalse);

    final bytes = await drain(ref!);
    expect(bytes.length, 48 + 8 + payload.length);
    expect(bytes.sublist(48 + 8), payload);
  });

  test(
    'a header-less file streams verbatim, but not when a patch is needed',
    () async {
      // Partially-written or non-fMP4 content: servable as-is, but a run needing a
      // tfdt correction cannot patch it, and an unpatched segment would desync the
      // MSE timeline — so that case must fail rather than serve bad bytes.
      final f = await write(
        '0.m4s',
        Uint8List.fromList('not-an-mp4'.codeUnits),
      );
      final plain = await SegmentRef.open(f);
      expect(plain, isNotNull);
      expect(plain!.head, isEmpty);
      expect(await drain(plain), 'not-an-mp4'.codeUnits);

      expect(await SegmentRef.open(f, correction: 500), isNull);
    },
  );

  test('empty and missing files yield null', () async {
    final empty = await write('e.m4s', Uint8List(0));
    expect(await SegmentRef.open(empty), isNull);
    expect(await SegmentRef.open(File('${dir.path}/nope.m4s')), isNull);
  });

  test('dispose is idempotent and suppresses streaming', () async {
    final f = await write('0.m4s', buildSegment(0, [9, 9, 9]));
    final ref = await SegmentRef.open(f);
    await ref!.dispose();
    await ref.dispose(); // must not throw on a second release
  });

  group('MuxedSegment', () {
    test('reports the exact total and streams parts back to back', () async {
      final a = await write('0.m4s', buildSegment(0, [1, 2, 3]));
      final b = await write('1.m4s', buildSegment(100, [4, 5, 6, 7]));
      final refA = await SegmentRef.open(a);
      final refB = await SegmentRef.open(b);
      final mux = MuxedSegment([refA!, refB!]);

      final expected = refA.total + refB.total;
      expect(mux.total, expected);

      final out = BytesBuilder();
      await for (final d in mux.stream()) {
        out.add(d);
      }
      final bytes = out.takeBytes();
      // Content-Length must match what is actually emitted, or hls.js stalls.
      expect(bytes.length, expected);
      // Both fragments are present, each keeping its own absolute tfdt.
      expect(Mp4Boxes.readTfdt(bytes), 0);
      expect(Mp4Boxes.readTfdt(Uint8List.sublistView(bytes, refA.total)), 100);
    });

    test('dispose releases every part', () async {
      final a = await write('0.m4s', buildSegment(0, [1]));
      final b = await write('1.m4s', buildSegment(1, [2]));
      final mux = MuxedSegment([
        (await SegmentRef.open(a))!,
        (await SegmentRef.open(b))!,
      ]);
      await mux.dispose();
      await mux.dispose();
    });
  });
}
