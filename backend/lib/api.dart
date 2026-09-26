import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cineseed_shared/cineseed_shared.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import 'log.dart';
import 'storage/s3_signer.dart';
import 'streaming/hls_playlists.dart';
import 'streaming/hls_session.dart';
import 'streaming/s3_range_proxy.dart';
import 'streaming/segments.dart';
import 'torrent/stream_id.dart';
import 'torrent/torrent_client.dart';
import 'tracker/tmdb_client.dart';
import 'tracker/tracker_connector.dart';

const _contentTypes = {
  '.mkv': 'video/x-matroska',
  '.mp4': 'video/mp4',
  '.m4v': 'video/mp4',
  '.webm': 'video/webm',
  '.mov': 'video/quicktime',
  '.avi': 'video/x-msvideo',
  '.ts': 'video/mp2t',
};

/// Every video-extension file, in torrent order (falls back to all files when
/// the torrent has no recognisable video). A single-video torrent yields one
/// entry; a season pack yields one per episode — all of which must reach S3
/// before the local copy may be freed.
List<TorrentFile> _videoFiles(List<TorrentFile> files) =>
    [for (final i in videoFileIndices(files)) files[i]];

String _contentTypeFor(String name) {
  final lower = name.toLowerCase();
  for (final e in _contentTypes.entries) {
    if (lower.endsWith(e.key)) return e.value;
  }
  return 'application/octet-stream';
}

/// All `/api/*` routes. Mounted under `/api` by the server.
Router buildApiRouter({
  required TrackerConnector tracker,
  required TorrentClient client,
  required S3Signer signer,
  required String downloadDir,
  required String incompleteDir,
  required HlsSessionManager hls,
  required SegmentGenerator segments,
  TmdbClient? tmdb,
  bool debug = false,
}) {
  final r = Router();

  // Latch of hashes confirmed on S3 (immutable once true). `uploading`/`finalized`
  // guard the once-per-hash upload and hand-over against concurrent polls.
  final s3Ready = <String>{};
  final uploading = <String>{};
  final finalized = <String>{};
  // hash → S3 upload fraction (0..1) while an upload is in flight.
  final uploadProgress = <String, double>{};
  // hash → how many video files are on neither S3 nor disk. Freeing the local
  // copy before every file had landed used to strand the rest (fixed), and the
  // torrents it already hit can never complete: their bytes are simply gone.
  // Recording that stops resolveS3 from re-attempting an upload whose source
  // does not exist — which it otherwise does on every single poll, forever.
  final stranded = <String, int>{};
  // Individual S3 object keys confirmed present (immutable once true, same as
  // s3Ready but per file). A season pack is polled per file by the file picker
  // and re-checked per file by resolveS3; without this each poll would re-HEAD
  // every episode that is already up.
  final s3Files = <String>{};

  Future<bool> fileOnS3(String key) async {
    if (s3Files.contains(key)) return true;
    if (!await signer.exists(key)) return false;
    s3Files.add(key);
    return true;
  }

  // Once on S3 the local copy is redundant: point Transmission at the S3-backed
  // mount (so it still sees its files) and free the download disk.
  Future<void> finalizeToS3(String hash, TorrentStreamInfo info) async {
    if (!finalized.add(hash)) return;
    if (info.downloadDir.isEmpty || info.downloadDir == downloadDir) return;
    final localPath = '${info.downloadDir}/${info.name}';
    try {
      await client.setLocation(hash, downloadDir, move: false);
      final f = File(localPath);
      final d = Directory(localPath);
      if (await f.exists()) {
        await f.delete();
      } else if (await d.exists()) {
        await d.delete(recursive: true);
      }
      Log.d('s3', 'finalized $hash → $downloadDir, freed $localPath');
    } catch (e) {
      finalized.remove(hash);
      Log.d('s3', 'finalize $hash failed: $e');
    }
  }

  // A finished torrent stays on the local download disk (info.downloadDir) so
  // reads hit plain files, never the rclone VFS. Upload it to S3 straight from
  // there — a busy reader can't disturb this.
  //
  // EVERY video file goes up, not just the primary one: finalizeToS3() frees the
  // torrent's whole directory, so a season pack whose other episodes were never
  // uploaded would lose them outright. Files go one at a time — fPutObject
  // streams from disk, so serial keeps memory flat even on a small box.
  Future<void> uploadToS3(
      String hash, TorrentStreamInfo info, List<TorrentFile> files) async {
    if (!uploading.add(hash)) return;
    final total = files.fold<int>(0, (sum, f) => sum + f.length);
    var done = 0;
    uploadProgress[hash] = 0;
    try {
      for (final file in files) {
        final base = done;
        await signer.putFile(file.name, '${info.downloadDir}/${file.name}',
            onProgress: (sent) {
          if (total > 0) uploadProgress[hash] = (base + sent) / total;
        });
        s3Files.add(file.name); // playable now, without waiting for its siblings
        done += file.length;
        Log.d('s3', 'uploaded ${file.name}');
      }
      s3Ready.add(hash); // we did the uploads — no need to HEAD to confirm them
      uploadProgress.remove(hash);
      unawaited(finalizeToS3(hash, info)); // only now is the local copy redundant
    } catch (e) {
      uploading.remove(hash); // failed — retry on the next add / restart / poll
      uploadProgress.remove(hash);
      // Loud even in production: a stranded upload leaves the film off S3 and
      // its bytes on the download disk, and nothing else reports it.
      Log.w('s3', 'upload for $hash failed: $e');
    }
  }

  // Resolve whether a torrent is on S3, driving the upload/finalize side-effects
  // for finished-but-not-yet-uploaded ones. Shared by the /torrents poll and the
  // internal sweep below so uploads run even with no client connected.
  Future<bool> resolveS3(TorrentState s) async {
    if (s3Ready.contains(s.hashString)) return true;
    if (s.percentDone < 1.0) return false;
    // An upload is already running for this hash — it latches s3Ready and
    // finalizes itself. Skip the HEADs (a season pack would issue one per
    // episode on every 1s poll).
    if (uploading.contains(s.hashString)) return false;
    // Known stranded: nothing can change until the data is fetched again, which
    // goes through /torrents (add) or a control action — both clear this. Skip
    // the per-episode HEADs rather than re-asking S3 about it every poll.
    if (stranded.containsKey(s.hashString)) return false;
    final info = await client.streamInfo(s.hashString);
    if (info == null || info.files.isEmpty) return false;
    final videos = _videoFiles(info.files);
    // The torrent counts as on S3 only when *every* video file is there — the
    // hand-over deletes the whole directory, so a partial set would strand the
    // rest. Re-upload just what's missing (resumes an interrupted batch).
    final missing = <TorrentFile>[];
    for (final f in videos) {
      if (!await fileOnS3(f.name)) missing.add(f);
    }
    if (missing.isEmpty) {
      s3Ready.add(s.hashString);
      unawaited(finalizeToS3(s.hashString, info));
      return true;
    }
    // Only what we still hold can go up. A file missing from S3 *and* from disk
    // is unrecoverable, and asking minio to upload it just fails on a -1 stat.
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
      stranded[s.hashString] = lost;
      Log.w('s3',
          '${s.hashString}: $lost of ${videos.length} files are on neither S3 '
          'nor disk — re-download to recover');
    }
    if (uploadable.isNotEmpty) {
      unawaited(uploadToS3(s.hashString, info, uploadable));
    }
    return false;
  }

  // Poll at 1s only while a download is in flight, so a finish is caught and its
  // upload kicked within a second. When nothing is downloading the loop stops
  // entirely — there's no idle timer. It's (re)started at boot and on every add;
  // upload success latches + finalizes on its own, so no polling is needed to
  // notice the object landed.
  var sweeping = false;
  void ensureSweep() {
    if (sweeping) return;
    sweeping = true;
    Future<void> tick() async {
      var downloading = false;
      try {
        final states = await client.list();
        for (final s in states) {
          await resolveS3(s);
        }
        downloading = states.any((s) => s.percentDone < 1.0);
      } catch (e) {
        Log.d('s3', 'sweep failed: $e');
      }
      if (downloading) {
        Timer(const Duration(seconds: 1), tick);
      } else {
        sweeping = false;
      }
    }

    tick();
  }

  ensureSweep(); // boot: reconcile once (upload any finished-but-not-on-S3), then idle

  // Runtime config for the frontend. The web build is baked into the image, so
  // it can't read env vars — it reads `debugMode` here at startup to mirror the
  // server's CINESEED_DEBUG (turning on the frontend's verbose logging too).
  r.get('/config', (Request req) async {
    return _json({'debugMode': debug}, 200, 'no-store');
  });

  // TMDB metadata proxy (poster, overview, runtime, …). Returns 404 if the
  // backend has no TMDB_API_KEY configured.
  r.get('/tmdb/movie/<id>', (Request req, String id) async {
    if (tmdb == null) {
      return _json({'error': 'tmdb disabled (set TMDB_API_KEY)'}, 404);
    }
    final n = int.tryParse(id);
    if (n == null) return _json({'error': 'bad id'}, 400);
    final m = await tmdb.movie(n);
    if (m == null) return _json({'error': 'not found'}, 404);
    return _json(m.toJson(), 200, 'public, max-age=86400');
  });

  // TMDB TV-show metadata. Separate from /movie because TMDB's movie and TV id
  // spaces are independent — the same integer is a different title in each.
  r.get('/tmdb/tv/<id>', (Request req, String id) async {
    if (tmdb == null) {
      return _json({'error': 'tmdb disabled (set TMDB_API_KEY)'}, 404);
    }
    final n = int.tryParse(id);
    if (n == null) return _json({'error': 'bad id'}, 400);
    final m = await tmdb.tv(n);
    if (m == null) return _json({'error': 'not found'}, 404);
    return _json(m.toJson(), 200, 'public, max-age=86400');
  });

  // Search the tracker → list of results (with infoHash).
  r.get('/search', (Request req) async {
    final q = req.url.queryParameters['q'] ?? '';
    if (q.trim().isEmpty) return _json({'error': 'missing q'}, 400);
    final results = await tracker.search(q, type: req.url.queryParameters['type']);
    return _json(results.map((e) => e.toJson()).toList());
  });

  // Raw .torrent bytes (mostly internal/debug).
  r.get('/torrent/<hash>', (Request req, String hash) async {
    final bytes = await tracker.fetchTorrent(hash);
    return Response.ok(bytes, headers: {'Content-Type': 'application/x-bittorrent'});
  });

  // Library: live torrent state. `onS3` — whether the video file has landed on
  // S3 — is the gate the frontend uses for in-app playback, Cast and download.
  r.get('/torrents', (Request req) async {
    final states = await client.list();
    final annotated = await Future.wait(states.map((s) async {
      final onS3 = await resolveS3(s);
      return s.copyWith(
        onS3: onS3,
        uploadProgress: uploadProgress[s.hashString] ?? 0,
        strandedFiles: stranded[s.hashString] ?? 0,
      );
    }));
    return _json(annotated.map((e) => e.toJson()).toList());
  });

  // The torrent's video files, in torrent (episode) order, each with its own
  // progress and S3 state. A multi-file torrent — a season pack — is picked from
  // here before anything is played: the file list is the only place the user can
  // choose WHICH episode to watch, and every other route addresses that choice
  // by `<hash>.<index>` (see [StreamId]).
  //
  // Polled by the picker while downloading, so the per-file HEADs are skipped
  // until the torrent is complete: uploads only start at 100%, so before that
  // every answer is known to be false without asking S3.
  r.get('/torrents/<hash>/files', (Request req, String hash) async {
    final info = await client.streamInfo(hash);
    if (info == null || info.files.isEmpty) {
      return _json({'error': 'torrent not found or no files'}, 404);
    }
    final finished = info.percentDone >= 1.0;
    final files = <TorrentFileInfo>[];
    for (final i in videoFileIndices(info.files)) {
      final f = info.files[i];
      files.add(TorrentFileInfo(
        index: i,
        name: f.name,
        length: f.length,
        bytesCompleted: f.bytesCompleted,
        onS3: finished && await fileOnS3(f.name),
      ));
    }
    return _json(TorrentFiles(
      name: info.name,
      percentDone: info.percentDone,
      files: files,
    ).toJson(), 200, 'no-store');
  });

  // Add: fetch the .torrent then add it STARTED (we leech).
  r.post('/torrents', (Request req) async {
    final body = jsonDecode(await req.readAsString()) as Map<String, dynamic>;
    final hash = body['hash'] as String?;
    if (hash == null || hash.isEmpty) return _json({'error': 'missing hash'}, 400);
    final metainfo = await tracker.fetchTorrent(hash);
    await client.addTorrent(metainfo, paused: false);
    stranded.remove(hash); // re-fetching is exactly what un-strands a torrent
    ensureSweep(); // start the 1s poll for this download
    return _json({'ok': true});
  });

  // Control: start / stop / remove.
  r.post('/torrents/<hash>/<action>', (Request req, String hash, String action) async {
    // Any deliberate action on a torrent may put its files back (a re-verify
    // after copying them in, a restart of a re-fetch) — re-evaluate rather than
    // trusting a verdict reached before the user intervened.
    stranded.remove(hash);
    switch (action) {
      case 'start':
        await client.start(hash);
      case 'stop':
        await client.stop(hash);
      case 'remove':
        await client.remove(hash, deleteData: req.url.queryParameters['deleteData'] == 'true');
      default:
        return _json({'error': 'unknown action'}, 404);
    }
    return _json({'ok': true});
  });

  // Resolves a stream id — `<hash>` or `<hash>.<fileIndex>`, see [StreamId] — to
  // the torrent's state plus the single file it addresses. Null when the torrent
  // is unknown, has no files, or the id names a file it doesn't have.
  Future<(TorrentStreamInfo, TorrentFile)?> resolveFile(String id) async {
    final sid = StreamId.parse(id);
    if (sid == null) return null;
    final info = await client.streamInfo(sid.hash);
    if (info == null || info.files.isEmpty) return null;
    final index = sid.resolve(info.files);
    if (index == null) return null;
    return (info, info.files[index]);
  }

  // Stream: hybrid. If the download is finished the object is on S3 → hand the
  // browser a presigned URL (fast, offloads the server). Until the object lands
  // on S3 (still downloading, or finished but not yet uploaded) → hand back the
  // local-file route, which streams the copy on the local download disk (never
  // the rclone VFS, whose reads would abort the concurrent S3 upload).
  r.get('/stream/<id>', (Request req, String id) async {
    final resolved = await resolveFile(id);
    if (resolved == null) {
      return _json({'error': 'torrent not found or no such file'}, 404);
    }
    final (info, file) = resolved;

    // NB: Transmission's `isFinished` means "done *seeding*", not "done
    // downloading" — the download-complete signal is percentDone >= 1.0.
    // But 100%-downloaded ≠ uploaded-to-S3: rclone only flushes the completed
    // file from its local VFS cache to the bucket on close/writeback (minutes
    // for a multi-GB file, and a seeding handle can delay it). Handing out a
    // presigned URL before the object lands → 404. So only go S3 once the
    // object actually exists; otherwise keep serving the local copy.
    if (info.percentDone >= 1.0 && await fileOnS3(file.name)) {
      final url = await signer.presign(file.name); // name == S3 key
      return _json({'url': url, 'mode': 's3', 'percentDone': info.percentDone});
    }

    // Absolute URL so the browser's <video> can hit it directly (works for
    // both same-origin prod and the cross-origin local dev frontend). The id is
    // carried through verbatim so the local route serves the same file.
    final localUrl = req.requestedUri.replace(path: '/api/file/$id').toString();
    return _json({'url': localUrl, 'mode': 'local', 'percentDone': info.percentDone});
  });

  // Download: only available once the completed object has landed on S3.
  // Returns a presigned URL with Content-Disposition: attachment so the
  // browser saves the file instead of streaming it inline.
  r.get('/download/<id>', (Request req, String id) async {
    final resolved = await resolveFile(id);
    if (resolved == null) {
      return _json({'error': 'torrent not found or no such file'}, 404);
    }
    final (info, file) = resolved;
    if (info.percentDone < 1.0 || !await fileOnS3(file.name)) {
      return _json({'error': 'not ready yet'}, 409);
    }
    final url = await signer.presignDownload(file.name);
    return _json({'url': url});
  });

  // Local file streaming with byte-accurate HTTP Range support. Only serves up
  // to the contiguously-downloaded prefix (Transmission's bytesCompleted), so
  // with sequential download the player can read from the start while the rest
  // is still arriving.
  r.get('/file/<id>', (Request req, String id) async {
    final resolved = await resolveFile(id);
    if (resolved == null) {
      return _json({'error': 'torrent not found or no such file'}, 404);
    }
    final (info, tf) = resolved;
    // Use Transmission's per-torrent downloadDir as the primary lookup. A
    // downloading/finished-but-not-yet-uploaded torrent stays on the local
    // download disk; only once its object is on S3 does finalizeToS3()
    // relocate it onto DOWNLOAD_DIR (e.g. an rclone mount) — by which
    // point playback uses the presigned S3 URL, not this route. If an
    // incomplete-dir is configured we fall through there when not found.
    final dir = info.downloadDir.isNotEmpty ? info.downloadDir : downloadDir;
    // While downloading, Transmission (rename-partial-files=true) names the
    // file `<name>.part`; it is renamed to `<name>` on completion.
    File? _find(String base) {
      final f = File(base);
      if (f.existsSync()) return f;
      final p = File('$base.part');
      if (p.existsSync()) return p;
      return null;
    }
    var file = _find('$dir/${tf.name}');
    if (file == null && incompleteDir.isNotEmpty) {
      file = _find('$incompleteDir/${tf.name}');
    }
    if (file == null) {
      return _json({'error': 'file not on disk yet', 'path': '$dir/${tf.name}'}, 404);
    }

    final total = tf.length;
    // Bytes safe to serve: whole file if download complete, else the
    // contiguous downloaded prefix (percentDone, not the seeding-done flag).
    final available = info.percentDone >= 1.0 ? total : tf.bytesCompleted;
    final contentType = _contentTypeFor(tf.name);

    final range = req.headers['range'];
    Log.d('req', 'file/$id range=${range ?? '(none)'} '
        'available=$available/$total');
    // Parsed against `available`, not `total`, so a range can never point past
    // what has actually been downloaded. Shares the proxy's parser rather than
    // reimplementing it — the old inline version mishandled suffix ranges,
    // reading `bytes=-500` as 0-500 (the FIRST 501 bytes) instead of the last
    // 500, which is what ffmpeg uses to read an MKV's Cues near EOF.
    var start = 0;
    var end = available - 1;
    if (range != null) {
      final parsed = S3RangeProxy.parseRange(range, available);
      if (parsed == null) {
        return Response(416, headers: {
          'Content-Range': 'bytes */$total',
          'Accept-Ranges': 'bytes',
        });
      }
      start = parsed.$1;
      end = parsed.$2;
    }

    if (available <= 0 || start > end || start >= available) {
      return Response(416, headers: {
        'Content-Range': 'bytes */$total',
        'Accept-Ranges': 'bytes',
      });
    }

    final length = end - start + 1;
    return Response(
      206,
      body: _rangeStream(file, start, end),
      headers: {
        'Content-Type': contentType,
        'Accept-Ranges': 'bytes',
        'Content-Length': '$length',
        'Content-Range': 'bytes $start-$end/$total',
        'Cache-Control': 'no-store',
        // So the cross-origin (local dev) <video> can read range metadata.
        'Access-Control-Expose-Headers':
            'Content-Range, Accept-Ranges, Content-Length',
      },
    );
  });

  // ---- Live HLS (multi-audio + subtitles + Dolby→AAC) --------------------
  // The in-app player streams via these routes. Segments are generated on
  // demand from the presigned S3 URL — no pre-transcode, no stored segments.
  // Only eligible once the file is finished + on S3 + has a usable MKV index;
  // otherwise these return 409 (the player shows "still downloading").
  //
  // `<id>` is a stream id (`<hash>` or `<hash>.<fileIndex>`, see [StreamId]) and
  // is also the HLS session key, so each episode of a season pack gets its own
  // session, ffmpeg producer and proxy cache. It has to be a single path segment
  // rather than a query parameter: the media playlists these serve reference
  // their own init/segments relatively, and hls.js resolves those against the
  // playlist URL — a query string would be dropped on the way.

  // Master playlist: single muxed (video+audio) variant + (text) subtitle groups.
  // `?a=<order>` selects which audio track the variant embeds (default: the
  // source's default track). The frontend reloads the master with a new `a` to
  // switch audio (hls.js loadSource swap).
  r.get('/hls/<id>/master.m3u8', (Request req, String id) async {
    final s = await hls.get(id);
    if (s == null) return _json({'error': 'not ready for HLS'}, 409);
    await segments.videoInit(s); // populate codec string for the master CODECS
    final a = int.tryParse(req.url.queryParameters['a'] ?? '');
    return _m3u8(HlsPlaylists.master(s, audioOrder: a));
  });

  // Audio-track list for the player's language menu. The muxed manifest has no
  // EXT-X-MEDIA:TYPE=AUDIO group, so hls.js can't supply this — the frontend
  // reads it here and switches by reloading the master with `?a=<order>`.
  r.get('/hls/<id>/audio-tracks', (Request req, String id) async {
    final s = await hls.get(id);
    if (s == null) return _json({'error': 'not ready for HLS'}, 409);
    return _json([
      for (final a in s.probe.audio)
        {
          'order': a.order,
          'label': a.label,
          'language': a.language,
          'isDefault': a.isDefault,
          'channels': a.channels,
          'codec': a.codec,
        }
    ]);
  });

  // Muxed media playlist + init + segments, per audio track `<t>` (= audio
  // order). Each segment carries video (copied) + that audio track (AAC),
  // interleaved by one continuous ffmpeg → A/V stays in sync by construction.
  r.get('/hls/<id>/m/<t|[0-9]+>/index.m3u8',
      (Request req, String id, String t) async {
    final s = await hls.get(id);
    if (s == null) return _json({'error': 'not ready for HLS'}, 409);
    return _m3u8(HlsPlaylists.muxedMedia(s));
  });
  r.get('/hls/<id>/m/<t|[0-9]+>/init.mp4',
      (Request req, String id, String t) async {
    final s = await hls.get(id);
    if (s == null) return _json({'error': 'not ready for HLS'}, 409);
    final bytes = await segments.muxedInit(s, int.parse(t));
    if (bytes == null) return Response.notFound('no init');
    return _mp4(bytes);
  });
  r.get('/hls/<id>/m/<t|[0-9]+>/<seg|[0-9]+>.m4s',
      (Request req, String id, String t, String seg) async {
    final s = await hls.get(id);
    if (s == null) return _json({'error': 'not ready for HLS'}, 409);
    final mux = await segments.muxedSegment(s, int.parse(t), int.parse(seg));
    if (mux == null) {
      Log.d('req', 'm/$t/$seg.m4s → 404 (timeout/out-of-range)');
      return Response.notFound('no segment');
    }
    Log.d('req', 'm/$t/$seg.m4s → 200 ${mux.total}B (streamed)');
    // Streamed from disk, not buffered: the length is known from the parts'
    // on-disk sizes, so Content-Length stays exact. `mux` owns open file
    // handles which its stream closes — including on client disconnect.
    return Response.ok(mux.stream(), headers: {
      'Content-Type': 'video/mp4',
      'Content-Length': '${mux.total}',
      'Cache-Control': 'public, max-age=3600',
    });
  });

  // Subtitle media playlist + per-segment WebVTT (windowed ffmpeg seek, cached).
  r.get('/hls/<id>/s/<t|[0-9]+>/index.m3u8', (Request req, String id, String t) async {
    final s = await hls.get(id);
    if (s == null) return _json({'error': 'not ready for HLS'}, 409);
    return _m3u8(HlsPlaylists.subtitleMedia(s));
  });
  r.get('/hls/<id>/s/<t|[0-9]+>/<seg|[0-9]+>.vtt',
      (Request req, String id, String t, String seg) async {
    final s = await hls.get(id);
    if (s == null) return _json({'error': 'not ready for HLS'}, 409);
    final vtt = await segments.vttSegment(s, int.parse(t), int.parse(seg));
    if (vtt == null) return Response.notFound('no subtitle');
    return Response.ok(vtt, headers: {
      'Content-Type': 'text/vtt; charset=utf-8',
      'Cache-Control': 'public, max-age=3600',
    });
  });

  return r;
}

Response _m3u8(String body) => Response.ok(body, headers: {
      'Content-Type': 'application/vnd.apple.mpegurl',
      'Cache-Control': 'no-cache',
    });

Response _mp4(List<int> bytes) => Response.ok(bytes, headers: {
      'Content-Type': 'video/mp4',
      'Cache-Control': 'public, max-age=3600',
    });

/// Streams `[start, end]` (inclusive) of [file] in chunks, **always closing the
/// underlying handle** — the `finally` runs whether the stream completes or the
/// subscription is cancelled (client disconnect). `File.openRead` could leak the
/// fd on an aborted Range request; a leaked handle on the rclone mount keeps the
/// file "in use" so rclone never flushes it to S3 (the object then 404s).
Stream<List<int>> _rangeStream(File file, int start, int end) async* {
  final raf = await file.open();
  try {
    await raf.setPosition(start);
    var pos = start;
    const chunkSize = 256 * 1024;
    while (pos <= end) {
      final n = (end - pos + 1) < chunkSize ? (end - pos + 1) : chunkSize;
      final bytes = await raf.read(n);
      if (bytes.isEmpty) break;
      yield bytes;
      pos += bytes.length;
    }
  } finally {
    await raf.close();
  }
}

Response _json(Object data, [int status = 200, String? cache]) => Response(
      status,
      body: jsonEncode(data),
      headers: {
        'Content-Type': 'application/json',
        if (cache != null) 'Cache-Control': cache,
      },
    );
