import 'package:cineseed_shared/cineseed_shared.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'api_client.dart';

/// Backend base URL. Defaults to a local backend for dev — override at build
/// time for the production bundle (same-origin: pass an empty string):
/// `flutter build web --dart-define=CINESEED_API_BASE=`
const apiBase = String.fromEnvironment(
  'CINESEED_API_BASE',
  defaultValue: 'http://localhost:8080',
);

final apiClientProvider = Provider<ApiClient>((ref) => ApiClient(apiBase));

/// Whether the user has tapped to open the player this page-load. Browsers
/// reject `play()` until a user gesture has occurred in the document; [mark] is
/// called from the library's play tap, so a `true` value means a gesture
/// happened and the player may autoplay. It lives only in memory, so a full page
/// reload or a direct deep-link onto /watch starts it at `false` and the player
/// stays paused until the user presses play.
final userInitiatedPlaybackProvider =
    NotifierProvider<UserInitiatedPlayback, bool>(UserInitiatedPlayback.new);

class UserInitiatedPlayback extends Notifier<bool> {
  @override
  bool build() => false;

  void mark() => state = true;
}

/// Search results, driven by [SearchController.search].
final searchProvider =
    AsyncNotifierProvider<SearchController, List<TorrentResult>>(
      SearchController.new,
    );

class SearchController extends AsyncNotifier<List<TorrentResult>> {
  @override
  Future<List<TorrentResult>> build() async => const [];

  Future<void> search(String query) async {
    if (query.isEmpty) return;
    state = const AsyncLoading();
    state = await AsyncValue.guard(
      () => ref.read(apiClientProvider).search(query),
    );
  }
}

/// Suggestions tab ([ApiClient.suggestions]): fetched once per page-load, and
/// again when the tab's refresh button invalidates it.
final suggestionsProvider = FutureProvider<List<FilmSuggestion>>(
  (ref) => ref.watch(apiClientProvider).suggestions(),
);

/// Library: polls the backend every 2 s so progress bars animate live.
final libraryProvider = StreamProvider<List<TorrentState>>((ref) async* {
  final api = ref.watch(apiClientProvider);
  while (true) {
    try {
      yield await api.listTorrents();
    } catch (_) {
      // Transient error — keep the last good value and retry.
    }
    await Future<void>.delayed(const Duration(seconds: 2));
  }
});

/// Presigned stream URL for a given torrent hash.
final streamUrlProvider = FutureProvider.family<String, String>(
  (ref, hash) => ref.watch(apiClientProvider).streamUrl(hash),
);

/// A torrent's video files, polled like the library so per-file download and
/// S3-upload progress animate live while the picker is open. Keyed by hash.
///
/// The poll STOPS once every file is downloaded and on S3, because from then on
/// no field can change again: a torrent never un-completes, and the backend's
/// S3 latches only ever go from false to true. Without this the loop would keep
/// billing a Transmission RPC every 2 s for the whole length of a film — this
/// provider outlives the picker, since the player is nested under it.
final torrentFilesProvider = StreamProvider.family<TorrentFiles, String>((
  ref,
  hash,
) async* {
  final api = ref.watch(apiClientProvider);
  while (true) {
    try {
      final files = await api.torrentFiles(hash);
      yield files;
      if (files.percentDone >= 1.0 && files.files.every((f) => f.onS3)) return;
    } catch (_) {
      // Transient error — keep the last good value and retry.
    }
    await Future<void>.delayed(const Duration(seconds: 2));
  }
});

/// TMDB metadata by media type + id. Keyed by a `(type, id)` record because
/// TMDB's movie and TV id spaces are independent — the same integer is a
/// different title in each. Returns `null` if the backend has no TMDB key, the
/// id is unknown, or the release isn't a movie/TV title.
final tmdbTitleProvider =
    FutureProvider.family<TmdbMovie?, ({MediaType type, int id})>(
      (ref, key) => ref.watch(apiClientProvider).tmdbTitle(key.type, key.id),
    );
