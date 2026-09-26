import 'dart:async';
import 'dart:js_interop';

import 'package:cineseed_shared/cineseed_shared.dart';
import 'package:chewie/chewie.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:video_player/video_player.dart';
import 'package:video_player_web_hls/video_player_web_hls.dart';
import 'package:web/web.dart' as web;

import '../../core/debug_log.dart';
import '../../core/providers.dart';
import 'cast_button.dart';

class PlayerScreen extends HookConsumerWidget {
  final String hash;

  /// Which video file inside the torrent to play — its index in the torrent's
  /// own file list. Null means the torrent's primary (largest) video, which is
  /// all a single-video torrent has.
  final int? fileIndex;

  /// Shown in the AppBar instead of the torrent name — the episode's filename,
  /// when the user picked it from a multi-file torrent.
  final String? title;

  const PlayerScreen({
    super.key,
    required this.hash,
    this.fileIndex,
    this.title,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final video = useState<VideoPlayerController?>(null);
    final chewie = useState<ChewieController?>(null);
    final error = useState<Object?>(null);
    final downloading = useState(false);
    // Whether we're presenting fullscreen. Mirrors the Chewie controller's
    // flag, but as Flutter state so the layout (full-bleed, no AppBar) rebuilds.
    final fullscreen = useState(false);
    // Stable key so the player element — and its underlying <video> platform
    // view — is preserved across rebuilds (e.g. when the AppBar appears /
    // disappears on fullscreen toggle), instead of being torn down + reloaded.
    final playerKey = useMemoized(() => GlobalKey(), const []);

    // Browsers reject play() until a user gesture has occurred in the document.
    // The latch is set when the user taps a library card to open the player, so
    // a true value means a gesture happened and autoplay is allowed. On a direct
    // page load / reload straight onto /watch/:hash the latch is false (it lives
    // only in memory) — autoplay would be rejected, so start paused and let the
    // user press play.
    final autoPlay = ref.read(userInitiatedPlaybackProvider);

    useEffect(() {
      var cancelled = false;
      // Cancels the in-flight backend calls when the player reloads (hash change
      // / navigation away), instead of merely discarding their results.
      final cancelToken = CancelToken();
      VideoPlayerController? vc;
      ChewieController? cc;
      StreamSubscription<void>? tracksSub;
      StreamSubscription<String?>? cuesSub;

      DebugLog.log('PLAYER', 'open hash=$hash file=$fileIndex autoPlay=$autoPlay');

      Future(() async {
        try {
          // In-app playback goes through live HLS, which exists only once the
          // file is finished + on S3. While still downloading, the web player
          // can't read the partial file — the user opens the VLC copy-link instead.
          final status = await ref.read(apiClientProvider).streamStatus(hash,
              fileIndex: fileIndex, cancelToken: cancelToken);
          DebugLog.log('PLAYER', 'streamStatus mode=${status.mode} url=${status.url}');
          if (status.mode != 's3') {
            if (!cancelled) downloading.value = true;
            return;
          }
          final api = ref.read(apiClientProvider);
          final url = api.hlsMasterUrl(hash, fileIndex: fileIndex);
          DebugLog.log('PLAYER', 'init HLS master $url');
          vc = VideoPlayerController.networkUrl(Uri.parse(url));
          await vc!.initialize();
          DebugLog.log('PLAYER', 'initialized size=${vc!.value.size} '
              'duration=${vc!.value.duration}');
          cc = ChewieController(
            videoPlayerController: vc!,
            autoPlay: autoPlay,
            looping: false,
            // Web: don't let Chewie push its own fullscreen route. That route
            // reparents the <video> platform view and, on exit, forces a full
            // hls.js reload + rebuffer. Instead the player stays mounted in
            // place and we drive the browser Fullscreen API + layout ourselves.
            disableFullScreenRoute: true,
            // Subtitles 30% larger than Chewie's default (18 → 23.4). Only the
            // size is overridden — colour stays inherited from the surrounding
            // DefaultTextStyle, and the box/alignment/markup defaults are kept.
            subtitleStyle: const SubtitleStyle(
              textStyle: TextStyle(fontSize: 24),
            ),
            errorBuilder: (context, errorMessage) => Padding(
              padding: const EdgeInsets.all(24),
              child: Center(
                child: SingleChildScrollView(
                  child: SelectableText(
                    'Playback error\n\n$errorMessage',
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white70),
                  ),
                ),
              ),
            ),
            onSubtitleTrackChanged: (track) {
              // playerId is the federated texture id the HLS plugin keys on —
              // the VideoPlayer widget relies on it too, despite its
              // visibleForTesting annotation.
              // ignore: invalid_use_of_visible_for_testing_member
              final id = vc!.playerId;
              // SubtitleTrack.id is the stringified hls.js track index; -1 = off.
              final order = track == null ? -1 : int.parse(track.id);
              DebugLog.log('ACTION', 'subtitle track → $order '
                  '(${track?.label ?? 'off'})');
              VideoPlayerPluginHls.instance?.setSubtitleTrack(id, order);
            },
            onAudioTrackChanged: (track) {
              // Muxed HLS: each audio track is a distinct variant, so switch by
              // reloading the master with `?a=<order>` in place (hls.js
              // loadSource), restoring the current position. Rebuffers briefly.
              // selectAudioTrack already owns activeAudioTrackId; the id is the
              // stringified backend order.
              final order = int.parse(track.id);
              // ignore: invalid_use_of_visible_for_testing_member
              final id = vc!.playerId;
              final pos = vc!.value.position.inMilliseconds / 1000.0;
              final newUrl = api.hlsMasterUrl(hash,
                  fileIndex: fileIndex, audioOrder: order);
              DebugLog.log('ACTION', 'audio track → $order (${track.label}) '
                  'reload @${pos.toStringAsFixed(1)}s $newUrl');
              VideoPlayerPluginHls.instance?.switchHlsSource(id, newUrl, pos);
            },
          );
          // Wire HLS subtitle track discovery + live cue delivery.
          final hls = VideoPlayerPluginHls.instance;
          if (hls != null) {
            // ignore: invalid_use_of_visible_for_testing_member
            final id = vc!.playerId;
            void applyTracks() {
              cc!.setSubtitleTracks([
                for (final t in hls.getSubtitleTracks(id))
                  SubtitleTrack(
                    id: t.id.toString(),
                    label: t.label ?? t.language ?? 'Track ${t.id + 1}',
                    language: t.language,
                  ),
              ]);
            }

            applyTracks();
            tracksSub =
                hls.subtitleTracksChanged(id).listen((_) => applyTracks());
            cuesSub = hls
                .subtitleCues(id)
                .listen((text) => cc!.setLiveSubtitle(text));
          }

          // Audio tracks come from the backend (the muxed manifest has no
          // hls.js audio renditions). Switching reloads the master in place.
          final tracks = await api.audioTracks(hash,
              fileIndex: fileIndex, cancelToken: cancelToken);
          DebugLog.log('PLAYER', 'audioTracks ${tracks.length}');
          if (tracks.isNotEmpty) {
            final def = tracks.firstWhere((t) => t.isDefault,
                orElse: () => tracks.first);
            cc!.setAudioTracks(
              [
                for (final t in tracks)
                  AudioTrack(
                    id: t.order.toString(),
                    label: t.label,
                    language: t.language,
                    isDefault: t.isDefault,
                  ),
              ],
              activeId: def.order.toString(),
            );
          }
          if (cancelled) {
            tracksSub?.cancel();
            cuesSub?.cancel();
            vc!.dispose();
            cc!.dispose();
            return;
          }
          video.value = vc;
          chewie.value = cc;
        } on DioException catch (e) {
          if (e.type == DioExceptionType.cancel) {
            DebugLog.log('PLAYER', 'setup cancelled (player reload)');
            return; // expected on reload — not a playback error
          }
          if (!cancelled) error.value = e;
          DebugLog.log('PLAYER', 'setup error: $e');
        } catch (e) {
          if (!cancelled) error.value = e;
          DebugLog.log('PLAYER', 'setup error: $e');
        }
      });

      return () {
        DebugLog.log('PLAYER',
            'dispose hash=$hash file=$fileIndex — cancel requests + teardown');
        cancelled = true;
        cancelToken.cancel('player reload');
        tracksSub?.cancel();
        cuesSub?.cancel();
        cc?.dispose();
        vc?.dispose();
      };
      // Re-runs on a file change too: switching episodes within one season pack
      // reuses this widget, and only the file index differs.
    }, [hash, fileIndex]);

    // Debug only: log user actions (play/pause + seeks) off the controller's
    // value stream. A position jump > ~1 s between ticks is treated as a seek
    // (normal playback advances by far less per tick). No-op when debug is off.
    useEffect(() {
      final vc = video.value;
      if (vc == null || !DebugLog.enabled) return null;
      var lastPlaying = vc.value.isPlaying;
      var lastPos = vc.value.position;
      void listener() {
        final v = vc.value;
        if (v.isPlaying != lastPlaying) {
          lastPlaying = v.isPlaying;
          DebugLog.log('ACTION',
              '${v.isPlaying ? 'play' : 'pause'} @${v.position.inMilliseconds / 1000.0}s');
        }
        final jump = (v.position - lastPos).inMilliseconds;
        if (jump.abs() > 1000) {
          DebugLog.log('ACTION', 'seek ${lastPos.inMilliseconds / 1000.0}s → '
              '${v.position.inMilliseconds / 1000.0}s');
        }
        lastPos = v.position;
      }

      vc.addListener(listener);
      return () => vc.removeListener(listener);
    }, [video.value]);

    // Sync Chewie's fullscreen state with the browser's native Fullscreen API.
    // Without this, the fullscreen button only expands the Flutter window area;
    // it doesn't trigger the OS-level browser fullscreen. We also listen for the
    // browser's fullscreenchange event so pressing Escape collapses Chewie too.
    useEffect(() {
      final cc = chewie.value;
      if (cc == null) return null;

      var lastFullScreen = cc.isFullScreen;

      void chewieListener() {
        final isFs = cc.isFullScreen;
        if (isFs == lastFullScreen) return;
        lastFullScreen = isFs;
        fullscreen.value = isFs;
        if (isFs) {
          web.document.documentElement?.requestFullscreen();
        } else {
          if (web.document.fullscreenElement != null) {
            web.document.exitFullscreen();
          }
        }
      }

      final jsHandler = ((JSAny? _) {
        if (web.document.fullscreenElement == null && cc.isFullScreen) {
          cc.exitFullScreen();
        }
      }).toJS;

      cc.addListener(chewieListener);
      web.document.addEventListener('fullscreenchange', jsHandler);

      return () {
        cc.removeListener(chewieListener);
        web.document.removeEventListener('fullscreenchange', jsHandler);
      };
    }, [chewie.value]);

    final library = ref.watch(libraryProvider);
    // The episode's own name when one was picked; otherwise the torrent's.
    final heading = title ??
        library.asData?.value
            .firstWhere(
              (t) => t.hashString.toLowerCase() == hash.toLowerCase(),
              orElse: () => const TorrentState(hashString: '', name: ''),
            )
            .name ??
        '';

    Widget body() {
      if (downloading.value) {
        return const Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'Still downloading.\n\n'
            'In-app playback streams via HLS, which is available once the file '
            'has finished and landed on S3. While downloading, copy the stream '
            'link from the library and open it in VLC.',
            textAlign: TextAlign.center,
          ),
        );
      }
      if (error.value != null) {
        return Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            'Could not play this file.\n\n'
            'The in-app player streams live HLS (HEVC video copied as-is, Dolby '
            'audio transcoded to AAC for the browser). If this persists the file '
            'may lack a seekable index.\n\n${error.value}',
            textAlign: TextAlign.center,
          ),
        );
      }
      if (chewie.value == null) return const CircularProgressIndicator();
      final ratio = video.value!.value.aspectRatio;
      return AspectRatio(
        aspectRatio: ratio == 0 ? 16 / 9 : ratio,
        // The GlobalKey keeps this Chewie (and its <video> platform view)
        // alive across the AppBar show/hide on fullscreen toggle.
        child: Chewie(key: playerKey, controller: chewie.value!),
      );
    }

    return Scaffold(
      // Hide the chrome in fullscreen so the video fills the viewport. The
      // player widget itself is preserved via [playerKey], so this is a pure
      // layout change — no teardown, no reload.
      appBar: fullscreen.value
          ? null
          : AppBar(
              title: Text(heading.isEmpty ? 'Watch' : heading),
              actions: [
                if (chewie.value != null)
                  CastButton(
                    hash: hash,
                    fileIndex: fileIndex,
                    title: heading.isEmpty ? 'Watch' : heading,
                  ),
              ],
            ),
      backgroundColor: Colors.black,
      body: Center(child: body()),
    );
  }
}
