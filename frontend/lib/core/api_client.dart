import 'package:cineseed_shared/cineseed_shared.dart';
import 'package:dio/dio.dart';

import 'debug_log.dart';

/// One selectable audio track from `/api/hls/<hash>/audio-tracks`. The muxed
/// HLS manifest carries no hls.js audio renditions, so the player's language
/// menu is sourced here and switched by reloading the master with `?a=<order>`.
class AudioTrackInfo {
  const AudioTrackInfo({
    required this.order,
    required this.label,
    this.language,
    this.isDefault = false,
  });

  final int order;
  final String label;
  final String? language;
  final bool isDefault;

  factory AudioTrackInfo.fromJson(Map<String, dynamic> j) {
    final order = j['order'] as int;
    return AudioTrackInfo(
      order: order,
      label: (j['label'] as String?) ?? 'Audio ${order + 1}',
      language: j['language'] as String?,
      isDefault: (j['isDefault'] as bool?) ?? false,
    );
  }
}

/// Thin HTTP wrapper around the Cineseed backend.
class ApiClient {
  final Dio _dio;
  final String baseUrl;

  ApiClient(this.baseUrl) : _dio = Dio(BaseOptions(baseUrl: baseUrl)) {
    _dio.interceptors.add(_DebugLogInterceptor());
  }

  /// Stream id: the torrent hash, suffixed with `.<fileIndex>` to address one
  /// file inside a multi-file torrent (a season pack). A bare hash means the
  /// torrent's primary — largest — video, which is the whole story for the
  /// single-video torrents most releases are.
  ///
  /// The index goes in the path rather than a query parameter because the HLS
  /// playlists the backend serves reference their segments relatively: hls.js
  /// resolves those against the playlist URL and would drop a query string.
  static String streamId(String hash, int? fileIndex) =>
      fileIndex == null ? hash : '$hash.$fileIndex';

  Future<List<TorrentResult>> search(String query) async {
    final res = await _dio.get('/api/search', queryParameters: {'q': query});
    return (res.data as List)
        .map((e) => TorrentResult.fromJson((e as Map).cast<String, dynamic>()))
        .toList();
  }

  Future<void> addTorrent(String infoHash) =>
      _dio.post('/api/torrents', data: {'hash': infoHash});

  Future<List<TorrentState>> listTorrents() async {
    final res = await _dio.get('/api/torrents');
    return (res.data as List)
        .map((e) => TorrentState.fromJson((e as Map).cast<String, dynamic>()))
        .toList();
  }

  Future<void> start(String hash) => _dio.post('/api/torrents/$hash/start');
  Future<void> stop(String hash) => _dio.post('/api/torrents/$hash/stop');
  Future<void> remove(String hash) => _dio.post('/api/torrents/$hash/remove');

  /// The torrent's video files with per-file progress and S3 state. More than
  /// one means the user picks which to watch before anything plays.
  Future<TorrentFiles> torrentFiles(String hash,
      {CancelToken? cancelToken}) async {
    final res = await _dio.get('/api/torrents/$hash/files',
        cancelToken: cancelToken);
    return TorrentFiles.fromJson((res.data as Map).cast<String, dynamic>());
  }

  Future<String> streamUrl(String hash, {int? fileIndex}) async {
    final res = await _dio.get('/api/stream/${streamId(hash, fileIndex)}');
    return StreamLink.fromJson((res.data as Map).cast<String, dynamic>()).url;
  }

  /// `/api/stream` status: `mode` is `s3` (finished, on S3 → playable via HLS),
  /// `local` (still downloading → only the VLC link works), and `url` is the
  /// direct S3/local link (used for the copy-to-VLC button).
  Future<({String url, String mode})> streamStatus(String hash,
      {int? fileIndex, CancelToken? cancelToken}) async {
    final res = await _dio.get('/api/stream/${streamId(hash, fileIndex)}',
        cancelToken: cancelToken);
    final m = (res.data as Map).cast<String, dynamic>();
    return (url: (m['url'] as String?) ?? '', mode: (m['mode'] as String?) ?? '');
  }

  /// Absolute URL of the live HLS master playlist for the in-app player.
  /// [audioOrder] selects which audio track the muxed variant embeds (the
  /// player reloads this URL with a new order to switch language).
  String hlsMasterUrl(String hash, {int? fileIndex, int? audioOrder}) =>
      '$baseUrl/api/hls/${streamId(hash, fileIndex)}/master.m3u8'
      '${audioOrder != null ? '?a=$audioOrder' : ''}';

  /// Audio tracks for one file's HLS stream (for the player's language menu).
  Future<List<AudioTrackInfo>> audioTracks(String hash,
      {int? fileIndex, CancelToken? cancelToken}) async {
    final res = await _dio.get(
        '/api/hls/${streamId(hash, fileIndex)}/audio-tracks',
        cancelToken: cancelToken);
    return (res.data as List)
        .map((e) => AudioTrackInfo.fromJson((e as Map).cast<String, dynamic>()))
        .toList();
  }

  /// Backend runtime config. `debugMode` mirrors the server's `CINESEED_DEBUG`
  /// and, when true, turns on the frontend's verbose logging. Best-effort: a
  /// missing/old backend (no `/api/config`) yields `false`.
  Future<bool> fetchDebugMode() async {
    final res = await _dio.get('/api/config');
    return ((res.data as Map)['debugMode'] as bool?) ?? false;
  }

  Future<String> downloadUrl(String hash, {int? fileIndex}) async {
    final res = await _dio.get('/api/download/${streamId(hash, fileIndex)}');
    return (res.data as Map)['url'] as String;
  }

  /// TMDB metadata for a movie or TV show, picking the endpoint by [type].
  /// Returns `null` if the backend isn't configured (404), the id is unknown to
  /// TMDB, or the release isn't a movie/TV title ([MediaType.other] → no call).
  Future<TmdbMovie?> tmdbTitle(MediaType type, int id) async {
    final path = switch (type) {
      MediaType.movie => '/api/tmdb/movie/$id',
      MediaType.tv => '/api/tmdb/tv/$id',
      MediaType.other => null,
    };
    if (path == null) return null;
    try {
      final res = await _dio.get(path);
      return TmdbMovie.fromJson((res.data as Map).cast<String, dynamic>());
    } on DioException catch (e) {
      if (e.response?.statusCode == 404) return null;
      rethrow;
    }
  }
}

/// Logs every Dio request/response/error to the browser console when debug mode
/// is on (no-op otherwise). The 2 s polls (`/api/torrents` — the library, and
/// `/api/torrents/<hash>/files` — the file picker) are excluded to keep the log
/// readable. NB: HLS playlist/segment traffic goes through hls.js (XHR), not
/// Dio — those are logged by the player fork instead.
class _DebugLogInterceptor extends Interceptor {
  static const _excluded = '/api/torrents';

  bool _skip(String? path) => path != null && path.startsWith(_excluded);

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    if (!_skip(options.path)) {
      DebugLog.log('NET', '→ ${options.method} ${options.uri}');
    }
    handler.next(options);
  }

  @override
  void onResponse(Response response, ResponseInterceptorHandler handler) {
    if (!_skip(response.requestOptions.path)) {
      DebugLog.log('NET',
          '← ${response.statusCode} ${response.requestOptions.uri}');
    }
    handler.next(response);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    if (!_skip(err.requestOptions.path)) {
      final what = err.type == DioExceptionType.cancel
          ? 'CANCELLED'
          : '${err.response?.statusCode ?? ''} ${err.type.name} ${err.message ?? ''}';
      DebugLog.log('NET', '✗ ${err.requestOptions.uri} — $what');
    }
    handler.next(err);
  }
}
