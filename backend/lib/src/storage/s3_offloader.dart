import 'dart:async';
import 'dart:io';

import 'package:cineseed_shared/cineseed_shared.dart';
import 'package:hls_remux/hls_remux.dart';

import '../torrent/stream_id.dart';
import '../torrent/torrent_client.dart';
import 's3_signer.dart';

/// Moves finished torrents to S3: uploads every video file straight from the
/// local download disk, then points Transmission at [postUploadDir] (e.g. an
/// rclone mount of the same bucket, so it keeps seeding) and frees the local
/// copy. Absent entirely when S3 isn't configured — files then stay local.
class S3Offloader {
  S3Offloader({
    required this.client,
    required this.signer,
    required this.postUploadDir,
  });

  final TorrentClient client;
  final S3Signer signer;
  final String postUploadDir;

  // Latch of hashes confirmed on S3 (immutable once true). `_uploading`/
  // `_finalized` guard the once-per-hash upload and hand-over against
  // concurrent polls.
  final _s3Ready = <String>{};
  final _uploading = <String>{};
  final _finalized = <String>{};
  // hash → S3 upload fraction (0..1) while an upload is in flight.
  final _uploadProgress = <String, double>{};
  // hash → how many video files are on neither S3 nor disk. Freeing the local
  // copy before every file had landed used to strand the rest (fixed), and the
  // torrents it already hit can never complete: their bytes are simply gone.
  // Recording that stops [resolve] from re-attempting an upload whose source
  // does not exist — which it otherwise does on every single poll, forever.
  final _stranded = <String, int>{};
  // Individual S3 object keys confirmed present (immutable once true, same as
  // _s3Ready but per file). A season pack is polled per file by the file
  // picker and re-checked per file by [resolve]; without this each poll would
  // re-HEAD every episode that is already up.
  final _s3Files = <String>{};

  double uploadProgress(String hash) => _uploadProgress[hash] ?? 0;
  int strandedFiles(String hash) => _stranded[hash] ?? 0;

  /// Re-evaluate [hash] from scratch: re-fetching or any deliberate action on
  /// a torrent may put its files back.
  void unstrand(String hash) => _stranded.remove(hash);

  Future<bool> fileOnS3(String key) async {
    if (_s3Files.contains(key)) return true;
    if (!await signer.exists(key)) return false;
    _s3Files.add(key);
    return true;
  }

  // Once on S3 the local copy is redundant: point Transmission at the S3-backed
  // mount (so it still sees its files) and free the download disk.
  Future<void> _finalize(String hash, TorrentStreamInfo info) async {
    if (!_finalized.add(hash)) return;
    if (info.downloadDir.isEmpty || info.downloadDir == postUploadDir) return;
    final localPath = '${info.downloadDir}/${info.name}';
    try {
      await client.setLocation(hash, postUploadDir, move: false);
      final f = File(localPath);
      final d = Directory(localPath);
      if (await f.exists()) {
        await f.delete();
      } else if (await d.exists()) {
        await d.delete(recursive: true);
      }
      Log.d('s3', 'finalized $hash → $postUploadDir, freed $localPath');
    } catch (e) {
      _finalized.remove(hash);
      Log.d('s3', 'finalize $hash failed: $e');
    }
  }

  // A finished torrent stays on the local download disk (info.downloadDir) so
  // reads hit plain files, never the rclone VFS. Upload it to S3 straight from
  // there — a busy reader can't disturb this.
  //
  // EVERY video file goes up, not just the primary one: _finalize() frees the
  // torrent's whole directory, so a season pack whose other episodes were never
  // uploaded would lose them outright. Files go one at a time — fPutObject
  // streams from disk, so serial keeps memory flat even on a small box.
  Future<void> _upload(
    String hash,
    TorrentStreamInfo info,
    List<TorrentFile> files,
  ) async {
    if (!_uploading.add(hash)) return;
    final total = files.fold<int>(0, (sum, f) => sum + f.length);
    var done = 0;
    _uploadProgress[hash] = 0;
    try {
      for (final file in files) {
        final base = done;
        await signer.putFile(
          file.name,
          '${info.downloadDir}/${file.name}',
          onProgress: (sent) {
            if (total > 0) _uploadProgress[hash] = (base + sent) / total;
          },
        );
        _s3Files.add(file.name); // playable now, without waiting for siblings
        done += file.length;
        Log.d('s3', 'uploaded ${file.name}');
      }
      _s3Ready.add(hash); // we did the uploads — no need to HEAD to confirm
      _uploadProgress.remove(hash);
      unawaited(_finalize(hash, info)); // only now is the local copy redundant
    } catch (e) {
      _uploading.remove(hash); // failed — retry on the next add/restart/poll
      _uploadProgress.remove(hash);
      // Loud even in production: a stranded upload leaves the film off S3 and
      // its bytes on the download disk, and nothing else reports it.
      Log.w('s3', 'upload for $hash failed: $e');
    }
  }

  /// Whether a torrent is on S3, driving the upload/finalize side-effects for
  /// finished-but-not-yet-uploaded ones. Shared by the /torrents poll and the
  /// internal sweep so uploads run even with no client connected.
  Future<bool> resolve(TorrentState s) async {
    if (_s3Ready.contains(s.hashString)) return true;
    if (s.percentDone < 1.0) return false;
    // An upload is already running for this hash — it latches _s3Ready and
    // finalizes itself. Skip the HEADs (a season pack would issue one per
    // episode on every 1s poll).
    if (_uploading.contains(s.hashString)) return false;
    // Known stranded: nothing can change until the data is fetched again,
    // which goes through /torrents (add) or a control action — both clear
    // this. Skip the per-episode HEADs rather than re-asking S3 every poll.
    if (_stranded.containsKey(s.hashString)) return false;
    final info = await client.streamInfo(s.hashString);
    if (info == null || info.files.isEmpty) return false;
    final videos = [
      for (final i in videoFileIndices(info.files)) info.files[i],
    ];
    // The torrent counts as on S3 only when *every* video file is there — the
    // hand-over deletes the whole directory, so a partial set would strand the
    // rest. Re-upload just what's missing (resumes an interrupted batch).
    final missing = <TorrentFile>[];
    for (final f in videos) {
      if (!await fileOnS3(f.name)) missing.add(f);
    }
    if (missing.isEmpty) {
      _s3Ready.add(s.hashString);
      unawaited(_finalize(s.hashString, info));
      return true;
    }
    // Only what we still hold can go up. A file missing from S3 *and* from
    // disk is unrecoverable, and asking minio to upload it just fails on a -1
    // stat.
    final uploadable = <TorrentFile>[];
    var lost = 0;
    for (final f in missing) {
      if (await File('${info.downloadDir}/${f.name}').exists()) {
        uploadable.add(f);
      } else {
        lost++;
      }
    }
    if (lost > 0) {
      _stranded[s.hashString] = lost;
      Log.w(
        's3',
        '${s.hashString}: $lost of ${videos.length} files are on neither S3 '
            'nor disk — re-download to recover',
      );
    }
    if (uploadable.isNotEmpty) {
      unawaited(_upload(s.hashString, info, uploadable));
    }
    return false;
  }

  // Poll at 1s only while a download is in flight, so a finish is caught and
  // its upload kicked within a second. When nothing is downloading the loop
  // stops entirely — there's no idle timer. It's (re)started at boot and on
  // every add; upload success latches + finalizes on its own, so no polling is
  // needed to notice the object landed.
  var _sweeping = false;
  var _disposed = false;
  Timer? _sweepTimer;

  void ensureSweep() {
    if (_sweeping || _disposed) return;
    _sweeping = true;
    Future<void> tick() async {
      var downloading = false;
      try {
        final states = await client.list();
        for (final s in states) {
          await resolve(s);
        }
        downloading = states.any((s) => s.percentDone < 1.0);
      } catch (e) {
        Log.d('s3', 'sweep failed: $e');
      }
      if (downloading && !_disposed) {
        _sweepTimer = Timer(const Duration(seconds: 1), tick);
      } else {
        _sweeping = false;
      }
    }

    tick();
  }

  /// Stops the sweep so a closed server leaves no timer behind.
  void dispose() {
    _disposed = true;
    _sweepTimer?.cancel();
  }
}
