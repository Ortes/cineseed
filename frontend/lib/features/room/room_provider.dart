import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:web/web.dart' as web;

import '../../core/providers.dart';
import 'room_client.dart';

/// The room this browser is in, if any. One at a time: joining another, or
/// leaving the player, drops the current connection.
final roomProvider = NotifierProvider<RoomSession, RoomClient?>(
  RoomSession.new,
);

class RoomSession extends Notifier<RoomClient?> {
  @override
  RoomClient? build() {
    ref.onDispose(() => state?.dispose());
    return null;
  }

  /// Connects to room [id] playing [stream] as [name]. Replaces any current
  /// room.
  void join({
    required String id,
    required String stream,
    required String name,
    bool creator = false,
  }) {
    final current = state;
    if (current != null &&
        current.roomId == id &&
        current.stream == stream &&
        current.name == name) {
      return;
    }
    current?.dispose();
    DisplayName.save(name);
    state = RoomClient(
      url: ref.read(apiClientProvider).roomSocketUrl(id),
      roomId: id,
      stream: stream,
      name: name,
      creator: creator,
    );
  }

  void leave() {
    state?.dispose();
    state = null;
  }
}

/// The name shown to the others in a room, remembered in this browser.
abstract final class DisplayName {
  static const _key = 'cineseed.name';

  static String? load() => web.window.localStorage.getItem(_key);

  static void save(String name) => web.window.localStorage.setItem(_key, name);
}
