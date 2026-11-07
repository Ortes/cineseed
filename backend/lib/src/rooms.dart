import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:hls_remux/hls_remux.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// Watch-together rooms: a few browsers playing one file in sync.
///
/// A room holds one shared playback state — `playing`, `position` and the
/// server time `at` it was observed — and its members. Anyone in the room may
/// play, pause or seek: the last `set` wins and is broadcast to everyone. From
/// `at` every client derives where the film is now, so a message arriving late
/// still lands at the right second.
///
/// Playback is HELD while any member reports it is not ready (its player still
/// initialising, or buffering). A hold freezes `position` at the moment it
/// began and is released once everyone is ready again, or after [holdCap]: one
/// member on a bad connection must not pin the room forever. Clients pause
/// while the room is held and show who is waited for.
///
/// Rooms live in memory only. A client that joins an unknown id recreates it
/// (it says which stream the room plays), so a backend restart mid-film is a
/// reconnect, not a lost party. Rooms with no members are swept after
/// [emptyTtl].
class RoomService {
  RoomService({
    this.emptyTtl = const Duration(minutes: 10),
    this.holdCap = const Duration(seconds: 20),
  });

  final Duration emptyTtl;
  final Duration holdCap;

  final Map<String, Room> _rooms = {};
  Timer? _sweep;

  static final _random = Random.secure();

  Room? room(String id) => _rooms[id];

  /// A new room playing [stream] (a stream id — `<hash>` or `<hash>.<index>`).
  Room create(String stream) {
    final id = List.generate(
      16,
      (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    final room = Room._(id, stream, holdCap: holdCap);
    _rooms[id] = room;
    Log.d('room', '$id created for $stream');
    return room;
  }

  /// Wires one WebSocket connection to room [id]. The first message must be
  /// `join`; until then the socket belongs to no room.
  void connect(String id, WebSocketChannel channel) {
    Member? member;
    Room? room;
    channel.stream.listen(
      (raw) {
        final Map<String, dynamic> msg;
        try {
          msg = (jsonDecode(raw as String) as Map).cast<String, dynamic>();
        } catch (_) {
          return; // not ours
        }
        final t = msg['t'];
        if (t == 'ping') {
          channel.sink.add(
            jsonEncode({
              't': 'pong',
              'c': msg['c'],
              's': DateTime.now().millisecondsSinceEpoch,
            }),
          );
          return;
        }
        if (t == 'join') {
          if (member != null) return;
          final stream = msg['stream'] as String?;
          final name = (msg['name'] as String?)?.trim();
          if (stream == null || name == null || name.isEmpty) {
            channel.sink.close(4000, 'join needs a name and a stream');
            return;
          }
          room = _rooms[id] ??= Room._(id, stream, holdCap: holdCap);
          member = room!.join(name, channel);
          return;
        }
        final r = room;
        final m = member;
        if (r == null || m == null) return;
        switch (t) {
          case 'set':
            final playing = msg['playing'];
            final position = msg['position'];
            if (playing is bool && position is num) {
              r.set(m, playing: playing, position: position.toDouble());
            }
          case 'ready':
            final ready = msg['ready'];
            if (ready is bool) r.setReady(m, ready);
        }
      },
      onDone: () {
        final r = room;
        final m = member;
        if (r != null && m != null) r.leave(m);
      },
      onError: (_) {},
      cancelOnError: true,
    );
  }

  /// Drops rooms that have had no members for [emptyTtl].
  void startSweeping() {
    _sweep ??= Timer.periodic(const Duration(minutes: 1), (_) {
      final now = DateTime.now();
      _rooms.removeWhere((id, r) {
        final stale =
            r.members.isEmpty && now.difference(r.emptySince) > emptyTtl;
        if (stale) {
          r._dispose();
          Log.d('room', '$id swept (empty > $emptyTtl)');
        }
        return stale;
      });
    });
  }

  void dispose() {
    _sweep?.cancel();
    for (final r in _rooms.values) {
      r._dispose();
    }
    _rooms.clear();
  }
}

class Member {
  Member._(this.id, this.name, this._channel);

  final String id;
  final String name;
  final WebSocketChannel _channel;

  /// False while this member's player cannot play: not initialised yet, or
  /// buffering. The room holds while anyone is not ready.
  bool ready = false;

  Map<String, Object> toJson() => {'id': id, 'name': name, 'ready': ready};
}

class Room {
  Room._(this.id, this.stream, {required this.holdCap});

  final String id;
  final String stream;
  final Duration holdCap;

  bool playing = false;

  /// Seconds into the film at [at].
  double position = 0;

  /// Server time (ms since epoch) [position] was observed. While playing, the
  /// film is at `position + (now - at)`.
  int at = DateTime.now().millisecondsSinceEpoch;

  /// Who last changed the state.
  String? by;

  final Map<String, Member> members = {};
  DateTime emptySince = DateTime.now();

  int _nextMember = 1;
  Timer? _holdTimer;

  /// Members everyone is waiting for. Non-empty means the room is held.
  List<Member> get waiting =>
      members.values.where((m) => !m.ready).toList(growable: false);

  bool get held => members.values.any((m) => !m.ready);

  /// Where the film is now, had nothing changed since [at].
  double positionNow() {
    if (!playing) return position;
    return position + (DateTime.now().millisecondsSinceEpoch - at) / 1000.0;
  }

  Member join(String name, WebSocketChannel channel) {
    final m = Member._('${_nextMember++}', name, channel);
    members[m.id] = m;
    Log.d('room', '$id: ${m.name} joined (${members.length} members)');
    // A newcomer is not ready until its player says so: hold here, with the
    // position frozen, so nobody runs ahead while it loads.
    _freeze();
    _broadcast();
    return m;
  }

  void leave(Member m) {
    if (members.remove(m.id) == null) return;
    Log.d('room', '$id: ${m.name} left (${members.length} members)');
    if (members.isEmpty) emptySince = DateTime.now();
    _afterReadyChange();
    _broadcast();
  }

  void set(Member m, {required bool playing, required double position}) {
    this.playing = playing;
    this.position = position;
    at = DateTime.now().millisecondsSinceEpoch;
    by = m.name;
    Log.d(
      'room',
      '$id: ${m.name} ${playing ? 'play' : 'pause'} @${position.toStringAsFixed(1)}s',
    );
    _broadcast();
  }

  void setReady(Member m, bool ready) {
    if (m.ready == ready) return;
    m.ready = ready;
    Log.d('room', '$id: ${m.name} ${ready ? 'ready' : 'buffering'}');
    if (!ready) {
      _freeze();
    } else {
      _afterReadyChange();
    }
    _broadcast();
  }

  /// Stops the shared clock: [position] becomes where the film is right now,
  /// and `at` is renewed once the hold ends. Starts the hold cap.
  void _freeze() {
    if (!playing) return;
    position = positionNow();
    at = DateTime.now().millisecondsSinceEpoch;
    _holdTimer ??= Timer(holdCap, () {
      _holdTimer = null;
      if (!held) return;
      Log.d('room', '$id: hold cap reached, releasing');
      for (final m in members.values) {
        m.ready = true;
      }
      _release();
      _broadcast();
    });
  }

  void _afterReadyChange() {
    if (held) return;
    _holdTimer?.cancel();
    _holdTimer = null;
    _release();
  }

  /// Restarts the shared clock from the frozen [position].
  void _release() {
    at = DateTime.now().millisecondsSinceEpoch;
  }

  Map<String, Object?> _state(Member recipient) => {
    't': 'state',
    'playing': playing,
    'position': position,
    'at': at,
    'by': by,
    'members': [for (final m in members.values) m.toJson()],
    'waiting': [for (final m in waiting) m.name],
    'you': recipient.id,
  };

  void _broadcast() {
    for (final m in members.values) {
      m._channel.sink.add(jsonEncode(_state(m)));
    }
  }

  void _dispose() {
    _holdTimer?.cancel();
    for (final m in members.values) {
      m._channel.sink.close();
    }
    members.clear();
  }
}
