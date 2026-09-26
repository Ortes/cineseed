import 'dart:math' as math;

import 'hls_session.dart';

/// Builds HLS manifests (master + media playlists) in memory from a session.
class HlsPlaylists {
  static const subGroup = 'sub';

  /// Master playlist: ONE muxed (video+audio) variant + (text) subtitle
  /// renditions. Jellyfin-style — video and audio are interleaved in a single
  /// fMP4 stream, so there is no separate audio rendition group. The variant
  /// embeds the requested [audioOrder] (else the source's DEFAULT track, else
  /// the first), so Chrome gets sound without any track UI. Switching audio
  /// means reloading this master with a different `?a=<order>` so its variant
  /// points at `m/<order>/index.m3u8` (the frontend swaps the hls.js source).
  static String master(HlsSession s, {int? audioOrder}) {
    final b = StringBuffer()
      ..writeln('#EXTM3U')
      ..writeln('#EXT-X-VERSION:7');

    final audio = s.probe.audio;
    var defaultIdx = audio.indexWhere((a) => a.isDefault);
    if (defaultIdx < 0) defaultIdx = 0;
    final fallbackOrder = audio.isNotEmpty ? audio[defaultIdx].order : 0;
    // Honour an explicit, valid track request; else fall back to the default.
    final selectedOrder =
        (audioOrder != null && audio.any((a) => a.order == audioOrder))
            ? audioOrder
            : fallbackOrder;

    final textSubs = s.probe.subtitles.where((x) => x.isText).toList();
    for (final sub in textSubs) {
      b.writeln('#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="$subGroup",'
          'NAME="${_esc(sub.label)}",'
          '${sub.language != null ? 'LANGUAGE="${sub.language}",' : ''}'
          'DEFAULT=NO,AUTOSELECT=NO,FORCED=NO,'
          'URI="s/${sub.order}/index.m3u8"');
    }

    final codecs = <String>[];
    if (s.videoCodecString != null) codecs.add(s.videoCodecString!);
    if (audio.isNotEmpty) codecs.add('mp4a.40.2');

    final streamInf = StringBuffer('#EXT-X-STREAM-INF:BANDWIDTH=6000000');
    if (codecs.isNotEmpty) streamInf.write(',CODECS="${codecs.join(',')}"');
    if (s.probe.video != null) {
      streamInf.write(',RESOLUTION=${s.probe.video!.width}x${s.probe.video!.height}');
    }
    if (textSubs.isNotEmpty) streamInf.write(',SUBTITLES="$subGroup"');
    b
      ..writeln(streamInf.toString())
      ..writeln('m/$selectedOrder/index.m3u8');
    return b.toString();
  }

  /// Muxed media playlist for one audio track — segments tile on the video
  /// keyframe boundaries (the muxer cuts on video keyframes; audio rides along).
  static String muxedMedia(HlsSession s) => _media(s.boundaries, 'init.mp4');

  /// WebVTT subtitle playlist segmented on the same boundaries as the media,
  /// so hls.js fetches only the cues for the window it needs (each `<i>.vtt`
  /// is a fast windowed ffmpeg seek) instead of one whole-file segment.
  static String subtitleMedia(HlsSession s) {
    var maxDur = 0.0;
    for (var i = 0; i < s.segmentCount; i++) {
      maxDur = math.max(maxDur, s.segDuration(i));
    }
    final b = StringBuffer()
      ..writeln('#EXTM3U')
      ..writeln('#EXT-X-VERSION:7')
      ..writeln('#EXT-X-TARGETDURATION:${maxDur.ceil()}')
      ..writeln('#EXT-X-PLAYLIST-TYPE:VOD');
    for (var i = 0; i < s.segmentCount; i++) {
      b
        ..writeln('#EXTINF:${s.segDuration(i).toStringAsFixed(6)},')
        ..writeln('$i.vtt');
    }
    b.writeln('#EXT-X-ENDLIST');
    return b.toString();
  }

  static String _media(List<double> boundaries, String initName) {
    final count = boundaries.length - 1;
    var maxDur = 0.0;
    for (var i = 0; i < count; i++) {
      maxDur = math.max(maxDur, boundaries[i + 1] - boundaries[i]);
    }
    final b = StringBuffer()
      ..writeln('#EXTM3U')
      ..writeln('#EXT-X-VERSION:7')
      ..writeln('#EXT-X-TARGETDURATION:${maxDur.ceil()}')
      ..writeln('#EXT-X-PLAYLIST-TYPE:VOD')
      ..writeln('#EXT-X-MAP:URI="$initName"');
    for (var i = 0; i < count; i++) {
      b
        ..writeln('#EXTINF:${(boundaries[i + 1] - boundaries[i]).toStringAsFixed(6)},')
        ..writeln('$i.m4s');
    }
    b.writeln('#EXT-X-ENDLIST');
    return b.toString();
  }

  static String _esc(String v) => v.replaceAll('"', "'");
}
