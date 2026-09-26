import 'dart:io';

import 'torrent_client.dart';

/// Where a torrent's file sits on the local download disk, or null if it isn't
/// there (yet). Transmission's per-torrent download dir is the primary lookup,
/// [fallbackDir] when it reports none, then [incompleteDir] if configured.
/// While downloading, Transmission (rename-partial-files=true) names the file
/// `<name>.part`; it is renamed to `<name>` on completion.
File? localFileOf(
  TorrentStreamInfo info,
  TorrentFile tf, {
  required String fallbackDir,
  String incompleteDir = '',
}) {
  File? find(String base) {
    final f = File(base);
    if (f.existsSync()) return f;
    final p = File('$base.part');
    if (p.existsSync()) return p;
    return null;
  }

  final dir = info.downloadDir.isNotEmpty ? info.downloadDir : fallbackDir;
  var file = find('$dir/${tf.name}');
  if (file == null && incompleteDir.isNotEmpty) {
    file = find('$incompleteDir/${tf.name}');
  }
  return file;
}
