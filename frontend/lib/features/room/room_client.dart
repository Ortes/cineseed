import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';

import 'package:flutter/foundation.dart';
import 'package:web/web.dart' as web;

import '../../core/debug_log.dart';

class RoomMember {
  const RoomMember({required this.id, required this.name, required this.ready});

  final String id;
  final String name;
  final bool ready;
}

/// The room's shared playback state, as last broadcast by the backend.
class RoomState {
  const RoomState({
    required this.playing,
    required this.position,
    required this.at,
    required this.by,
    required this.members,
    required this.waiting,
    required this.you,
  });

  final bool playing;

  /// Seconds into the film at server time [at] (ms since epoch).
  final double position;
  final int at;
  final String? by;
  final List<RoomMember> members;

  /// Names of the members everyone waits for; non-empty means the room is
  /// held and nobody plays.
  final List<String> waiting;

  /// This client's member id.
  final String you;

  bool get held => waiting.isNotEmpty;

  /// Whether players should be playing right now.
  bool get shouldPlay => playing && !held;

  /// Where the film is at server time [serverNowMs]. While held the backend
  /// froze [position], so nothing is extrapolated.
  double positionAt(int serverNowMs) =>
      shouldPlay ? position + (serverNowMs - at) / 1000.0 : position;

  factory RoomState.fromJson(Map<String, dynamic> j) => RoomState(
    playing: j['playing'] as bool,
    position: (j['position'] as num).toDouble(),
    at: j['at'] as int,
    by: j['by'] as String?,
    members: [
      for (final m in j['members'] as List)
        RoomMember(
          id: m['id'] as String,
          name: m['name'] as String,
          ready: m['ready'] as bool,
        ),
    ],
    waiting: (j['waiting'] as List).cast<String>(),
    you: j['you'] as String,
  );
}

/// One browser's connection to a watch-together room (`/api/rooms/<id>/ws`).
///
/// Joins on connect, reconnects on loss (a backend restart recreates the room
/// from [stream]), and keeps a server-clock offset from a few pings so
/// [RoomState.positionAt] can be evaluated locally. [state] is the latest
/// broadcast; [set] and [ready] are the two things a member may say.
class RoomClient {
  RoomClient({
    required this.url,
    required this.roomId,
    required this.stream,
    required this.name,
    this.creator = false,
  }) {
    _connect();
  }

  final String url;
  final String roomId;
  final String stream;
  final String name;

  /// This browser made the room: its player's state seeds the room's.
  final bool creator;

  final ValueNotifier<RoomState?> state = ValueNotifier(null);
  final ValueNotifier<bool> connected = ValueNotifier(false);

  web.WebSocket? _ws;
  bool _disposed = false;
  Timer? _reconnect;

  /// Last readiness this member reported, re-sent on every (re)connect: the
  /// player may be ready before the socket opens, and the backend starts a
  /// member as not ready.
  bool? _ready;

  /// Server clock minus local clock, ms; from the lowest-latency ping so far.
  int _offsetMs = 0;
  int _bestRttMs = 1 << 30;
  final Map<int, int> _pings = {}; // sent-at → nothing; keyed for lookup

  int serverNow() => DateTime.now().millisecondsSinceEpoch + _offsetMs;

  void _connect() {
    if (_disposed) return;
    final ws = web.WebSocket(url);
    _ws = ws;
    ws.onopen = ((web.Event _) {
      if (_ws != ws) return;
      DebugLog.log('ROOM', 'connected $roomId as $name');
      connected.value = true;
      _send({'t': 'join', 'name': name, 'stream': stream});
      if (_ready != null) _send({'t': 'ready', 'ready': _ready});
      for (var i = 0; i < 3; i++) {
        Timer(Duration(milliseconds: 150 * i), _ping);
      }
    }).toJS;
    ws.onmessage = ((web.MessageEvent e) {
      if (_ws != ws) return;
      _onMessage((e.data as JSString).toDart);
    }).toJS;
    ws.onclose = ((web.Event _) {
      if (_ws != ws) return;
      connected.value = false;
      if (_disposed) return;
      DebugLog.log('ROOM', 'socket closed — reconnecting in 2 s');
      _reconnect = Timer(const Duration(seconds: 2), _connect);
    }).toJS;
  }

  void _ping() {
    final now = DateTime.now().millisecondsSinceEpoch;
    _pings[now] = now;
    _send({'t': 'ping', 'c': now});
  }

  void _onMessage(String raw) {
    final msg = (jsonDecode(raw) as Map).cast<String, dynamic>();
    switch (msg['t']) {
      case 'pong':
        final sent = msg['c'] as int;
        if (_pings.remove(sent) == null) return;
        final now = DateTime.now().millisecondsSinceEpoch;
        final rtt = now - sent;
        if (rtt < _bestRttMs) {
          _bestRttMs = rtt;
          _offsetMs = (msg['s'] as int) - (sent + rtt ~/ 2);
          DebugLog.log('ROOM', 'clock offset ${_offsetMs}ms (rtt ${rtt}ms)');
        }
      case 'state':
        final s = RoomState.fromJson(msg);
        DebugLog.log(
          'ROOM',
          'state ${s.playing ? 'play' : 'pause'} '
              '@${s.position.toStringAsFixed(1)}s by=${s.by} '
              'members=${s.members.length} waiting=${s.waiting}',
        );
        state.value = s;
    }
  }

  void _send(Map<String, Object?> msg) {
    final ws = _ws;
    if (ws == null || ws.readyState != web.WebSocket.OPEN) return;
    ws.send(jsonEncode(msg).toJS);
  }

  /// This member played, paused or seeked: the room follows.
  void set({required bool playing, required double position}) {
    DebugLog.log(
      'ROOM',
      'set ${playing ? 'play' : 'pause'} @${position.toStringAsFixed(1)}s',
    );
    _send({'t': 'set', 'playing': playing, 'position': position});
  }

  /// Whether this member's player can play right now. False holds the room.
  void ready(bool ready) {
    DebugLog.log('ROOM', ready ? 'ready' : 'not ready');
    _ready = ready;
    _send({'t': 'ready', 'ready': ready});
  }

  void dispose() {
    _disposed = true;
    _reconnect?.cancel();
    _ws?.close();
    _ws = null;
    state.dispose();
    connected.dispose();
  }
}
