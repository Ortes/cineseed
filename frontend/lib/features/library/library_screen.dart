import 'package:cineseed_shared/cineseed_shared.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:go_router/go_router.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../core/providers.dart';
import '../../core/theme.dart';
import '../player/cast_button.dart';
import '../player/stream_actions.dart';
import '../search/format_helpers.dart';
import '../search/search_screen.dart';
import '../suggestions/suggestions_view.dart';

class LibraryScreen extends StatelessWidget {
  const LibraryScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        backgroundColor: CineseedColors.background,
        appBar: AppBar(
          title: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: Image.asset(
                  'assets/icon.png',
                  width: 24,
                  height: 24,
                  fit: BoxFit.cover,
                ),
              ),
              const SizedBox(width: 10),
              const Text('Cineseed'),
            ],
          ),
          bottom: const TabBar(
            tabs: [
              Tab(text: 'Library', icon: Icon(Icons.video_library_outlined)),
              Tab(text: 'Search', icon: Icon(Icons.search_rounded)),
              Tab(text: 'Suggestions', icon: Icon(Icons.star_outline_rounded)),
            ],
          ),
        ),
        body: const TabBarView(
          children: [_LibraryTab(), SearchView(), SuggestionsView()],
        ),
      ),
    );
  }
}

class _LibraryTab extends HookConsumerWidget {
  const _LibraryTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    useAutomaticKeepAlive(); // survive TabBarView switches (keeps the filter)
    final filterController = useTextEditingController();
    final filter = useState('');
    final library = ref.watch(libraryProvider);

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: TextField(
            controller: filterController,
            decoration: InputDecoration(
              hintText: 'Filter library…',
              prefixIcon: const Icon(
                Icons.search_rounded,
                color: CineseedColors.creamMuted,
              ),
              isDense: true,
              suffixIcon: ValueListenableBuilder<TextEditingValue>(
                valueListenable: filterController,
                builder: (_, v, _) => v.text.isEmpty
                    ? const SizedBox.shrink()
                    : IconButton(
                        icon: const Icon(Icons.clear_rounded),
                        onPressed: () {
                          filterController.clear();
                          filter.value = '';
                        },
                      ),
              ),
            ),
            onChanged: (v) => filter.value = v.trim().toLowerCase(),
          ),
        ),
        Expanded(
          child: library.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (e, _) => Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  'Error: $e',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: CineseedColors.creamMuted),
                ),
              ),
            ),
            data: (torrents) {
              if (torrents.isEmpty) {
                return _EmptyState(
                  icon: Icons.movie_creation_outlined,
                  title: 'Your library is empty',
                  subtitle: 'Open Search to add your first film.',
                );
              }
              final filtered = filter.value.isEmpty
                  ? torrents
                  : torrents
                        .where(
                          (t) => t.name.toLowerCase().contains(filter.value),
                        )
                        .toList();
              if (filtered.isEmpty) {
                return const _EmptyState(
                  icon: Icons.search_off_rounded,
                  title: 'No matches',
                  subtitle: 'Try a different filter term.',
                );
              }
              // Totals cover the whole library, not the filtered view — they're
              // a seeding dashboard, not a property of the current search.
              return Column(
                children: [
                  _TotalsBar(torrents: torrents),
                  Expanded(
                    // Transmission returns torrents oldest-first (by internal id
                    // / added order). Reverse so the most recently added is on top.
                    child: ListView.builder(
                      padding: const EdgeInsets.fromLTRB(12, 4, 12, 16),
                      itemCount: filtered.length,
                      itemBuilder: (context, i) => _TorrentTile(
                        torrent: filtered[filtered.length - 1 - i],
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ],
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({
    required this.icon,
    required this.title,
    required this.subtitle,
  });
  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 40, color: CineseedColors.creamMuted),
            const SizedBox(height: 18),
            Text(
              title,
              style: const TextStyle(
                color: CineseedColors.cream,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: CineseedColors.creamMuted,
                fontSize: 13,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Library-wide seeding dashboard: live up/down rates, total data sent and the
/// aggregate ratio. Refreshes with the 2 s library poll.
class _TotalsBar extends StatelessWidget {
  const _TotalsBar({required this.torrents});
  final List<TorrentState> torrents;

  @override
  Widget build(BuildContext context) {
    var rateDown = 0, rateUp = 0, uploaded = 0, base = 0;
    for (final t in torrents) {
      rateDown += t.rateDownload;
      rateUp += t.rateUpload;
      uploaded += t.uploadedEver;
      base += t.ratioBase;
    }
    // Bytes-weighted aggregate, i.e. total sent / total fetched — not the mean
    // of the per-film ratios, which would let a tiny torrent skew the number.
    final ratio = base > 0 ? uploaded / base : null;

    return Container(
      // Full width so it lines up with the filter field and the cards — a
      // Column centres a self-sizing child, which left this floating mid-screen.
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: CineseedColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: CineseedColors.outline.withValues(alpha: 0.6),
        ),
      ),
      child: Wrap(
        spacing: 20,
        runSpacing: 8,
        children: [
          _Stat(
            icon: Icons.south_rounded,
            label: 'Download',
            value: fmtRate(rateDown),
          ),
          _Stat(
            icon: Icons.north_rounded,
            label: 'Upload',
            value: fmtRate(rateUp),
          ),
          _Stat(
            icon: Icons.cloud_upload_outlined,
            label: 'Total uploaded',
            value: fmtBytes(uploaded),
          ),
          _Stat(
            icon: Icons.swap_vert_rounded,
            label: 'Ratio',
            value: fmtRatio(ratio),
            highlight: ratio != null && ratio >= 1,
          ),
        ],
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({
    required this.icon,
    required this.label,
    required this.value,
    this.highlight = false,
  });
  final IconData icon;
  final String label;
  final String value;
  final bool highlight;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 15, color: CineseedColors.creamMuted),
        const SizedBox(width: 6),
        Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: const TextStyle(
                fontSize: 10,
                color: CineseedColors.creamMuted,
                letterSpacing: 0.4,
              ),
            ),
            Text(
              value,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: highlight
                    ? CineseedColors.primaryBright
                    : CineseedColors.cream,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// One film's transfer figures: live down/up rate, bytes sent, share ratio.
///
/// Direction is shown with Material icons, not "↑"/"↓" glyphs — the bundled
/// text font has no U+2191/U+2193 and renders them as tofu boxes.
class _TorrentMetrics extends StatelessWidget {
  const _TorrentMetrics({required this.torrent});
  final TorrentState torrent;

  @override
  Widget build(BuildContext context) {
    final t = torrent;
    final ratio = t.ratio;
    const muted = TextStyle(fontSize: 11, color: CineseedColors.creamMuted);

    return DefaultTextStyle(
      style: muted,
      child: Wrap(
        spacing: 12,
        runSpacing: 2,
        children: [
          // Down rate only while it's actually fetching — a seeding film showing
          // a permanent "0 B/s" download is noise.
          if (!t.isReady || t.rateDownload > 0)
            _Metric(icon: Icons.south_rounded, text: fmtRate(t.rateDownload)),
          _Metric(icon: Icons.north_rounded, text: fmtRate(t.rateUpload)),
          _Metric(
            icon: Icons.cloud_upload_outlined,
            text: '${fmtBytes(t.uploadedEver)} sent',
          ),
          Text(
            'ratio ${fmtRatio(ratio)}',
            style: muted.copyWith(
              fontWeight: FontWeight.w600,
              color: ratio != null && ratio >= 1
                  ? CineseedColors.primaryBright
                  : CineseedColors.creamMuted,
            ),
          ),
        ],
      ),
    );
  }
}

class _Metric extends StatelessWidget {
  const _Metric({required this.icon, required this.text});
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 12, color: CineseedColors.creamMuted),
        const SizedBox(width: 3),
        Text(text),
      ],
    );
  }
}

class _TorrentTile extends ConsumerWidget {
  const _TorrentTile({required this.torrent});
  final TorrentState torrent;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = torrent;
    // In-app playback and the VLC copy-link work as soon as any bytes have
    // landed (sequential download fills the file front-to-back; the player
    // waits for the first pieces). Cast and download need the file on S3
    // (`onS3`).
    final hasBytes = t.percentDone > 0;
    // Stranded first: such a torrent is also 100% done and not on S3, so it
    // would otherwise read as "uploading" forever — an upload that can never
    // start, let alone finish.
    final stranded = t.strandedFiles > 0;
    final finalizing = t.isReady && !t.onS3 && !stranded;
    final statusText = stranded
        ? '${t.strandedFiles} file${t.strandedFiles == 1 ? '' : 's'} missing  ·  '
              're-download to recover'
        : t.onS3
        ? 'Ready to stream'
        : finalizing
        ? 'Uploading to S3…  ${(t.uploadProgress * 100).toStringAsFixed(0)} %'
        : '${(t.percentDone * 100).toStringAsFixed(1)} %  ·  '
              '${hasBytes ? 'playable while downloading' : 'starting…'}';

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
      child: Card(
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          // Always tappable: /watch resolves to the player for a single-video
          // torrent and to the file list for a season pack, and the file list
          // is worth reaching mid-download — it is where the per-episode
          // progress and VLC links live.
          onTap: () {
            ref.read(userInitiatedPlaybackProvider.notifier).mark();
            context.push('/watch/${t.hashString}');
          },
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
            child: Row(
              children: [
                // Small status dot — only the "ready" state earns a bright
                // accent; in-progress stays muted so the list reads calmer.
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: t.onS3
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
                        t.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                          color: CineseedColors.cream,
                        ),
                      ),
                      const SizedBox(height: 8),
                      // Two-stage progress until the file is on S3. First bar:
                      // download (determinate). Once it's full, a second bar
                      // appears for the S3 upload — determinate on
                      // uploadProgress, indeterminate until the first bytes land.
                      if (!t.onS3)
                        ClipRRect(
                          borderRadius: BorderRadius.circular(99),
                          child: LinearProgressIndicator(
                            value: t.percentDone,
                            minHeight: 2,
                            backgroundColor: CineseedColors.outline.withValues(
                              alpha: 0.4,
                            ),
                            valueColor: const AlwaysStoppedAnimation(
                              CineseedColors.creamMuted,
                            ),
                          ),
                        ),
                      if (finalizing) const SizedBox(height: 4),
                      if (finalizing)
                        ClipRRect(
                          borderRadius: BorderRadius.circular(99),
                          child: LinearProgressIndicator(
                            value: t.uploadProgress > 0
                                ? t.uploadProgress
                                : null,
                            minHeight: 2,
                            backgroundColor: CineseedColors.outline.withValues(
                              alpha: 0.4,
                            ),
                            valueColor: const AlwaysStoppedAnimation(
                              CineseedColors.primaryBright,
                            ),
                          ),
                        ),
                      if (!t.onS3) const SizedBox(height: 6),
                      Text(
                        statusText,
                        style: const TextStyle(
                          fontSize: 11.5,
                          color: CineseedColors.creamMuted,
                          fontWeight: FontWeight.w400,
                          letterSpacing: 0.2,
                        ),
                      ),
                      const SizedBox(height: 4),
                      // Per-film transfer metrics, refreshed by the 2 s poll.
                      // Always rendered (a fresh add reads 0 B/s · 0 B · 0.00)
                      // so the tile height doesn't jump when seeding starts.
                      _TorrentMetrics(torrent: t),
                    ],
                  ),
                ),
                if (hasBytes) ...[
                  const SizedBox(width: 8),
                  // Cast needs the S3 object (same HLS path as in-app).
                  if (t.onS3)
                    CastButton(
                      hash: t.hashString,
                      title: t.name,
                      color: CineseedColors.creamMuted,
                    ),
                  // VLC handles MKV/HEVC/Dolby and tolerates the growing file
                  // mid-download — the one action that works before S3, so it
                  // stays available throughout. (No index-at-end pain like
                  // Chrome's <video>.)
                  Tooltip(
                    message:
                        'Copy stream URL — then in VLC: '
                        '⌘N (Open Network), paste, Open',
                    child: IconButton(
                      icon: const Icon(Icons.content_copy_rounded, size: 18),
                      color: CineseedColors.creamMuted,
                      onPressed: () =>
                          copyStreamUrl(context, ref, t.hashString),
                    ),
                  ),
                  // Download serves the presigned S3 object — disabled (greyed)
                  // until the file is actually on S3, so it can't 409.
                  IconButton(
                    tooltip: t.onS3
                        ? 'Download'
                        : finalizing
                        ? 'Available once the upload to S3 finishes'
                        : 'Available once the download finishes',
                    icon: const Icon(Icons.download_rounded, size: 20),
                    color: CineseedColors.creamMuted,
                    onPressed: t.onS3
                        ? () => downloadFile(context, ref, t.hashString)
                        : null,
                  ),
                  // In-app playback: live HLS off S3 once the file is there,
                  // else off the local copy while it downloads.
                  IconButton(
                    tooltip: stranded
                        ? 'Files missing — re-download to recover'
                        : 'Play in browser',
                    icon: const Icon(Icons.play_arrow_rounded, size: 24),
                    color: stranded
                        ? CineseedColors.creamMuted.withValues(alpha: 0.4)
                        : CineseedColors.cream,
                    onPressed: !stranded
                        ? () {
                            ref
                                .read(userInitiatedPlaybackProvider.notifier)
                                .mark();
                            context.push('/watch/${t.hashString}');
                          }
                        : null,
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
