import 'dart:io';
import 'dart:typed_data';

import 'package:hls_remux/hls_remux.dart';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';

const _srt = '''1
00:00:01,000 --> 00:00:02,500
<i>Hello</i> & <font color="red">world</font>

2
00:00:03,000 --> 00:00:09,000
A long line
spanning windows

3
00:00:15,000 --> 00:00:16,000
{\\an8}Top <b>bold</b>
''';

const _ass = r'''[Script Info]
ScriptType: v4.00+

[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
Style: Default,Arial,20,&H00FFFFFF,&H000000FF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,2,0,2,10,10,10,1

[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
Dialogue: 0,0:00:05.00,0:00:07.00,Default,,0,0,0,,{\i1}Salut{\i0}, toi\Nligne deux
Dialogue: 0,0:00:11.00,0:00:12.00,Default,,0,0,0,,{\p1}m 0 0 l 10 10{\p0}Dessin, a < b
''';

void main() {
  late Directory dir;
  late LocalRangeServer server;
  late http.Client client;
  late String url;
  late MkvCues cues;
  late ByteRangeReader direct;
  late ByteRangeReader scan;

  setUpAll(() async {
    dir = await Directory.systemTemp.createTemp('mkv_subtitles_');
    File('${dir.path}/a.srt').writeAsStringSync(_srt);
    File('${dir.path}/b.ass').writeAsStringSync(_ass);
    final mkv = '${dir.path}/film.mkv';
    // 20 s, a keyframe every 2 s; ffmpeg indexes every subtitle block in the
    // Cues, as mkvmerge does.
    final r = await Process.run('ffmpeg', [
      ...'-v error -y -f lavfi -i testsrc=duration=20:size=160x120:rate=24'
          .split(' '),
      ...['-i', '${dir.path}/a.srt', '-i', '${dir.path}/b.ass'],
      ...'-map 0 -map 1 -map 2 -c:v mpeg4 -g 48 -c:s copy'.split(' '),
      mkv,
    ]);
    if (r.exitCode != 0) fail('ffmpeg: ${r.stderr}');

    server = LocalRangeServer();
    await server.start();
    url = server.register('film', CompleteFile(mkv));
    client = http.Client();
    cues = (await MkvCues.fetch(url))!;
    direct = (o, n) async => (await server.read('film', o, n))!;
    scan = httpRangeReader(url, client);
  });

  tearDownAll(() async {
    client.close();
    await server.stop();
    await dir.delete(recursive: true);
  });

  MkvTrack track(int order) => cues.subtitleTracks[order];

  test('indexes the subtitle tracks and their blocks', () {
    expect(cues.subtitleTracks.map((t) => t.codecId), [
      'S_TEXT/UTF8',
      'S_TEXT/ASS',
    ]);
    expect(cues.subtitleCues[track(0).number], hasLength(3));
    expect(cues.subtitleCues[track(1).number], hasLength(2));
    expect(cues.clusterCues, isNotEmpty);
  });

  test('reading the index and scanning the clusters agree', () async {
    for (var order = 0; order < 2; order++) {
      for (var start = 0.0; start < 20; start += 4) {
        final a = await MkvSubtitles.indexed(
          cues,
          track(order),
          start,
          start + 4,
          direct,
        );
        final b = await MkvSubtitles.scan(
          cues,
          track(order),
          start,
          start + 4,
          scan,
        );
        expect(a, b, reason: 'track $order @$start');
      }
    }
  });

  test('a window holds every cue shown during it, converted', () async {
    Future<String> vtt(int order, double start, double end) =>
        MkvSubtitles.window(
          cues,
          track(order),
          start,
          end,
          direct: direct,
          scan: scan,
        );

    expect(
      await vtt(0, 0, 4),
      'WEBVTT\n\n'
      '00:00:01.000 --> 00:00:02.500\n<i>Hello</i> &amp; world\n\n'
      '00:00:03.000 --> 00:00:09.000\nA long line\nspanning windows\n\n',
    );
    // Started in the previous window, still on screen in this one.
    expect(
      await vtt(0, 8, 12),
      'WEBVTT\n\n'
      '00:00:03.000 --> 00:00:09.000\nA long line\nspanning windows\n\n',
    );
    expect(
      await vtt(0, 12, 16),
      'WEBVTT\n\n00:00:15.000 --> 00:00:16.000\nTop <b>bold</b>\n\n',
    );
    expect(await vtt(0, 16, 20), 'WEBVTT\n\n');
    expect(
      await vtt(1, 4, 8),
      'WEBVTT\n\n00:00:05.000 --> 00:00:07.000\n<i>Salut</i>, toi\nligne deux\n\n',
    );
    expect(
      await vtt(1, 8, 12),
      'WEBVTT\n\n00:00:11.000 --> 00:00:12.000\nDessin, a &lt; b\n\n',
    );
  });

  test('cue text keeps i/b/u, drops other markup, escapes', () {
    String srt(String s) =>
        MkvSubtitles.cueText('S_TEXT/UTF8', Uint8List.fromList(s.codeUnits));
    expect(srt('<I>a</I>\r\n\r\nb --> c'), '<i>a</i>\nb --&gt; c');
    expect(srt('<font face="x">a</font> <u>b</u>'), 'a <u>b</u>');
    expect(srt('padded\x00\x00'), 'padded');
    String ass(String s) =>
        MkvSubtitles.cueText('S_TEXT/ASS', Uint8List.fromList(s.codeUnits));
    expect(ass(r'3,0,Default,,0,0,0,,{\b700\c&HFF&}x{\b0}\hy'), '<b>x</b> y');
    expect(ass(r'4,0,Default,,0,0,0,,{\i1}open'), '<i>open</i>');
  });
}
