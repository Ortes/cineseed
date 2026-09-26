import 'dart:io';

import 'package:cineseed_backend/cineseed_backend.dart';

Future<void> main() async {
  // Local dev: read repo-root .env if present. Process env wins, so the
  // container's env_file is unaffected.
  final env = loadDotenv();
  final config = Config.fromEnv(env);
  final server = await startServer(config);
  print(
    'Cineseed backend listening on '
    'http://${server.http.address.host}:${server.http.port}',
  );

  // Graceful shutdown on SIGTERM (docker stop) / SIGINT (Ctrl-C).
  Future<void> shutdown(ProcessSignal _) async {
    await server.close();
    exit(0);
  }

  ProcessSignal.sigterm.watch().listen(shutdown);
  ProcessSignal.sigint.watch().listen(shutdown);
}
