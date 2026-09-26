import 'package:cineseed_shared/cineseed_shared.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../core/providers.dart';
import '../../core/theme.dart';
import '../search/format_helpers.dart';
import 'cast_button.dart';
import 'player_screen.dart';
import 'stream_actions.dart';

/// Entry point for `/watch/:hash`: decides whether there is anything to choose.
///
/// A single-video torrent goes straight into the player, exactly as before —
/// no extra tap, no extra screen. A multi-file torrent (a season pack) shows
/// its files first, because the user has to say WHICH episode to watch before
/// anything can play; picking one pushes `/watch/:hash/:index`.
///
/// This is also reachable while the torrent is still downloading — that is when
/// the per-file view matters most, since each episode has its own progress and
/// its own VLC link.
class WatchScreen extends ConsumerWidget {
  const WatchScreen({super.key, required this.hash});

  final String hash;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final files = ref.watch(torrentFilesProvider(hash));

    return files.when(
      loading: () =>
          const _Shell(title: 'Watch', child: CircularProgressIndicator()),
      error: (e, _) => _Shell(
        title: 'Watch',
        child: Text(
          'Could not read this torrent\'s files.\n\n$e',
          textAlign: TextAlign.center,
        ),
      ),
      data: (t) {
        if (t.files.isEmpty) {
          return const _Shell(
            title: 'Watch',
            child: Text('This torrent has no video files.'),
          );
        }
        // One video → nothing to pick. Rendered in place rather than
        // redirected, so the URL stays /watch/:hash (deep links keep working)
        // and there's no flash of a one-row list. fileIndex stays null: a bare
        // hash already means "the torrent's only video".
        if (t.isSingleFile) return PlayerScreen(hash: hash);
        return _FilePicker(hash: hash, torrent: t);
      },
    );
  }
}

/// Plain scaffold for the states that have no player and no list yet. Keeps the
/// AppBar (and therefore the back arrow to the library) in every state.
class _Shell extends StatelessWidget {
  const _Shell({required this.title, required this.child});
  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: SelectableText(title, maxLines: 1)),
    backgroundColor: CineseedColors.background,
    body: Center(
      child: Padding(padding: const EdgeInsets.all(24), child: child),
    ),
  );
}

class _FilePicker extends StatelessWidget {
  const _FilePicker({required this.hash, required this.torrent});

  final String hash;
  final TorrentFiles torrent;

  @override
  Widget build(BuildContext context) {
    final ready = torrent.files.where((f) => f.onS3).length;
    final total = torrent.files.length;

    return Scaffold(
      backgroundColor: CineseedColors.background,
      appBar: AppBar(title: SelectableText(torrent.name, maxLines: 1)),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Row(
              children: [
                Icon(
                  ready == total
                      ? Icons.check_circle_outline_rounded
                      : Icons.hourglass_bottom_rounded,
                  size: 15,
                  color: CineseedColors.creamMuted,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    ready == total
                        ? '$total files · all ready to stream'
                        : '$ready of $total ready to stream  ·  '
                              '${(torrent.percentDone * 100).toStringAsFixed(1)} % downloaded',
                    style: const TextStyle(
                      fontSize: 12,
                      color: CineseedColors.creamMuted,
                    ),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 16),
              itemCount: torrent.files.length,
              itemBuilder: (context, i) =>
                  _FileTile(hash: hash, file: torrent.files[i]),
            ),
          ),
        ],
      ),
    );
  }
}

class _FileTile extends ConsumerWidget {
  const _FileTile({required this.hash, required this.file});

  final String hash;
  final TorrentFileInfo file;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Same gates as the library, one file down: in-app playback, Cast and
    // download need this file on S3; the VLC link works from the first bytes,
    // because sequential download fills each file front-to-back.
    //
    // "Downloaded" is its own state, distinct from "ready": the files of a
    // season pack go up to S3 one at a time, so an episode can sit fully
    // downloaded but not yet uploaded — saying "while downloading" there would
    // misreport which half of the pipeline it is waiting on.
    final downloaded = file.percentDone >= 1.0;
    final status = file.onS3
        ? 'Ready to stream  ·  ${fmtBytes(file.length)}'
        : downloaded
        ? 'Downloaded  ·  not on S3 yet'
        : file.hasBytes
        ? '${(file.percentDone * 100).toStringAsFixed(1)} %  ·  '
              'playable in VLC while downloading'
        : 'Waiting  ·  ${fmtBytes(file.length)}';

    void open() {
      // Marks the user gesture that lets the player autoplay. The episode name
      // rides along as `extra` so the player's AppBar names the episode rather
      // than the pack; it doesn't survive a reload, where the title falls back
      // to the torrent name.
      ref.read(userInitiatedPlaybackProvider.notifier).mark();
      context.push('/watch/$hash/${file.index}', extra: file.displayName);
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
      child: Card(
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: file.onS3 ? open : null,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
            child: Row(
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: file.onS3
                        ? CineseedColors.primaryBright
                        : CineseedColors.outline,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        file.displayName,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                          color: CineseedColors.cream,
                        ),
                      ),
                      const SizedBox(height: 8),
                      // Only while the download itself is in flight — a full
                      // bar next to "Downloaded" would say nothing.
                      if (!file.onS3 && !downloaded) ...[
                        ClipRRect(
                          borderRadius: BorderRadius.circular(99),
                          child: LinearProgressIndicator(
                            value: file.percentDone,
                            minHeight: 2,
                            backgroundColor: CineseedColors.outline.withValues(
                              alpha: 0.4,
                            ),
                            valueColor: const AlwaysStoppedAnimation(
                              CineseedColors.creamMuted,
                            ),
                          ),
                        ),
                        const SizedBox(height: 6),
                      ],
                      Text(
                        status,
                        style: const TextStyle(
                          fontSize: 11.5,
                          color: CineseedColors.creamMuted,
                          letterSpacing: 0.2,
                        ),
                      ),
                    ],
                  ),
                ),
                if (file.hasBytes) ...[
                  const SizedBox(width: 8),
                  if (file.onS3)
                    CastButton(
                      hash: hash,
                      fileIndex: file.index,
                      title: file.displayName,
                      color: CineseedColors.creamMuted,
                    ),
                  Tooltip(
                    message:
                        'Copy stream URL — then in VLC: '
                        '⌘N (Open Network), paste, Open',
                    child: IconButton(
                      icon: const Icon(Icons.content_copy_rounded, size: 18),
                      color: CineseedColors.creamMuted,
                      onPressed: () => copyStreamUrl(
                        context,
                        ref,
                        hash,
                        fileIndex: file.index,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: file.onS3
                        ? 'Download'
                        : 'Available once this file is on S3',
                    icon: const Icon(Icons.download_rounded, size: 20),
                    color: CineseedColors.creamMuted,
                    onPressed: file.onS3
                        ? () => downloadFile(
                            context,
                            ref,
                            hash,
                            fileIndex: file.index,
                          )
                        : null,
                  ),
                  IconButton(
                    tooltip: file.onS3
                        ? 'Play in browser'
                        : 'Available once this file is on S3 — '
                              'use the copy button for VLC',
                    icon: const Icon(Icons.play_arrow_rounded, size: 24),
                    color: file.onS3
                        ? CineseedColors.cream
                        : CineseedColors.creamMuted.withValues(alpha: 0.4),
                    onPressed: file.onS3 ? open : null,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
