/// Cineseed's backend as a library: start the server, optionally with your own
/// torrent client, indexer or storage in place of the defaults.
///
/// ```dart
/// final server = await startServer(Config.fromEnv(loadDotenv()),
///     client: MyTorrentClient());
/// ```
library;

export 'package:cineseed_shared/cineseed_shared.dart';

export 'src/config.dart' show Config, S3Settings;
export 'src/dotenv_loader.dart' show loadDotenv;
export 'src/server.dart' show CineseedServer, startServer;
export 'src/storage/s3_signer.dart' show S3Signer;
export 'src/torrent/torrent_client.dart';
export 'src/torrent/transmission_client.dart' show TransmissionClient;
export 'src/tracker/tmdb_client.dart' show TmdbClient;
export 'src/tracker/torznab_tracker.dart' show TorznabTracker;
export 'src/tracker/tracker_connector.dart';
