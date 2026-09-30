import 'package:cineseed_shared/cineseed_shared.dart';

/// Abstract tracker. [TorznabTracker] is the built-in implementation; any
/// other source can implement this without touching the rest of the app.
abstract interface class TrackerConnector {
  /// Full-text search → list of results carrying the `infoHash`.
  Future<List<TorrentResult>> search(String query, {String? type});

  /// Fetch the raw `.torrent` bytes for an infoHash (Torznab `t=get`).
  Future<List<int>> fetchTorrent(String infoHash);
}

/// The tracker answered, but not with results — typically an outage page
/// (C411 serves an HTML "Incident en cours" with HTTP 200). [body] is what it
/// returned, so the user can read it.
class TrackerException implements Exception {
  final String message;
  final String body;

  TrackerException(this.message, this.body);

  @override
  String toString() => 'TrackerException: $message';
}
