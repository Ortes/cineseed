import 'package:cineseed_shared/cineseed_shared.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/providers.dart';
import 'release_row.dart';

/// Search a movie → list of *films* (one card per TMDB id). Clicking a film
/// opens [FilmScreen] with every release for that film. Releases without a
/// TMDB id are shown as a flat list below the grid.
class SearchScreen extends StatelessWidget {
  const SearchScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Search')),
      body: const SearchView(),
    );
  }
}

/// Embeddable search body — used standalone in [SearchScreen] and as a tab
/// inside the library screen.
class SearchView extends HookConsumerWidget {
  const SearchView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    useAutomaticKeepAlive(); // survive TabBarView switches (keeps the query)
    final controller = useTextEditingController();

    void doSearch() =>
        ref.read(searchProvider.notifier).search(controller.text.trim());

    final results = ref.watch(searchProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SearchBar(controller: controller, onSubmit: doSearch),
        results.maybeWhen(
          data: (list) => _ResultsTotals(list: list),
          orElse: () => const SizedBox.shrink(),
        ),
        const SizedBox(height: 8),
        Expanded(
          child: results.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (e, _) => Center(child: Text('Error: $e')),
            data: (list) => _FilmsList(releases: list),
          ),
        ),
      ],
    );
  }
}

class _SearchBar extends StatelessWidget {
  const _SearchBar({required this.controller, required this.onSubmit});

  final TextEditingController controller;
  final VoidCallback onSubmit;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: TextField(
        controller: controller,
        autofocus: true,
        decoration: InputDecoration(
          hintText: 'Search a movie…',
          prefixIcon: const Icon(Icons.search),
          border: const OutlineInputBorder(),
          suffixIcon: ValueListenableBuilder<TextEditingValue>(
            valueListenable: controller,
            builder: (_, v, _) => v.text.isEmpty
                ? const SizedBox.shrink()
                : IconButton(
                    icon: const Icon(Icons.clear),
                    onPressed: () => controller.clear(),
                  ),
          ),
        ),
        onSubmitted: (_) => onSubmit(),
      ),
    );
  }
}

class _ResultsTotals extends StatelessWidget {
  const _ResultsTotals({required this.list});
  final List<TorrentResult> list;

  @override
  Widget build(BuildContext context) {
    if (list.isEmpty) return const SizedBox.shrink();
    // Count distinct titles the same way [_FilmsList] groups them: by
    // (mediaType, tmdbId), so a movie and a TV show sharing an id count as two.
    final titleCount = list
        .where(
          (r) =>
              r.tmdbId != null &&
              (r.mediaType == MediaType.movie || r.mediaType == MediaType.tv),
        )
        .map((r) => (r.mediaType, r.tmdbId))
        .toSet()
        .length;
    final style = Theme.of(context).textTheme.bodyMedium?.copyWith(
      color: Theme.of(context).colorScheme.onSurfaceVariant,
    );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          Text('${list.length} torrents', style: style),
          const SizedBox(width: 16),
          Text('$titleCount titles', style: style),
        ],
      ),
    );
  }
}

/// Groups releases by `tmdbId` and renders a poster grid. Releases without a
/// TMDB id are listed as rows under the grid (no card, just file rows).
class _FilmsList extends ConsumerWidget {
  const _FilmsList({required this.releases});
  final List<TorrentResult> releases;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (releases.isEmpty) {
      return const Center(
        child: Text('No results. Type a query and hit Enter.'),
      );
    }

    // Bucket by (mediaType, tmdbId). Keying on both keeps a TV show and a
    // movie that happen to share a TMDB id in separate groups. Only movie/TV
    // titles are grouped into poster cells; everything else (and untagged
    // releases) drops to the orphans list.
    final films = <(MediaType, int), List<TorrentResult>>{};
    final orphans = <TorrentResult>[];
    for (final r in releases) {
      final id = r.tmdbId;
      if (id != null &&
          (r.mediaType == MediaType.movie || r.mediaType == MediaType.tv)) {
        films.putIfAbsent((r.mediaType, id), () => []).add(r);
      } else {
        orphans.add(r);
      }
    }

    // Order films by best (max) seeders desc, then by # of releases desc.
    final entries = films.entries.toList()
      ..sort((a, b) {
        final aMax = a.value.map((r) => r.seeders).fold<int>(0, _max);
        final bMax = b.value.map((r) => r.seeders).fold<int>(0, _max);
        final c = bMax.compareTo(aMax);
        return c != 0 ? c : b.value.length.compareTo(a.value.length);
      });

    // Orphans get seeder-sorted so the most-available appear first.
    final orphansSorted = [...orphans]
      ..sort((a, b) => b.seeders.compareTo(a.seeders));

    return CustomScrollView(
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          sliver: SliverGrid(
            gridDelegate: filmGridDelegate,
            delegate: SliverChildBuilderDelegate((context, i) {
              final e = entries[i];
              return FilmGridCell(
                mediaType: e.key.$1,
                tmdbId: e.key.$2,
                releases: e.value,
              );
            }, childCount: entries.length),
          ),
        ),
        if (orphansSorted.isNotEmpty)
          SliverToBoxAdapter(child: _OrphansSection(releases: orphansSorted)),
      ],
    );
  }

  static int _max(int a, int b) => a > b ? a : b;
}

const _cellWidth = 180.0;

/// Grid of [FilmGridCell]s. ~180 px cells. Poster (2:3) = 180×270. Below:
/// title + year + chip row (quality / languages). 180/0.48 ≈ 375 total →
/// ~105 px for the text block. Keeps a 4K/HQ + VF/MULTI/VOSTFR chip row.
const filmGridDelegate = SliverGridDelegateWithMaxCrossAxisExtent(
  maxCrossAxisExtent: _cellWidth,
  mainAxisSpacing: 18,
  crossAxisSpacing: 14,
  childAspectRatio: 0.48,
);

/// One poster cell in a film grid. Poster image on top (TMDB), title, year,
/// rating and a chip row (quality + audio/subs languages) underneath.
class FilmGridCell extends HookConsumerWidget {
  const FilmGridCell({
    super.key,
    required this.mediaType,
    required this.tmdbId,
    required this.releases,
    this.movie,
    this.allocineId,
    this.showReleaseDate = false,
  });
  final MediaType mediaType;
  final int tmdbId;
  final List<TorrentResult> releases;

  /// TMDB metadata the caller already has; fetched by [tmdbId] when null.
  final TmdbMovie? movie;

  /// Links the poster to the film's AlloCiné page; to an AlloCiné search when
  /// null.
  final String? allocineId;

  /// The full release date under the title (`12 Sep 2026`), not just the year.
  final bool showReleaseDate;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hover = useState(false);
    final theme = Theme.of(context);
    final movie =
        this.movie ??
        ref.watch(tmdbTitleProvider((type: mediaType, id: tmdbId))).value;
    final rating = movie?.rating;

    // Fall back to the parsed release title until TMDB loads (or if it 404s).
    final canonical = ([
      ...releases,
    ]..sort((a, b) => b.seeders.compareTo(a.seeders))).first;
    final parsed = ReleaseTags.cleanTitle(canonical.title);
    final title = movie?.title ?? parsed.name;
    final year = showReleaseDate && movie?.releaseDate != null
        ? _longDate(movie!.releaseDate!)
        : movie?.year ?? parsed.year;
    final poster = _resizePoster(movie?.posterUrl, 'w342');

    // Parsed once per cell, not on every hover repaint of a long grid.
    final (qualities, langs) = useMemoized(
      () => (_qualityTags(releases), _langTags(releases)),
      [releases],
    );

    const radius = 12.0;
    return MouseRegion(
      onEnter: (_) => hover.value = true,
      onExit: (_) => hover.value = false,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeOut,
        transform: Matrix4.identity()
          ..scaleByDouble(
            hover.value ? 1.025 : 1.0,
            hover.value ? 1.025 : 1.0,
            1.0,
            1.0,
          ),
        transformAlignment: Alignment.center,
        child: Material(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(radius),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: () => context.push('/film/${mediaType.name}/$tmdbId'),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                AspectRatio(
                  aspectRatio: 2 / 3,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(radius),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(
                            alpha: hover.value ? 0.45 : 0.25,
                          ),
                          blurRadius: hover.value ? 14 : 8,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(radius),
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          if (poster != null)
                            Image.network(
                              poster,
                              fit: BoxFit.cover,
                              // Decoded at the cell's size, not the file's:
                              // keeps a long grid's image cache from churning.
                              cacheWidth:
                                  (_cellWidth *
                                          MediaQuery.devicePixelRatioOf(
                                            context,
                                          ))
                                      .ceil(),
                              errorBuilder: (_, _, _) =>
                                  _PosterPlaceholder(title: title),
                            )
                          else
                            _PosterPlaceholder(title: title),
                          // Releases count badge — top-right.
                          Positioned(
                            top: 8,
                            right: 8,
                            child: _Badge(
                              icon: Icons.layers_outlined,
                              label: '${releases.length}',
                            ),
                          ),
                          Positioned(
                            left: 8,
                            bottom: 8,
                            child: Tooltip(
                              message: allocineId != null
                                  ? 'Open on AlloCiné'
                                  : 'Search on AlloCiné',
                              child: InkWell(
                                borderRadius: BorderRadius.circular(999),
                                onTap: () => launchUrl(
                                  _allocineUrl(allocineId, movie, title),
                                  webOnlyWindowName: '_blank',
                                ),
                                child: const _Badge(
                                  icon: Icons.open_in_new_rounded,
                                  label: 'AlloCiné',
                                ),
                              ),
                            ),
                          ),
                          // TV shows get a marker so they're not mistaken for
                          // films (they render through the same poster cell).
                          if (mediaType == MediaType.tv)
                            const Positioned(
                              top: 8,
                              left: 8,
                              child: _Badge(
                                icon: Icons.live_tv,
                                label: 'TV Show',
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 2),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                          height: 1.15,
                        ),
                      ),
                      if (year != null || rating != null)
                        Text.rich(
                          TextSpan(
                            children: [
                              if (year != null) TextSpan(text: '$year'),
                              if (year != null && rating != null)
                                const TextSpan(text: '  '),
                              if (rating != null) ...[
                                // An icon: the web font has no ★ glyph.
                                const WidgetSpan(
                                  alignment: PlaceholderAlignment.middle,
                                  child: Icon(
                                    Icons.star_rounded,
                                    size: 14,
                                    color: Colors.amber,
                                  ),
                                ),
                                TextSpan(
                                  text: ' ${rating.toStringAsFixed(1)}',
                                  style: const TextStyle(color: Colors.amber),
                                ),
                                TextSpan(text: ' (${movie!.voteCount})'),
                              ],
                            ],
                          ),
                          maxLines: 1,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                            height: 1.15,
                          ),
                        ),
                      if (qualities.isNotEmpty || langs.isNotEmpty) ...[
                        const SizedBox(height: 6),
                        Wrap(
                          spacing: 4,
                          runSpacing: 4,
                          children: [
                            for (final q in qualities)
                              _CellChip(label: q, accent: true),
                            for (final l in langs) _CellChip(label: l),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Quality tags across all releases of a film. 2160p → "4K", 1080p → "HQ".
/// Lower resolutions are intentionally hidden to keep the cell compact.
Set<String> _qualityTags(List<TorrentResult> rs) {
  final out = <String>{};
  for (final r in rs) {
    final res = ReleaseTags.parse(r.title).resolution;
    if (res == '2160p') {
      out.add('4K');
    } else if (res == '1080p') {
      out.add('HQ');
    }
  }
  return out;
}

/// Language tags across all releases, simplified to a short ordered list:
/// `4K/HQ` chips first (handled separately), then `MULTI`, `VF`, `VOSTFR`.
List<String> _langTags(List<TorrentResult> rs) {
  final found = <String>{};
  for (final r in rs) {
    final lang = ReleaseTags.parse(r.title).language;
    if (lang == null) continue;
    final upper = lang.toUpperCase();
    if (upper.startsWith('MULTI')) {
      found.add('MULTI');
    } else if (upper == 'VOSTFR') {
      found.add('VOSTFR');
    } else if (const {
      'VFF',
      'VFI',
      'VFQ',
      'VF2',
      'VF',
      'TRUEFRENCH',
    }.contains(upper)) {
      found.add('VF');
    } else {
      found.add(upper);
    }
  }
  // Stable, readable order.
  const order = ['MULTI', 'VF', 'VOSTFR'];
  final ordered =
      [
        for (final k in order)
          if (found.remove(k)) k,
        ...found, // any unexpected leftovers, sorted alphabetically below
      ]..sort((a, b) {
        final ai = order.indexOf(a);
        final bi = order.indexOf(b);
        if (ai == -1 && bi == -1) return a.compareTo(b);
        if (ai == -1) return 1;
        if (bi == -1) return -1;
        return ai.compareTo(bi);
      });
  return ordered;
}

const _months = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', //
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];

/// `2026-09-12` → `12 Sep 2026`; [iso] unchanged when it isn't a date.
String _longDate(String iso) {
  final d = DateTime.tryParse(iso);
  return d == null ? iso : '${d.day} ${_months[d.month - 1]} ${d.year}';
}

/// The film's AlloCiné page when its id is known, else an AlloCiné search:
/// by original title when it's in Latin script, since TMDB's title is the
/// English one and AlloCiné knows the French and original ones.
Uri _allocineUrl(String? allocineId, TmdbMovie? movie, String title) {
  if (allocineId != null) {
    return Uri.parse(
      'https://www.allocine.fr/film/fichefilm_gen_cfilm=$allocineId.html',
    );
  }
  final original = movie?.originalTitle;
  final latin =
      original != null && RegExp(r'^[\u0000-\u024F]*$').hasMatch(original);
  return Uri.https('www.allocine.fr', '/rechercher/', {
    'q': latin ? original : title,
  });
}

/// Swap the TMDB image-CDN size segment (`/w500/` → `/w342/`, etc.). Safe
/// because every URL we build is `https://image.tmdb.org/t/p/wNNN/<file>`.
String? _resizePoster(String? url, String size) {
  if (url == null) return null;
  return url.replaceFirst(RegExp(r'/w\d+/'), '/$size/');
}

class _PosterPlaceholder extends StatelessWidget {
  const _PosterPlaceholder({required this.title});
  final String title;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            theme.colorScheme.surfaceContainerHigh,
            theme.colorScheme.surfaceContainerHighest,
          ],
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Icon(
              Icons.movie_creation_outlined,
              size: 28,
              color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
            ),
            const SizedBox(height: 6),
            Text(
              title,
              textAlign: TextAlign.center,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({required this.icon, required this.label});
  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final bg = Colors.black.withValues(alpha: 0.6);
    const fg = Colors.white;
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: fg),
          const SizedBox(width: 4),
          Text(
            label,
            style: theme.textTheme.labelSmall?.copyWith(
              color: fg,
              fontWeight: FontWeight.w600,
              height: 1.0,
            ),
          ),
        ],
      ),
    );
  }
}

/// Small pill chip used under each cell's title (quality + language).
class _CellChip extends StatelessWidget {
  const _CellChip({required this.label, this.accent = false});
  final String label;
  final bool accent;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bg = accent
        ? theme.colorScheme.primary.withValues(alpha: 0.16)
        : theme.colorScheme.surfaceContainerHighest;
    final fg = accent
        ? theme.colorScheme.primary
        : theme.colorScheme.onSurfaceVariant;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label,
        style: theme.textTheme.labelSmall?.copyWith(
          color: fg,
          fontWeight: FontWeight.w600,
          height: 1.0,
        ),
      ),
    );
  }
}

/// Untagged releases (no TMDB id matched) shown as a flat list under the
/// grid. Each row is the standard [ReleaseRow] with an Add action that posts
/// the infoHash to the backend.
class _OrphansSection extends ConsumerWidget {
  const _OrphansSection({required this.releases});
  final List<TorrentResult> releases;

  Future<void> _add(BuildContext context, WidgetRef ref, String hash) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref.read(apiClientProvider).addTorrent(hash);
      ref.invalidate(libraryProvider);
      messenger.showSnackBar(const SnackBar(content: Text('Added to library')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Failed: $e')));
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
          child: Text(
            '${releases.length} untagged release${releases.length > 1 ? 's' : ''} '
            '(no TMDB id)',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        const Divider(height: 1),
        for (final r in releases) ...[
          ReleaseRow(
            release: r,
            dense: true,
            onAdd: () => _add(context, ref, r.infoHash),
          ),
          const Divider(height: 1),
        ],
      ],
    );
  }
}
