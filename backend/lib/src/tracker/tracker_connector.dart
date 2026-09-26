import 'package:cineseed_shared/cineseed_shared.dart';

/// Abstract tracker. [TorznabTracker] is the built-in implementation; any
/// other source can implement this without touching the rest of the app.
abstract interface class TrackerConnector {
  /// Full-text search → list of results carrying the `infoHash`.
  Future<List<TorrentResult>> search(String query, {String? type});

  /// The [count] most recently uploaded movie releases, newest first.
  Future<List<TorrentResult>> latestMovies(int count);

  /// Fetch the raw `.torrent` bytes for an infoHash (Torznab `t=get`).
  Future<List<int>> fetchTorrent(String infoHash);
}
