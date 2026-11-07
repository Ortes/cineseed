import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:web/web.dart' as web;

import '../../core/providers.dart';
import '../../core/theme.dart';
import '../player/stream_actions.dart';
import 'room_client.dart';
import 'room_provider.dart';

/// Name prompt shown before joining a room — to a guest landing on a room
/// link, in place of the player, and to the host in a dialog. [onJoin] gets
/// the trimmed name. The tap doubles as the user gesture browsers need before
/// the player may call play().
class RoomJoinCard extends HookWidget {
  const RoomJoinCard({
    super.key,
    required this.title,
    required this.onJoin,
    this.action = 'Join',
  });

  final String title;
  final String action;
  final ValueChanged<String> onJoin;

  @override
  Widget build(BuildContext context) {
    final controller = useTextEditingController(text: DisplayName.load() ?? '');
    final name = useState(controller.text.trim());
    useEffect(() {
      void sync() => name.value = controller.text.trim();
      controller.addListener(sync);
      return () => controller.removeListener(sync);
    }, [controller]);

    void submit() {
      if (name.value.isEmpty) return;
      onJoin(name.value);
    }

    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 360),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(title, textAlign: TextAlign.center),
          const SizedBox(height: 16),
          TextField(
            key: const ValueKey('room-name'),
            controller: controller,
            autofocus: true,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => submit(),
            decoration: const InputDecoration(labelText: 'Your name'),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            key: const ValueKey('room-join'),
            onPressed: name.value.isEmpty ? null : submit,
            icon: const Icon(Icons.group_rounded),
            label: Text(action),
          ),
        ],
      ),
    );
  }
}

/// AppBar action: makes a room for [stream], joins it as the host and copies
/// the invite link. The current URL gains `?room=<id>` so a reload stays in
/// the room.
class WatchTogetherButton extends ConsumerWidget {
  const WatchTogetherButton({super.key, required this.stream});

  final String stream;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return IconButton(
      key: const ValueKey('watch-together'),
      tooltip: 'Watch together',
      icon: const Icon(Icons.group_add_rounded),
      onPressed: () async {
        final name = await showDialog<String>(
          context: context,
          builder: (ctx) => AlertDialog(
            content: RoomJoinCard(
              title:
                  'Watch together: invite someone to play this in sync '
                  'with you. Anyone in the room can play, pause and seek.',
              action: 'Create room',
              onJoin: (name) => Navigator.of(ctx).pop(name),
            ),
          ),
        );
        if (name == null || !context.mounted) return;
        final messenger = ScaffoldMessenger.of(context);
        final String id;
        try {
          id = await ref.read(apiClientProvider).createRoom(stream);
        } catch (e) {
          messenger.showSnackBar(
            SnackBar(content: Text('Could not create the room: $e')),
          );
          return;
        }
        ref
            .read(roomProvider.notifier)
            .join(id: id, stream: stream, name: name, creator: true);
        final link = Uri.base.replace(
          queryParameters: {...Uri.base.queryParameters, 'room': id},
        );
        web.window.history.replaceState(null, '', link.toString());
        if (!context.mounted) return;
        await copyUrlToClipboard(
          context,
          link.toString(),
          'Invite link copied — send it to whoever you watch with',
          'Send this link to whoever you watch with.',
        );
      },
    );
  }
}

/// Who is in the room. Tapping it copies the invite link again.
class RoomChip extends HookWidget {
  const RoomChip({super.key, required this.room});

  final RoomClient room;

  @override
  Widget build(BuildContext context) {
    final state = useValueListenable(room.state);
    final connected = useValueListenable(room.connected);
    final names = [
      for (final m in state?.members ?? const <RoomMember>[]) m.name,
    ];
    final link = Uri.base.replace(
      queryParameters: {...Uri.base.queryParameters, 'room': room.roomId},
    );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: ActionChip(
        key: const ValueKey('room-chip'),
        avatar: Icon(
          connected ? Icons.group_rounded : Icons.cloud_off_rounded,
          size: 18,
          color: connected
              ? CineseedColors.primaryBright
              : CineseedColors.creamMuted,
        ),
        label: Text(
          names.isEmpty ? 'Room' : names.join(' · '),
          overflow: TextOverflow.ellipsis,
        ),
        tooltip: 'Copy the invite link',
        onPressed: () => copyUrlToClipboard(
          context,
          link.toString(),
          'Invite link copied',
          'Send this link to whoever you watch with.',
        ),
      ),
    );
  }
}

/// "Waiting for Bob…" over the picture while the room is held.
class RoomWaitingBanner extends HookWidget {
  const RoomWaitingBanner({super.key, required this.room});

  final RoomClient room;

  @override
  Widget build(BuildContext context) {
    final state = useValueListenable(room.state);
    final others = [
      for (final m in state?.members ?? const <RoomMember>[])
        if (!m.ready && m.id != state?.you) m.name,
    ];
    if (state == null || !state.held) return const SizedBox.shrink();
    final text = others.isEmpty
        ? 'Loading…'
        : 'Waiting for ${others.join(', ')}…';
    return IgnorePointer(
      child: Align(
        alignment: Alignment.topCenter,
        child: Container(
          key: const ValueKey('room-waiting'),
          margin: const EdgeInsets.only(top: 12),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.7),
            borderRadius: BorderRadius.circular(99),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: 10),
              Text(text, style: const TextStyle(color: Colors.white)),
            ],
          ),
        ),
      ),
    );
  }
}
