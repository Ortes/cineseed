import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:cineseed_shared/cineseed_shared.dart';

import 'torrent_client.dart';

/// Minimal Transmission JSON-RPC client.
///
/// Handles the `409 + X-Transmission-Session-Id` handshake and optional Basic
/// auth. Torrents are added unpaused (`paused: false`) so downloading starts
/// immediately.
class TransmissionClient implements TorrentClient {
  final Uri rpcUrl;
  final String? user;
  final String? pass;
  final http.Client _http;
  String? _sessionId;

  TransmissionClient({
    required String url,
    this.user,
    this.pass,
    http.Client? client,
  }) : rpcUrl = Uri.parse(url),
       _http = client ?? http.Client();

  Future<Map<String, dynamic>> _call(
    String method, [
    Map<String, dynamic> arguments = const {},
  ]) async {
    final body = jsonEncode({'method': method, 'arguments': arguments});

    var res = await _send(body);
    if (res.statusCode == 409) {
      // Transmission CSRF handshake: grab the session id and replay once.
      _sessionId = res.headers['x-transmission-session-id'];
      res = await _send(body);
    }
    if (res.statusCode != 200) {
      throw Exception('Transmission $method failed: HTTP ${res.statusCode}');
    }
    final json = jsonDecode(res.body) as Map<String, dynamic>;
    if (json['result'] != 'success') {
      throw Exception('Transmission $method: ${json['result']}');
    }
    return (json['arguments'] as Map?)?.cast<String, dynamic>() ?? {};
  }

  Future<http.Response> _send(String body) {
    final headers = <String, String>{'Content-Type': 'application/json'};
    if (_sessionId != null) headers['X-Transmission-Session-Id'] = _sessionId!;
    if (user != null && pass != null) {
      headers['Authorization'] =
          'Basic ${base64Encode(utf8.encode('$user:$pass'))}';
    }
    return _http.post(rpcUrl, headers: headers, body: body);
  }

  @override
  Future<void> addTorrent(List<int> metainfo, {bool paused = false}) async {
    final args = await _call('torrent-add', {
      'metainfo': base64Encode(metainfo),
      'paused': paused,
    });
    // torrent-add returns either `torrent-added` or `torrent-duplicate`.
    final added =
        (args['torrent-added'] ?? args['torrent-duplicate'])
            as Map<String, dynamic>?;
    final hash = added?['hashString'] as String?;
    if (hash != null) await setSequential(hash, true);
  }

  /// Enable/disable sequential (in-order) downloading so the file fills
  /// front-to-back and can be streamed locally while still downloading.
  /// Requires Transmission 4.1+ (RPC field is snake_case `sequential_download`,
  /// a 4.1 convention); older daemons silently ignore the unknown field.
  Future<void> setSequential(String hash, bool value) async {
    try {
      await _call('torrent-set', {
        'ids': [hash],
        'sequential_download': value,
      });
    } catch (_) {
      // Older Transmission rejects the unknown arg — ignore, leech proceeds
      // in default (rarest-first) order.
    }
  }

  @override
  Future<List<TorrentState>> list() async {
    final args = await _call('torrent-get', {
      'fields': [
        'hashString',
        'name',
        'percentDone',
        'status',
        'eta',
        'rateDownload',
        'rateUpload',
        'uploadedEver',
        'downloadedEver',
        'totalSize',
        'isFinished',
      ],
    });
    final torrents = (args['torrents'] as List? ?? [])
        .cast<Map<String, dynamic>>();
    return torrents.map(TorrentState.fromJson).toList();
  }

  @override
  Future<List<TorrentFile>> files(String hash) async {
    final args = await _call('torrent-get', {
      'ids': [hash],
      'fields': ['name', 'files'],
    });
    final torrents = (args['torrents'] as List? ?? [])
        .cast<Map<String, dynamic>>();
    if (torrents.isEmpty) return const [];
    final files = (torrents.first['files'] as List? ?? [])
        .cast<Map<String, dynamic>>();
    return files
        .map(
          (f) => TorrentFile(
            f['name'] as String? ?? '',
            (f['length'] as num?)?.toInt() ?? 0,
            (f['bytesCompleted'] as num?)?.toInt() ?? 0,
          ),
        )
        .toList();
  }

  @override
  Future<TorrentStreamInfo?> streamInfo(String hash) async {
    final args = await _call('torrent-get', {
      'ids': [hash],
      'fields': ['name', 'downloadDir', 'percentDone', 'isFinished', 'files'],
    });
    final torrents = (args['torrents'] as List? ?? [])
        .cast<Map<String, dynamic>>();
    if (torrents.isEmpty) return null;
    final t = torrents.first;
    final files = (t['files'] as List? ?? [])
        .cast<Map<String, dynamic>>()
        .map(
          (f) => TorrentFile(
            f['name'] as String? ?? '',
            (f['length'] as num?)?.toInt() ?? 0,
            (f['bytesCompleted'] as num?)?.toInt() ?? 0,
          ),
        )
        .toList();
    return TorrentStreamInfo(
      name: t['name'] as String? ?? '',
      downloadDir: t['downloadDir'] as String? ?? '',
      percentDone: (t['percentDone'] as num?)?.toDouble() ?? 0,
      isFinished: t['isFinished'] as bool? ?? false,
      files: files,
    );
  }

  @override
  Future<TorrentPieces?> pieces(String hash) async {
    final args = await _call('torrent-get', {
      'ids': [hash],
      'fields': ['pieces', 'pieceSize'],
    });
    final torrents = (args['torrents'] as List? ?? [])
        .cast<Map<String, dynamic>>();
    if (torrents.isEmpty) return null;
    final t = torrents.first;
    return TorrentPieces(
      base64Decode(t['pieces'] as String),
      (t['pieceSize'] as num).toInt(),
    );
  }

  @override
  Future<void> start(String hash) => _call('torrent-start', {
    'ids': [hash],
  });

  @override
  Future<void> stop(String hash) => _call('torrent-stop', {
    'ids': [hash],
  });

  @override
  Future<void> remove(String hash, {bool deleteData = false}) =>
      _call('torrent-remove', {
        'ids': [hash],
        'delete-local-data': deleteData,
      });

  @override
  Future<void> setLocation(String hash, String location, {bool move = false}) =>
      _call('torrent-set-location', {
        'ids': [hash],
        'location': location,
        'move': move,
      });
}
