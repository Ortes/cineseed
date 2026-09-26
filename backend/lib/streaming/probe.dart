import 'dart:convert';
import 'dart:io';

/// One audio rendition discovered in the source file.
class AudioTrack {
  /// Index among audio streams (the `N` in ffmpeg `-map 0:a:N`).
  final int order;
  final String codec;
  final int channels;
  final int sampleRate;
  final String? language;
  final String? title;
  final bool isDefault;

  const AudioTrack({
    required this.order,
    required this.codec,
    required this.channels,
    required this.sampleRate,
    this.language,
    this.title,
    this.isDefault = false,
  });

  /// Browsers (Chrome) decode AAC; Dolby/DTS/etc must be transcoded to AAC.
  bool get needsTranscode => codec.toLowerCase() != 'aac';

  /// Label for the HLS rendition NAME attribute.
  String get label {
    final parts = <String>[];
    if (title != null && title!.isNotEmpty) parts.add(title!);
    if (language != null && language!.isNotEmpty)
      parts.add(language!.toUpperCase());
    if (parts.isEmpty) parts.add('Audio ${order + 1}');
    return parts.join(' · ');
  }
}

/// One subtitle track. Only text subs become WebVTT; image subs are skipped.
class SubtitleTrack {
  final int order; // the `N` in `-map 0:s:N`
  final String codec;
  final String? language;
  final String? title;

  const SubtitleTrack({
    required this.order,
    required this.codec,
    this.language,
    this.title,
  });

  static const _textCodecs = {
    'subrip',
    'srt',
    'ass',
    'ssa',
    'mov_text',
    'webvtt',
    'text',
    'subviewer',
  };

  bool get isText => _textCodecs.contains(codec.toLowerCase());

  String get label {
    final parts = <String>[];
    if (title != null && title!.isNotEmpty) parts.add(title!);
    if (language != null && language!.isNotEmpty)
      parts.add(language!.toUpperCase());
    if (parts.isEmpty) parts.add('Sub ${order + 1}');
    return parts.join(' · ');
  }
}

class VideoTrack {
  final String codec;
  final int width;
  final int height;
  const VideoTrack({
    required this.codec,
    required this.width,
    required this.height,
  });
}

/// Result of probing the source: one video track + audio/subtitle renditions.
class MediaProbe {
  final VideoTrack? video;
  final List<AudioTrack> audio;
  final List<SubtitleTrack> subtitles;
  final double? duration;

  const MediaProbe({
    required this.video,
    required this.audio,
    required this.subtitles,
    required this.duration,
  });

  /// Runs `ffprobe` (headers only — cheap) against a URL or path.
  static Future<MediaProbe?> run(
    String source, {
    String ffprobe = 'ffprobe',
  }) async {
    final res = await Process.run(ffprobe, [
      '-v',
      'quiet',
      '-print_format',
      'json',
      '-show_streams',
      '-show_format',
      source,
    ]);
    if (res.exitCode != 0) return null;
    final Map<String, dynamic> json;
    try {
      json = jsonDecode(res.stdout as String) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }

    final streams = (json['streams'] as List? ?? [])
        .cast<Map<String, dynamic>>();
    VideoTrack? video;
    final audio = <AudioTrack>[];
    final subtitles = <SubtitleTrack>[];
    var aOrder = 0, sOrder = 0;

    for (final s in streams) {
      final type = s['codec_type'] as String?;
      final codec = (s['codec_name'] as String?) ?? '';
      final tags = (s['tags'] as Map?)?.cast<String, dynamic>() ?? const {};
      final lang = tags['language'] as String?;
      final title = tags['title'] as String?;
      switch (type) {
        case 'video':
          // Skip cover-art / attached pics (they report as video streams).
          final disp = (s['disposition'] as Map?)?.cast<String, dynamic>();
          if (disp != null && (disp['attached_pic'] == 1)) break;
          video ??= VideoTrack(
            codec: codec,
            width: (s['width'] as num?)?.toInt() ?? 0,
            height: (s['height'] as num?)?.toInt() ?? 0,
          );
        case 'audio':
          final disp = (s['disposition'] as Map?)?.cast<String, dynamic>();
          audio.add(
            AudioTrack(
              order: aOrder++,
              codec: codec,
              channels: (s['channels'] as num?)?.toInt() ?? 2,
              sampleRate: int.tryParse('${s['sample_rate'] ?? ''}') ?? 48000,
              language: lang,
              title: title,
              isDefault: disp != null && disp['default'] == 1,
            ),
          );
        case 'subtitle':
          subtitles.add(
            SubtitleTrack(
              order: sOrder++,
              codec: codec,
              language: lang,
              title: title,
            ),
          );
      }
    }

    final fmt = (json['format'] as Map?)?.cast<String, dynamic>();
    final dur = double.tryParse('${fmt?['duration'] ?? ''}');

    return MediaProbe(
      video: video,
      audio: audio,
      subtitles: subtitles,
      duration: dur,
    );
  }
}
