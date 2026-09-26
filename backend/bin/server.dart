import 'package:cineseed_backend/config.dart';
import 'package:cineseed_backend/dotenv_loader.dart';
import 'package:cineseed_backend/server.dart';

Future<void> main() async {
  // Local dev: read repo-root .env if present. Process env wins, so the
  // server's systemd EnvironmentFile is unaffected.
  final env = loadDotenv();
  final config = Config.fromEnv(env);
  final server = await startServer(config);
  print(
    'Cineseed backend listening on http://${server.address.host}:${server.port}',
  );
}
