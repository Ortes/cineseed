// Standalone HLS server for browser verification WITHOUT Transmission/the SSH
// tunnel. Builds a real HlsSession from the presigned S3 URL and serves the
// same playlists + on-demand segments the production api.dart routes use,
// exercising the optimized path (range proxy + segment cache + prefetch).
//
//   dart run tool/hls_server.dart [presignedUrlFile] [port]
//
// Then open http://localhost:<port>/ in Chrome.
import 'dart:io';

import 'package:cineseed_backend/streaming/hls_playlists.dart';
import 'package:cineseed_backend/streaming/hls_session.dart';
import 'package:cineseed_backend/streaming/mkv_cues.dart';
import 'package:cineseed_backend/streaming/probe.dart';
import 'package:cineseed_backend/streaming/producer_manager.dart';
import 'package:cineseed_backend/streaming/s3_range_proxy.dart';
import 'package:cineseed_backend/streaming/segment_producer.dart';
import 'package:cineseed_backend/streaming/segment_ref.dart';
import 'package:cineseed_backend/streaming/segments.dart';
import 'package:cineseed_backend/streaming/transcode_pool.dart';

late HlsSession session;
late SegmentGenerator gen;

Future<void> main(List<String> args) async {
  final urlFile = args.isNotEmpty ? args.first : '/tmp/hlsgate/url.txt';
  final port = args.length > 1 ? int.parse(args[1]) : 8099;
  final url = File(urlFile).readAsStringSync().trim();

  final proxy = S3RangeProxy();
  await proxy.start();
  final local = proxy.register('probe', url);

  final probe = await MediaProbe.run(local);
  final cues = await MkvCues.fetch(local);
  if (probe == null || cues == null) {
    stderr.writeln('probe/cues failed');
    exit(1);
  }
  final duration =
      cues.durationSeconds ?? probe.duration ?? cues.keyframeTimes.last;
  final producerBoundaries = HlsSession.computeBoundaries(
    cues.keyframeTimes,
    duration,
    4,
  );
  final (boundaries, groupStart) = HlsSession.groupBoundaries(
    producerBoundaries,
    4,
  );
  session = HlsSession(
    id: 'probe',
    url: local,
    probe: probe,
    keyframes: cues.keyframeTimes,
    boundaries: boundaries,
    producerBoundaries: producerBoundaries,
    groupStart: groupStart,
    fileName: 'probe',
    urlExpiresAt: DateTime.now().add(const Duration(hours: 5)),
  );
  gen = SegmentGenerator(
    pool: TranscodePool(3),
    producerManager: ProducerManager(
      config: ProducerConfig(
        ffmpegBin: 'ffmpeg',
        tempRoot: Directory.systemTemp.path,
      ),
    ),
  );
  await gen.videoInit(session); // pre-warm codec string for the master

  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
  stdout.writeln(
    'HLS test server: http://localhost:$port/  '
    '(segments=${session.segmentCount}, audio=${probe.audio.length})',
  );
  await for (final req in server) {
    _handle(req);
  }
}

Future<void> _handle(HttpRequest req) async {
  final res = req.response;
  res.headers.set('Access-Control-Allow-Origin', '*');
  final p = req.uri.path;
  try {
    if (p == '/' || p == '/index.html') {
      res.headers.contentType = ContentType.html;
      res.write(_page);
      await res.close();
      return;
    }
    if (p == '/hls/master.m3u8') {
      await _m3u8(res, HlsPlaylists.master(session));
    } else if (RegExp(r'^/hls/m/(\d+)/index\.m3u8$').hasMatch(p)) {
      await _m3u8(res, HlsPlaylists.muxedMedia(session));
    } else if (RegExp(r'^/hls/m/(\d+)/init\.mp4$').firstMatch(p)
        case final m?) {
      final b = await gen.muxedInit(session, int.parse(m.group(1)!));
      b == null ? await _notFound(res) : await _mp4(res, b);
    } else if (RegExp(r'^/hls/m/(\d+)/(\d+)\.m4s$').firstMatch(p)
        case final m?) {
      final mux = await gen.muxedSegment(
        session,
        int.parse(m.group(1)!),
        int.parse(m.group(2)!),
      );
      mux == null ? await _notFound(res) : await _muxed(res, mux);
    } else {
      await _notFound(res);
    }
  } catch (e) {
    stderr.writeln('[hls] ERR $p: $e');
    res.statusCode = 500;
    await res.close();
  }
}

Future<void> _m3u8(HttpResponse res, String body) async {
  res.headers.contentType = ContentType('application', 'vnd.apple.mpegurl');
  res.write(body);
  await res.close();
}

Future<void> _mp4(HttpResponse res, List<int> bytes) async {
  res.headers.contentType = ContentType('video', 'mp4');
  res.add(bytes);
  await res.close();
}

/// Segments are streamed off disk rather than buffered, so the dev server has to
/// consume the stream the way the real route does — it owns open file handles.
Future<void> _muxed(HttpResponse res, MuxedSegment mux) async {
  res.headers.contentType = ContentType('video', 'mp4');
  res.headers.contentLength = mux.total;
  await res.addStream(mux.stream());
  await res.close();
}

Future<void> _notFound(HttpResponse res) async {
  res.statusCode = 404;
  await res.close();
}

const _page = '''
<!DOCTYPE html><html><head><meta charset="utf-8"><title>HLS opt test</title>
<script src="https://cdn.jsdelivr.net/npm/hls.js@1"></script></head>
<body style="background:#111;color:#0f0;font-family:monospace">
<video id="v" controls muted width="800" style="background:#000"></video>
<pre id="log"></pre>
<script>
window.__log=[];const L=(m)=>{window.__log.push(m);document.getElementById('log').textContent=window.__log.slice(-25).join('\\n');};
const v=document.getElementById('v');
window.__state=()=>({t:+v.currentTime.toFixed(2),dur:v.duration,err:v.error&&v.error.code,paused:v.paused,ready:v.readyState,
  buffered:v.buffered.length?[+v.buffered.start(0).toFixed(2),+v.buffered.end(v.buffered.length-1).toFixed(2)]:null});
window.__seek=(s)=>{v.currentTime=s;L('seek->'+s);};
if(Hls.isSupported()){
  const hls=new Hls();window.__hls=hls;
  hls.on(Hls.Events.ERROR,(e,d)=>L('ERROR '+d.type+' '+d.details+' fatal='+d.fatal));
  hls.on(Hls.Events.MEDIA_ATTACHED,()=>{L('attached');hls.loadSource('/hls/master.m3u8');});
  hls.on(Hls.Events.MANIFEST_PARSED,(e,d)=>L('manifest levels='+d.levels.length+' audio='+hls.audioTracks.length));
  hls.on(Hls.Events.FRAG_BUFFERED,(e,d)=>L('frag '+d.frag.type+' sn='+d.frag.sn+' ['+d.frag.start.toFixed(2)+'-'+(d.frag.start+d.frag.duration).toFixed(2)+']'));
  hls.attachMedia(v);
  v.addEventListener('canplay',()=>v.play().then(()=>L('play ok')).catch(e=>L('play err '+e)));
  v.addEventListener('timeupdate',()=>{if(!window.__lt||Date.now()-window.__lt>1500){window.__lt=Date.now();L('t='+v.currentTime.toFixed(2)+' buf='+(v.buffered.length?v.buffered.end(v.buffered.length-1).toFixed(2):'-'));}});
}else L('HLS unsupported');
</script></body></html>
''';
