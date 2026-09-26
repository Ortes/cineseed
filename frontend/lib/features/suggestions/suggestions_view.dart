import 'package:cineseed_shared/cineseed_shared.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../core/providers.dart';
import '../search/search_screen.dart';

/// Library tab: this year's films on C411, and last year's too from January
/// to March (the backend rebuilds the list daily), in the order the user
/// picks.
class SuggestionsView extends HookConsumerWidget {
  const SuggestionsView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    useAutomaticKeepAlive(); // survive TabBarView switches (keeps the order)
    final sort = useState(SuggestionSort.recommended);
    final films = ref.watch(suggestionsProvider).value;
    final sorted = useMemoized(
      () => films == null
          ? null
          : sortSuggestions(films, sort.value, DateTime.now()),
      [films, sort.value],
    );
    final theme = Theme.of(context);

    return ref
        .watch(suggestionsProvider)
        .when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => Center(child: Text('Error: $e')),
          data: (_) => CustomScrollView(
            slivers: [
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                sliver: SliverToBoxAdapter(
                  child: Wrap(
                    spacing: 16,
                    runSpacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    alignment: WrapAlignment.spaceBetween,
                    children: [
                      Text(
                        '${sorted!.length} recent films on C411',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      SegmentedButton<SuggestionSort>(
                        showSelectedIcon: false,
                        segments: const [
                          ButtonSegment(
                            value: SuggestionSort.recommended,
                            label: Text('Recommended'),
                            tooltip: 'Rating and release date together',
                          ),
                          ButtonSegment(
                            value: SuggestionSort.rating,
                            label: Text('Rating'),
                          ),
                          ButtonSegment(
                            value: SuggestionSort.releaseDate,
                            label: Text('Latest'),
                          ),
                        ],
                        selected: {sort.value},
                        onSelectionChanged: (s) => sort.value = s.single,
                      ),
                    ],
                  ),
                ),
              ),
              SliverPadding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
                sliver: SliverGrid(
                  gridDelegate: filmGridDelegate,
                  delegate: SliverChildBuilderDelegate((context, i) {
                    final s = sorted[i];
                    return FilmGridCell(
                      mediaType: MediaType.movie,
                      tmdbId: s.movie.id,
                      releases: s.releases,
                      movie: s.movie,
                      allocineId: s.allocineId,
                      showReleaseDate: true,
                    );
                  }, childCount: sorted.length),
                ),
              ),
            ],
          ),
        );
  }
}
