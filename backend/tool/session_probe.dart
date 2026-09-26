// End-to-end (no Transmission/Chrome) exercise of the optimized HLS generation
// path: proxy → ffprobe + MkvCues → HlsSession → SegmentGenerator (with its
// segment cache + prefetch + tfdt patching).
//
//   dart run tool/session_probe.dart [presignedUrlFile]
//
// Verifies: (1) cache/prefetch make sequential segments near-instant after the
// first; (2) seek-back is instant; (3) generated fragments tile (init+seg0+seg1
// concatenated reads as one continuous, monotonic stream under ffprobe).
import 'dart:io';

import 'package:cineseed_backend/streaming/hls_session.dart';
import 'package:cineseed_backend/streaming/mkv_cues.dart';
import 'package:cineseed_backend/streaming/probe.dart';
import 'package:cineseed_backend/streaming/producer_manager.dart';
import 'package:cineseed_backend/streaming/s3_range_proxy.dart';
import 'package:cineseed_backend/streaming/segment_producer.dart';
import 'package:cineseed_backend/streaming/segments.dart';
import 'package:cineseed_backend/streaming/transcode_pool.dart';

Future<void> main(List<String> args) async {
  final urlFile = args.isNotEmpty ? args.first : '/tmp/hlsgate/url.txt';
  final url = File(urlFile).readAsStringSync().trim();

  final proxy = S3RangeProxy(); // production defaults
  await proxy.start();
  final local = proxy.register('probe', url);

  final t0 = Stopwatch()..start();
  final probeF = MediaProbe.run(local);
  final cuesF = MkvCues.fetch(local);
  final probe = await probeF;
  final cues = await cuesF;
  print('build (probe∥cues): ${(t0.elapsedMilliseconds / 1000).toStringAsFixed(2)}s  '
      'video=${probe?.video?.codec} audio=${probe?.audio.length} subs=${probe?.subtitles.length} '
      'keyframes=${cues?.keyframeTimes.length}');
  if (probe == null || cues == null) {
    stderr.writeln('probe/cues failed');
    await proxy.stop();
    exit(1);
  }

  final duration = cues.durationSeconds ?? probe.duration ?? cues.keyframeTimes.last;
  final producerBoundaries =
      HlsSession.computeBoundaries(cues.keyframeTimes, duration, 4);
  final (boundaries, groupStart) =
      HlsSession.groupBoundaries(producerBoundaries, 4);
  final s = HlsSession(
      id: 'probe',
      url: local,
      probe: probe,
      keyframes: cues.keyframeTimes,
      boundaries: boundaries,
      producerBoundaries: producerBoundaries,
      groupStart: groupStart,
      fileName: 'probe',
      urlExpiresAt: DateTime.now().add(const Duration(hours: 5)));
  print('segments=${s.segmentCount} duration=${duration.toStringAsFixed(1)}s');

  final gen = SegmentGenerator(
    pool: TranscodePool(3),
    producerManager: ProducerManager(
      config: ProducerConfig(
        ffmpegBin: 'ffmpeg',
        tempRoot: Directory.systemTemp.path,
      ),
    ),
  );

  // Muxed model: one continuous ffmpeg per (session, audio track) emits fMP4
  // segments carrying video + that audio track. `muxedSegment(s, 0, i)` is the
  // default-track stream's segment i.
  Future<int> timeV(int i) async {
    final sw = Stopwatch()..start();
    print('  m0/$i ...');
    final b =
        await gen.muxedSegment(s, 0, i).timeout(const Duration(seconds: 25),
            onTimeout: () {
      print('  m0/$i TIMEOUT after 25s');
      return null;
    });
    print('  m0/$i  ${(sw.elapsedMilliseconds / 1000).toStringAsFixed(2)}s  ${b?.total ?? 0} bytes');
    // The ref owns open file handles; nothing here reads the bytes.
    await b?.dispose();
    return b?.total ?? 0;
  }

  print('=== video init (pre-warm) ===');
  final initSw = Stopwatch()..start();
  final init = await gen.videoInit(s);
  print('  init ${(initSw.elapsedMilliseconds / 1000).toStringAsFixed(2)}s  ${init.length} bytes  codec=${s.videoCodecString} ts=${s.videoTimescale}');

  print('=== sequential play (prefetch should make 1,2 instant) ===');
  await timeV(0);
  await timeV(1);
  await timeV(2);

  print('=== far seek then its follow-on ===');
  final mid = (s.segmentCount * 0.6).floor();
  await timeV(mid);
  await timeV(mid + 1);

  print('=== seek-back (cached) ===');
  await timeV(0);

  if (probe.audio.length > 1) {
    print('=== audio-track switch (muxed track 1, segment 0) ===');
    final aSw = Stopwatch()..start();
    final a0 = await gen.muxedSegment(s, 1, 0).timeout(
        const Duration(seconds: 25),
        onTimeout: () => null);
    print('  m1/0 ${(aSw.elapsedMilliseconds / 1000).toStringAsFixed(2)}s  ${a0?.total ?? 0} bytes');
    await a0?.dispose();
  }

  // --- tiling check: init + seg0 + seg1 must read as one continuous stream ---
  print('=== tiling check (init+m0+m1 concatenated) ===');
  final dir = await Directory.systemTemp.createTemp('tile_');
  final f = File('${dir.path}/joined.mp4');
  final sink = f.openWrite();
  sink.add((await gen.muxedInit(s, 0))!);
  await sink.addStream((await gen.muxedSegment(s, 0, 0))!.stream());
  await sink.addStream((await gen.muxedSegment(s, 0, 1))!.stream());
  await sink.close();
  final pr = await Process.run('ffprobe', [
    '-v', 'error', '-show_entries', 'format=duration', '-show_entries',
    'stream=nb_read_packets', '-count_packets', '-select_streams', 'v:0',
    '-of', 'default=noprint_wrappers=1', f.path,
  ]);
  print(pr.stdout.toString().trim());
  print('  expected ~${(s.segEnd(1) - s.segStart(0)).toStringAsFixed(2)}s across v0+v1');
  if (pr.exitCode != 0) stderr.writeln(pr.stderr);
  await dir.delete(recursive: true);

  await proxy.stop();
}
