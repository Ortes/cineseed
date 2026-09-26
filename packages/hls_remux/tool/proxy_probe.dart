// Ad-hoc latency probe: run the real per-segment ffmpeg command THROUGH the
// caching range proxy and time it, vs. the ~10-12 s raw-S3 baseline.
//
//   dart run tool/proxy_probe.dart [presignedUrlFile]
//
// Defaults to /tmp/hlsgate/url.txt.
import 'dart:io';

import 'package:hls_remux/hls_remux.dart';

Future<void> main(List<String> args) async {
  final urlFile = args.isNotEmpty ? args.first : '/tmp/hlsgate/url.txt';
  final url = File(urlFile).readAsStringSync().trim();

  final proxy = S3RangeProxy(
    chunkSize: 8 << 20,
    readAheadChunks: 3,
    maxCacheBytes: 256 << 20,
  );
  await proxy.start();
  final local = proxy.register('probe', url);
  stdout.writeln('proxy: $local');

  Future<void> seg(num start) async {
    final dir = await Directory.systemTemp.createTemp('pp_');
    final sw = Stopwatch()..start();
    final res = await Process.run('ffmpeg', [
      '-nostdin',
      '-y',
      '-loglevel',
      'error',
      '-multiple_requests',
      '1',
      '-rw_timeout',
      '30000000',
      '-ss',
      start.toStringAsFixed(3),
      '-i',
      local,
      '-t',
      '7.5',
      '-map',
      '0:v:0',
      '-c:v',
      'copy',
      '-tag:v',
      'hvc1',
      '-f',
      'hls',
      '-hls_time',
      '5.9',
      '-hls_segment_type',
      'fmp4',
      '-hls_fmp4_init_filename',
      'init.mp4',
      '-hls_segment_filename',
      '${dir.path}/seg%d.m4s',
      '-hls_list_size',
      '0',
      '-hls_flags',
      'independent_segments',
      '${dir.path}/out.m3u8',
    ]);
    sw.stop();
    final f = File('${dir.path}/seg0.m4s');
    final bytes = f.existsSync() ? f.lengthSync() : 0;
    stdout.writeln(
      'seg@${start.toString().padRight(6)} '
      '${(sw.elapsedMilliseconds / 1000).toStringAsFixed(2)}s '
      'exit=${res.exitCode} bytes=$bytes',
    );
    if (res.exitCode != 0) stderr.writeln(res.stderr);
    await dir.delete(recursive: true);
  }

  stdout.writeln('=== cold: first opens fill the header/index cache ===');
  await seg(0);
  await seg(6); // first real seek → caches the EOF Cues chunk
  stdout.writeln('=== warm: index cached, only the new cluster is fetched ===');
  await seg(1800);
  await seg(3480);
  await seg(6900);
  stdout.writeln('=== seek-back: upstream chunks already cached ===');
  await seg(6);
  await seg(1800);

  stdout.writeln(
    '=== CONCURRENT burst: 3 raw ffmpegs at FRONT (like the harness) ===',
  );
  final sw = Stopwatch()..start();
  await Future.wait([seg(0), seg(12), seg(15)]).timeout(
    const Duration(seconds: 60),
    onTimeout: () {
      stdout.writeln('CONCURRENT TIMEOUT after 60s');
      return [];
    },
  );
  stdout.writeln(
    'concurrent total ${(sw.elapsedMilliseconds / 1000).toStringAsFixed(2)}s',
  );

  await proxy.stop();
}
