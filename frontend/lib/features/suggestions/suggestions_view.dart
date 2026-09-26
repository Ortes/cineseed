import 'package:cineseed_shared/cineseed_shared.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../core/providers.dart';
import '../search/search_screen.dart';

/// Library tab: the films among the tracker's latest 100 movie releases, best
/// TMDB rating first (the backend sorts them).
class SuggestionsView extends HookConsumerWidget {
  const SuggestionsView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    useAutomaticKeepAlive(); // survive TabBarView switches (keeps the scroll)
    final films = ref.watch(suggestionsProvider);
    final theme = Theme.of(context);

    return films.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('Error: $e')),
      data: (list) => CustomScrollView(
        slivers: [
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 8, 8, 0),
            sliver: SliverToBoxAdapter(
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '${list.length} films in the latest 100 releases, '
                      'best rated first',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  films.isLoading
                      ? const Padding(
                          padding: EdgeInsets.all(12),
                          child: SizedBox.square(
                            dimension: 24,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        )
                      : IconButton(
                          tooltip: 'Refresh',
                          icon: const Icon(Icons.refresh_rounded),
                          onPressed: () => ref.invalidate(suggestionsProvider),
                        ),
                ],
              ),
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            sliver: SliverGrid(
              gridDelegate: filmGridDelegate,
              delegate: SliverChildBuilderDelegate((context, i) {
                final s = list[i];
                return FilmGridCell(
                  mediaType: MediaType.movie,
                  tmdbId: s.movie.id,
                  releases: s.releases,
                  movie: s.movie,
                );
              }, childCount: list.length),
            ),
          ),
        ],
      ),
    );
  }
}
