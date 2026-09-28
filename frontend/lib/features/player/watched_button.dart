import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../core/providers.dart';
import '../../core/theme.dart';

/// Toggles one video's watched mark ([watchedProvider]). The player sets it on
/// its own near the end; this is for marking by hand, or undoing that.
class WatchedButton extends ConsumerWidget {
  const WatchedButton({super.key, required this.id});

  /// Stream id of the video ([ApiClient.streamId]).
  final String id;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final watched = ref.watch(watchedProvider).contains(id);
    return IconButton(
      tooltip: watched ? 'Watched — tap to unmark' : 'Mark as watched',
      icon: Icon(
        watched
            ? Icons.check_circle_rounded
            : Icons.check_circle_outline_rounded,
        size: 20,
      ),
      color: watched ? CineseedColors.primaryBright : CineseedColors.creamMuted,
      onPressed: () =>
          ref.read(watchedProvider.notifier).set(id, watched: !watched),
    );
  }
}
