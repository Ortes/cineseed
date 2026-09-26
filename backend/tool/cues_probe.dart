// Throwaway tool: verify MkvCues.fetch reads only KBs and returns sane
// keyframe boundaries. Usage: dart run tool/cues_probe.dart "<presigned-url>"
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:cineseed_backend/streaming/mkv_cues.dart';

class _CountingClient extends http.BaseClient {
  final http.Client _inner = http.Client();
  int bytes = 0;
  int requests = 0;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests++;
    final res = await _inner.send(request);
    final data = await res.stream.toBytes();
    bytes += data.length;
    return http.StreamedResponse(
      Stream.value(data),
      res.statusCode,
      headers: res.headers,
      reasonPhrase: res.reasonPhrase,
    );
  }
}

void main(List<String> args) async {
  final url = args.isNotEmpty
      ? args[0]
      : File('/tmp/hlsgate_url.txt').readAsStringSync().trim();
  final client = _CountingClient();
  final sw = Stopwatch()..start();
  final cues = await MkvCues.fetch(url, client: client);
  sw.stop();
  if (cues == null) {
    print('NO CUES (HLS-ineligible)');
    return;
  }
  final t = cues.keyframeTimes;
  print('keyframes: ${t.length}');
  print('first 8: ${t.take(8).map((x) => x.toStringAsFixed(3)).toList()}');
  print(
    'last: ${t.last.toStringAsFixed(3)}  duration: ${cues.durationSeconds?.toStringAsFixed(3)}',
  );
  // gaps
  final gaps = <double>[];
  for (var i = 1; i < t.length; i++) {
    gaps.add(t[i] - t[i - 1]);
  }
  gaps.sort();
  print(
    'gap min/median/max: ${gaps.first.toStringAsFixed(3)} / '
    '${gaps[gaps.length ~/ 2].toStringAsFixed(3)} / ${gaps.last.toStringAsFixed(3)}',
  );
  print(
    'HTTP requests: ${client.requests}  bytes read: ${client.bytes} '
    '(${(client.bytes / 1024).toStringAsFixed(1)} KiB) in ${sw.elapsedMilliseconds}ms',
  );
  if (args.length >= 3) {
    final lo = double.parse(args[1]), hi = double.parse(args[2]);
    final inRange = t.where((x) => x >= lo && x <= hi).toList();
    print(
      'cues in [$lo,$hi]: ${inRange.map((e) => e.toStringAsFixed(3)).toList()}',
    );
  }
}
