// Exercises the subtitle path only: proxy → probe/cues → HlsSession →
// SegmentGenerator.vttSegment, for a few windows on every text track.
//
//   dart run tool/vtt_probe.dart [presignedUrlFile]
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

  final proxy = S3RangeProxy();
  await proxy.start();
  final local = proxy.register('probe', url);

  final probeF = MediaProbe.run(local);
  final cuesF = MkvCues.fetch(local);
  final probe = await probeF;
  final cues = await cuesF;
  if (probe == null || cues == null) {
    stderr.writeln('probe/cues failed');
    await proxy.stop();
    exit(1);
  }
  final duration =
      cues.durationSeconds ?? probe.duration ?? cues.keyframeTimes.last;
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

  final gen = SegmentGenerator(
    pool: TranscodePool(3),
    producerManager: ProducerManager(
      config: ProducerConfig(
          ffmpegBin: 'ffmpeg', tempRoot: Directory.systemTemp.path),
    ),
  );

  print('segments=${s.segmentCount} subs=${probe.subtitles.length}');
  for (var t = 0; t < probe.subtitles.length; t++) {
    final sub = probe.subtitles[t];
    if (!sub.isText) continue;
    for (final i in [
      0,
      30,
      (s.segmentCount * 0.6).floor(),
      s.segmentCount - 2,
      s.segmentCount - 1,
    ]) {
      final sw = Stopwatch()..start();
      final vtt = await gen.vttSegment(s, t, i);
      final cueCount = RegExp('-->').allMatches(vtt ?? '').length;
      print('  s:$t "${sub.label}" seg $i @${s.segStart(i).toStringAsFixed(1)}s '
          '${(sw.elapsedMilliseconds / 1000).toStringAsFixed(2)}s '
          '${vtt?.length ?? 0}B cues=$cueCount '
          'first=${_firstCue(vtt)} last=${_lastCue(vtt)}');
    }
  }
  await proxy.stop();
  exit(0);
}

String _firstCue(String? vtt) {
  final m = RegExp(r'^.*-->.*$', multiLine: true).firstMatch(vtt ?? '');
  return m?.group(0)?.trim() ?? '-';
}

String _lastCue(String? vtt) {
  final all = RegExp(r'^.*-->.*$', multiLine: true).allMatches(vtt ?? '');
  return all.isEmpty ? '-' : all.last.group(0)!.trim();
}
