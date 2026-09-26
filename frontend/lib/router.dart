import 'package:cineseed_shared/cineseed_shared.dart';
import 'package:go_router/go_router.dart';

import 'features/library/library_screen.dart';
import 'features/player/player_screen.dart';
import 'features/player/watch_screen.dart';
import 'features/search/film_screen.dart';
import 'features/search/search_screen.dart';

final router = GoRouter(
  routes: [
    GoRoute(
      path: '/',
      builder: (context, state) => const LibraryScreen(),
      // The other screens are nested children of '/', so deep-linking (or
      // reloading) straight onto one resolves to the route chain
      // [LibraryScreen, child] — the library is already on the navigation stack
      // beneath it. Every sub-page therefore has a working back arrow that pops
      // to the library, with no per-screen back-button wiring, and it behaves
      // the same no matter where the page was opened from.
      routes: [
        GoRoute(
          path: 'search',
          builder: (context, state) => const SearchScreen(),
        ),
        GoRoute(
          path: 'film/:type/:tmdbId',
          builder: (context, state) {
            final id = int.parse(state.pathParameters['tmdbId']!);
            final type = MediaType.fromJson(state.pathParameters['type']);
            return FilmScreen(mediaType: type, tmdbId: id);
          },
        ),
        // A torrent: straight into the player when it holds a single video,
        // otherwise its file list (see [WatchScreen]).
        GoRoute(
          path: 'watch/:hash',
          builder: (context, state) =>
              WatchScreen(hash: state.pathParameters['hash']!),
          routes: [
            // One file inside that torrent, by its index in the torrent's file
            // list. Nested, so backing out of an episode returns to the list.
            GoRoute(
              path: ':index',
              builder: (context, state) => PlayerScreen(
                hash: state.pathParameters['hash']!,
                fileIndex: int.parse(state.pathParameters['index']!),
                title: state.extra as String?,
              ),
            ),
          ],
        ),
      ],
    ),
  ],
);
