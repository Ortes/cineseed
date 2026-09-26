import 'dart:convert';
import 'dart:io';

import 'package:hls_remux/hls_remux.dart';
import 'package:test/test.dart';

/// Consumes a segment ref's stream (closing its file handle) as a string.
Future<String> drain(SegmentRef r) async {
  final out = <int>[];
  await for (final d in r.stream()) {
    out.addAll(d);
  }
  return utf8.decode(out);
}

/// A fake "ffmpeg": parses `-hls_segment_filename <dir>/%d.m4s` and
/// `-start_number N`, writes init.mp4 + 6 segments (atomic .tmp→rename, like
/// ffmpeg's temp_file flag) 20ms apart, then idles reading stdin until it gets
/// `q` (graceful quit) or EOF. Respects SIGSTOP/SIGCONT naturally.
const _mockFfmpeg = r'''#!/usr/bin/env bash
dir=""; start=0
while [ $# -gt 0 ]; do
  case "$1" in
    -hls_segment_filename) dir="$(dirname "$2")"; shift 2;;
    -start_number) start="$2"; shift 2;;
    *) shift;;
  esac
done
mkdir -p "$dir"
: > "$dir/init.mp4"
i=$start
n=$((start+6))
while [ $i -lt $n ]; do
  printf 'seg%d' "$i" > "$dir/$i.m4s.tmp" && mv "$dir/$i.m4s.tmp" "$dir/$i.m4s"
  i=$((i+1))
  sleep 0.02
done
while read -r line; do [ "$line" = "q" ] && break; done
exit 0
''';

void main() {
  late Directory tmp;
  late String mockBin;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('vp_test_');
    mockBin = '${tmp.path}/mock_ffmpeg.sh';
    await File(mockBin).writeAsString(_mockFfmpeg);
    await Process.run('chmod', ['+x', mockBin]);
  });

  tearDown(() async {
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  ProducerConfig cfg({int throttle = 30, int retain = 50, Duration? idle}) =>
      ProducerConfig(
        ffmpegBin: mockBin,
        tempRoot: '${tmp.path}/sessions',
        targetSeconds: 6,
        throttleAheadSegments: throttle,
        retainBehindSegments: retain,
        pollInterval: const Duration(milliseconds: 30),
        segmentTimeout: const Duration(seconds: 3),
        idleKillDelay: idle ?? const Duration(seconds: 60),
      );

  final boundaries = [for (var i = 0; i <= 10; i++) (i * 6).toDouble()];

  Future<SegmentProducer> startAt(int seg, ProducerConfig c) =>
      SegmentProducer.start(
        label: 'v:h',
        url: 'http://127.0.0.1/none',
        boundaries: boundaries,
        timescale: 16000,
        startSegment: seg,
        outputArgs: const ['-map', '0:v:0', '-c:v', 'copy'],
        config: c,
      );

  test(
    'serves produced segments and waits for not-yet-produced ones',
    () async {
      final p = await startAt(0, cfg());
      addTearDown(p.kill);

      final s0 = await p.awaitSegment(0);
      expect(s0, isNotNull);
      expect(await drain(s0!), 'seg0');

      // Segment 5 is written ~100ms in; awaitSegment must block then resolve.
      final s5 = await p.awaitSegment(5);
      expect(s5, isNotNull);
      expect(await drain(s5!), 'seg5');

      expect(p.highWater, greaterThanOrEqualTo(5));
      expect(p.isAlive, isTrue);
    },
  );

  test('canServe reflects start segment and production frontier', () async {
    final p = await startAt(2, cfg());
    addTearDown(p.kill);
    await p.awaitSegment(2); // ensure running
    expect(p.canServe(1), isFalse, reason: 'before startSegment');
    expect(p.canServe(2), isTrue);
    // far ahead of the frontier (+ reorder window) → not serveable without restart
    expect(p.canServe(p.highWater + 100), isFalse);
  });

  test(
    'prunes consumed segments behind the client and raises the floor',
    () async {
      // retain 2 behind the playhead: with segs 0..5 on disk and the client at 5,
      // pruneBelow = 5 - 2 = 3, so 0/1/2 are deleted and the floor moves to 3.
      final p = await startAt(0, cfg(retain: 2));
      addTearDown(p.kill);
      await p.awaitSegment(5); // all six produced, highWater >= 5
      final dir = p.tempPath;
      expect(File('$dir/0.m4s').existsSync(), isTrue);

      p.noteRequest(5); // advance the playhead
      // Wait for a scan tick to run the sliding-window cleanup.
      await Future.delayed(const Duration(milliseconds: 120));

      expect(
        File('$dir/2.m4s').existsSync(),
        isFalse,
        reason: 'pruned below floor',
      );
      expect(File('$dir/0.m4s').existsSync(), isFalse);
      expect(File('$dir/3.m4s').existsSync(), isTrue, reason: 'kept: at floor');
      expect(p.canServe(2), isFalse, reason: 'below floor → needs restart');
      expect(p.canServe(3), isTrue);
      expect(p.canServe(5), isTrue);
    },
  );

  test('out-of-range and below-start segments return null', () async {
    final p = await startAt(3, cfg());
    addTearDown(p.kill);
    expect(await p.awaitSegment(0), isNull); // below startSegment
    expect(await p.awaitSegment(999), isNull); // beyond segmentCount
  });

  test('kill removes the temp dir and marks dead', () async {
    final p = await startAt(0, cfg());
    await p.awaitSegment(0);
    final dir = p.tempPath;
    expect(Directory(dir).existsSync(), isTrue);
    await p.kill();
    expect(p.isAlive, isFalse);
    expect(Directory(dir).existsSync(), isFalse);
  });

  test(
    'goes idle and self-kills after the idle delay with no requests',
    () async {
      final p = await startAt(0, cfg(idle: const Duration(milliseconds: 200)));
      addTearDown(p.kill);
      p.retain();
      await p.awaitSegment(0);
      p.release(); // refCount → 0, idle timer starts
      await Future.delayed(const Duration(milliseconds: 500));
      expect(p.isAlive, isFalse);
    },
  );
}
