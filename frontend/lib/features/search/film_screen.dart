import 'package:cineseed_shared/cineseed_shared.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:go_router/go_router.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../core/providers.dart';
import 'format_helpers.dart';
import 'release_row.dart';
import 'search_sort.dart';

/// Detail page for one film: lists every release in the current search whose
/// `tmdbId` matches. Pulled from the live `searchProvider` so we don't need to
/// re-issue the query.
class FilmScreen extends HookConsumerWidget {
  const FilmScreen({
    super.key,
    required this.mediaType,
    required this.tmdbId,
  });

  final MediaType mediaType;
  final int tmdbId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sortKey = useState(SortKey.seeders);
    final sortDesc = useState(true);

    void toggleSort(SortKey key) {
      if (sortKey.value == key) {
        sortDesc.value = !sortDesc.value;
      } else {
        sortKey.value = key;
        sortDesc.value = key != SortKey.name;
      }
    }

    final search = ref.watch(searchProvider);
    final releases = search.maybeWhen(
      data: (list) => list
          .where((r) => r.tmdbId == tmdbId && r.mediaType == mediaType)
          .toList(),
      orElse: () => const <TorrentResult>[],
    );
    final movie =
        ref.watch(tmdbTitleProvider((type: mediaType, id: tmdbId))).value;

    final clean = releases.isEmpty
        ? (name: 'Film #$tmdbId', year: null)
        : ReleaseTags.cleanTitle(_canonicalTitle(releases));
    final displayTitle = movie?.title ?? clean.name;
    final displayYear = movie?.year ?? clean.year;

    Future<void> add(String infoHash) async {
      final messenger = ScaffoldMessenger.of(context);
      final router = GoRouter.of(context);
      try {
        await ref.read(apiClientProvider).addTorrent(infoHash);
        ref.invalidate(libraryProvider);
        messenger.showSnackBar(const SnackBar(content: Text('Added to library')));
        router.go('/');
      } catch (e) {
        messenger.showSnackBar(SnackBar(content: Text('Failed: $e')));
      }
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(
          displayYear != null ? '$displayTitle ($displayYear)' : displayTitle,
        ),
      ),
      body: releases.isEmpty
          ? const Center(
              child: Text(
                'No releases for this film in the current search.\n'
                'Go back and search again.',
                textAlign: TextAlign.center,
              ),
            )
          : Column(
              children: [
                _FilmHeader(releases: releases, movie: movie),
                ColumnHeader(
                  sortKey: sortKey.value,
                  sortDesc: sortDesc.value,
                  onSort: toggleSort,
                ),
                const Divider(height: 1),
                Expanded(
                  child: ListView.separated(
                    itemCount: releases.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (_, i) {
                      final sorted =
                          sortReleases(releases, sortKey.value, sortDesc.value);
                      return ReleaseRow(
                        release: sorted[i],
                        onAdd: () => add(sorted[i].infoHash),
                      );
                    },
                  ),
                ),
              ],
            ),
    );
  }
}

String _canonicalTitle(List<TorrentResult> releases) {
  final sorted = [...releases]..sort((a, b) => b.seeders.compareTo(a.seeders));
  return sorted.first.title;
}

class _FilmHeader extends StatelessWidget {
  const _FilmHeader({required this.releases, this.movie});
  final List<TorrentResult> releases;
  final TmdbMovie? movie;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final totalSize = releases.fold<int>(0, (s, r) => s + r.size);
    final resolutions = <String>{};
    for (final r in releases) {
      final res = ReleaseTags.parse(r.title).resolution;
      if (res != null) resolutions.add(res);
    }
    final sortedRes = resolutions.toList()
      ..sort((a, b) => b.compareTo(a)); // 2160p first
    final poster = movie?.posterUrl;
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (poster != null) ...[
            DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(10),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.25),
                    blurRadius: 8,
                    offset: const Offset(0, 3),
                  ),
                ],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: Image.network(
                  poster,
                  width: 100,
                  height: 150,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => const SizedBox(width: 100, height: 150),
                ),
              ),
            ),
            const SizedBox(width: 16),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (movie?.overview != null && movie!.overview!.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(
                      movie!.overview!,
                      maxLines: 4,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                Wrap(
                  spacing: 12,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    for (final r in sortedRes)
                      Chip(
                        label: Text(r),
                        visualDensity: VisualDensity.compact,
                      ),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.storage, size: 16),
                        const SizedBox(width: 4),
                        Text(fmtSize(totalSize)),
                      ],
                    ),
                    Text(
                      '${releases.length} releases',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
