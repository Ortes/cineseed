import 'torrent_client.dart';

const videoExtensions = {
  '.mkv',
  '.mp4',
  '.avi',
  '.mov',
  '.m4v',
  '.webm',
  '.ts',
  '.wmv',
  '.flv',
  '.mpg',
  '.mpeg',
};

bool isVideoFile(String name) {
  final lower = name.toLowerCase();
  return videoExtensions.any(lower.endsWith);
}

/// Indices — into the torrent's own file list — of every video-extension file,
/// in torrent order, which for a season pack is episode order. Falls back to
/// every file when nothing in the torrent looks like video.
///
/// Torrent order, not size order: it is the only stable identity a client can
/// hold on to, and it is what the user recognises (E01 first, not "the biggest
/// episode first").
List<int> videoFileIndices(List<TorrentFile> files) {
  final videos = [
    for (var i = 0; i < files.length; i++)
      if (isVideoFile(files[i].name)) i,
  ];
  return videos.isNotEmpty
      ? videos
      : [for (var i = 0; i < files.length; i++) i];
}

/// The torrent's *primary* video: the largest one. What a bare-hash id serves —
/// the right answer for the single-video torrents that used to be the only case.
int primaryVideoIndex(List<TorrentFile> files) {
  final videos = videoFileIndices(files);
  videos.sort((a, b) => files[b].length.compareTo(files[a].length));
  return videos.first;
}

/// Addresses one video file inside a torrent.
///
/// A stream id is a torrent hash, optionally suffixed with `.<fileIndex>` to
/// name one file inside a multi-file torrent; a bare hash means the primary
/// (largest) video. A torrent hash is hex, so the `.` is unambiguous.
///
/// It is deliberately ONE URL path segment. The HLS media playlists reference
/// their init/segments relatively (`m/0/index.m3u8`, `12.m4s`), so an entire
/// session has to hang off a single `/api/hls/<id>/` prefix — a query parameter
/// would be dropped the moment hls.js resolved a child URL. The same id form is
/// then used by `/api/stream`, `/api/file` and `/api/download` so there is one
/// way to name a file, not two.
///
/// It doubles as the session key for the HLS session cache, the range proxy and
/// the ffmpeg producers, all of which key on an opaque token containing no `:`.
class StreamId {
  final String hash;

  /// The requested file index, or null for "the primary video".
  final int? fileIndex;

  const StreamId(this.hash, [this.fileIndex]);

  /// Parses `<hash>` or `<hash>.<index>`. Returns null when the suffix is
  /// present but not a file index — a malformed id names no file, so the caller
  /// reports that rather than guessing at one.
  static StreamId? parse(String id) {
    final dot = id.indexOf('.');
    if (dot < 0) return StreamId(id);
    final i = int.tryParse(id.substring(dot + 1));
    if (i == null || i < 0) return null;
    return StreamId(id.substring(0, dot), i);
  }

  /// Index of the file this id addresses within [files], or null when the id
  /// names a file the torrent doesn't have.
  ///
  /// An out-of-range index is rejected, not clamped: silently serving a
  /// different episode than the one asked for would look like a playback bug
  /// and hide the real error (a stale link, a torrent whose files changed).
  int? resolve(List<TorrentFile> files) {
    if (files.isEmpty) return null;
    final i = fileIndex;
    if (i == null) return primaryVideoIndex(files);
    return i < files.length ? i : null;
  }

  @override
  String toString() => fileIndex == null ? hash : '$hash.$fileIndex';
}
