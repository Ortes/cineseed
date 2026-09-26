import 'package:cineseed_streaming/cineseed_streaming.dart';
import 'package:test/test.dart';

HlsSession _sessionWith(List<AudioTrack> audio) => HlsSession(
  id: 'h',
  url: 'http://x/y',
  probe: MediaProbe(
    video: const VideoTrack(codec: 'hevc', width: 1920, height: 1080),
    audio: audio,
    subtitles: const [],
    duration: 100,
  ),
  keyframes: const [0, 6, 12],
  boundaries: const [0, 6, 12],
  producerBoundaries: const [0, 6, 12],
  groupStart: const [0, 1, 2],
);

AudioTrack _audio(int order, {bool isDefault = false}) => AudioTrack(
  order: order,
  codec: 'aac',
  channels: 2,
  sampleRate: 48000,
  language: 'en',
  isDefault: isDefault,
);

void main() {
  group('HlsPlaylists.master audio selection', () {
    test('defaults to the source default track when no ?a given', () {
      final s = _sessionWith([_audio(0), _audio(1, isDefault: true)]);
      expect(HlsPlaylists.master(s), contains('m/1/index.m3u8'));
      expect(HlsPlaylists.master(s), isNot(contains('m/0/index.m3u8')));
    });

    test('honours a valid requested audioOrder', () {
      final s = _sessionWith([_audio(0, isDefault: true), _audio(1)]);
      expect(HlsPlaylists.master(s, audioOrder: 1), contains('m/1/index.m3u8'));
    });

    test('falls back to the default for an out-of-range audioOrder', () {
      final s = _sessionWith([_audio(0, isDefault: true), _audio(1)]);
      expect(
        HlsPlaylists.master(s, audioOrder: 99),
        contains('m/0/index.m3u8'),
      );
    });
  });

  group('HlsSession.computeBoundaries', () {
    test('every keyframe is a boundary; ends at duration', () {
      final keyframes = [for (var i = 0; i <= 20; i++) i.toDouble()];
      final b = HlsSession.computeBoundaries(keyframes, 20, 6);
      // Every keyframe becomes a cut (anchor-independent so the -ss'd producer
      // reproduces them); the final boundary is the duration.
      expect(b, [for (var i = 0; i <= 20; i++) i.toDouble()]);
      // strictly increasing
      for (var i = 1; i < b.length; i++) {
        expect(b[i] > b[i - 1], isTrue);
      }
    });

    test('interior boundaries are exactly the keyframes (sparse/irregular)', () {
      // Mirrors the real test file's opening: a 10s gap forces a long segment.
      final keyframes = [0.0, 1.001, 4.004, 14.014, 15.307, 18.018, 28.028];
      final b = HlsSession.computeBoundaries(keyframes, 30, 6);
      expect(b, [...keyframes, 30.0]);
      // Every interior boundary is an actual keyframe (clean copy cut).
      for (final x in b.sublist(1, b.length - 1)) {
        expect(keyframes.contains(x), isTrue, reason: '$x not a keyframe');
      }
    });

    test('handles no keyframes by spanning the whole duration', () {
      expect(HlsSession.computeBoundaries([], 42, 6), [0, 42]);
    });

    test('keeps every keyframe incl. closely-spaced ones (open-GOP)', () {
      // Real "Arrival" keyframes. The previous absolute-grid grouping dropped
      // 4.213 (and others); cutting at EVERY keyframe is what makes the cut set
      // independent of the producer's -ss anchor, so file i.m4s == segment i.
      final keyframes = [0.0, 4.213, 12.095, 14.932, 18.852, 28.570, 38.997];
      final b = HlsSession.computeBoundaries(keyframes, 100, 6);
      expect(b, [0.0, 4.213, 12.095, 14.932, 18.852, 28.570, 38.997, 100]);
    });

    test('drops a keyframe sitting ~at the duration (no micro-segment)', () {
      final keyframes = [0.0, 6.0, 12.0, 19.99];
      final b = HlsSession.computeBoundaries(keyframes, 20, 6);
      expect(b, [0.0, 6.0, 12.0, 20.0]); // 19.99 within 0.05 of end → folded in
    });

    test('segment durations are positive and sum to duration', () {
      final keyframes = [for (var i = 0; i <= 100; i++) i.toDouble()];
      final b = HlsSession.computeBoundaries(keyframes, 100, 6);
      var sum = 0.0;
      for (var i = 0; i < b.length - 1; i++) {
        final d = b[i + 1] - b[i];
        expect(d > 0, isTrue);
        sum += d;
      }
      expect(sum, closeTo(100, 1e-9));
    });
  });

  group('HlsSession.groupBoundaries', () {
    test('merges micro keyframe intervals up to the floor', () {
      // A rapid-cut cluster (3×0.125s GOPs) between normal segments — a shape
      // seen in a real film that deadlocked hls.js when published per-keyframe.
      final fine = [0.0, 2.0, 4.5, 4.625, 4.750, 4.875, 6.0, 10.0];
      final (grouped, gs) = HlsSession.groupBoundaries(fine, 4);
      expect(grouped.first, 0.0);
      expect(grouped.last, 10.0);
      // Every playlist boundary is one of the fine (keyframe) boundaries.
      for (final x in grouped) {
        expect(fine.contains(x), isTrue, reason: '$x not a fine boundary');
      }
      // groupStart maps playlist boundaries back to fine indices.
      expect(gs.length, grouped.length);
      for (var i = 0; i < gs.length; i++) {
        expect(fine[gs[i]], grouped[i]);
      }
      // No playlist segment shorter than the floor.
      for (var i = 0; i < grouped.length - 1; i++) {
        expect(grouped[i + 1] - grouped[i], greaterThanOrEqualTo(4.0));
      }
    });

    test('merges a short tail into the previous group', () {
      final fine = [0.0, 4.0, 8.0, 8.5];
      final (grouped, gs) = HlsSession.groupBoundaries(fine, 4);
      expect(grouped, [0.0, 4.0, 8.5]); // 8.0→8.5 tail folded into 4.0→8.0
      expect(gs, [0, 1, 3]);
    });

    test('single-segment input passes through', () {
      final (grouped, gs) = HlsSession.groupBoundaries([0.0, 3.0], 4);
      expect(grouped, [0.0, 3.0]);
      expect(gs, [0, 1]);
    });
  });

  group('S3RangeProxy.parseRange', () {
    test('open-ended range clamps to EOF', () {
      expect(S3RangeProxy.parseRange('bytes=100-', 1000), (100, 999));
    });

    test('bounded range is honoured and clamped', () {
      expect(S3RangeProxy.parseRange('bytes=0-99', 1000), (0, 99));
      expect(S3RangeProxy.parseRange('bytes=900-5000', 1000), (900, 999));
    });

    test('suffix range returns the last N bytes', () {
      expect(S3RangeProxy.parseRange('bytes=-200', 1000), (800, 999));
      // Suffix larger than the file → whole file.
      expect(S3RangeProxy.parseRange('bytes=-5000', 1000), (0, 999));
    });

    test('rejects malformed / unsatisfiable ranges', () {
      expect(S3RangeProxy.parseRange('items=0-1', 1000), isNull);
      expect(S3RangeProxy.parseRange('bytes=1000-1001', 1000), isNull);
      expect(S3RangeProxy.parseRange('bytes=abc', 1000), isNull);
      expect(S3RangeProxy.parseRange('bytes=500-100', 1000), isNull);
    });
  });

  group('SegmentGenerator.trimPartialCue', () {
    // One complete cue, then a second block cut at every offset — whatever the
    // wall-clock kill lands on must still parse as WebVTT.
    const full =
        'WEBVTT\n\n'
        '05:00.466 --> 05:01.795\n<i>End of manifest.</i>\n\n'
        '05:04.899 --> 05:09.705\nI can\'t be\nthe only person here.\n';

    test('keeps a complete body untouched', () {
      expect(SegmentGenerator.trimPartialCue(full), full);
    });

    test('drops a cue cut mid-block, keeping the complete ones', () {
      for (var cut = full.indexOf('05:04'); cut < full.length; cut++) {
        final trimmed = SegmentGenerator.trimPartialCue(full.substring(0, cut));
        expect(
          trimmed,
          startsWith('WEBVTT\n\n05:00.466 --> 05:01.795\n'),
          reason: 'cut at $cut',
        );
        // Either the partial block is gone, or it is a whole cue: a timing
        // line plus at least one complete text line.
        final blocks = trimmed.split('\n\n');
        for (final b in blocks.skip(1).where((b) => b.isNotEmpty)) {
          expect(
            b,
            matches(RegExp(r'-->[^\n]*\n(?:[^\n]+\n?)+$')),
            reason: 'cut at $cut',
          );
        }
      }
    });

    test('header-only body (gap window) is left as is', () {
      expect(SegmentGenerator.trimPartialCue('WEBVTT\n\n'), 'WEBVTT\n\n');
    });
  });
}
