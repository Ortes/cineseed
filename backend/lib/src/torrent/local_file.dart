import 'dart:io';

import 'torrent_client.dart';

/// Every path a torrent's file may have on the local download disk, in lookup
/// order: Transmission's per-torrent download dir ([fallbackDir] when it
/// reports none), then [incompleteDir] if configured. While downloading,
/// Transmission (rename-partial-files=true) names the file `<name>.part`; it
/// is renamed to `<name>` on completion.
List<String> localPathsOf(
  TorrentStreamInfo info,
  TorrentFile tf, {
  required String fallbackDir,
  String incompleteDir = '',
}) {
  final dir = info.downloadDir.isNotEmpty ? info.downloadDir : fallbackDir;
  return [
    for (final base in [
      '$dir/${tf.name}',
      if (incompleteDir.isNotEmpty) '$incompleteDir/${tf.name}',
    ]) ...[base, '$base.part'],
  ];
}

/// Where a torrent's file sits on the local download disk, or null if it isn't
/// there (yet). See [localPathsOf].
File? localFileOf(
  TorrentStreamInfo info,
  TorrentFile tf, {
  required String fallbackDir,
  String incompleteDir = '',
}) {
  for (final path in localPathsOf(
    info,
    tf,
    fallbackDir: fallbackDir,
    incompleteDir: incompleteDir,
  )) {
    final f = File(path);
    if (f.existsSync()) return f;
  }
  return null;
}
