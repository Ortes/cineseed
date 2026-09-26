import 'dart:async';
import 'dart:js_interop';

import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../core/providers.dart';

@JS('requestCastSession')
external void _jsRequestCastSession();

@JS('castHls')
external void _jsCastHls(String url, String title);

@JS('getCastState')
external String _jsGetCastState();

@JS('isCastAvailable')
external bool _jsIsCastAvailable();

/// Cast button for HLS-ready content. Polls Cast state every 2 s.
/// Hidden automatically when no Cast device is on the network or when
/// the browser doesn't support the Cast API (non-Chrome).
class CastButton extends HookConsumerWidget {
  final String hash;

  /// Which file inside the torrent to cast; null = the primary (largest) video.
  final int? fileIndex;

  final String title;
  final Color? color;

  const CastButton({
    super.key,
    required this.hash,
    required this.title,
    this.fileIndex,
    this.color,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final available = useState(false);
    final connected = useState(false);

    void poll() {
      try {
        available.value = _jsIsCastAvailable();
        connected.value = _jsGetCastState() == 'CONNECTED';
      } catch (_) {}
    }

    useEffect(() {
      poll();
      final timer = Timer.periodic(const Duration(seconds: 2), (_) => poll());
      return timer.cancel;
    }, const []);

    void onTap() {
      final url = ref
          .read(apiClientProvider)
          .hlsMasterUrl(hash, fileIndex: fileIndex);
      if (connected.value) {
        try {
          _jsCastHls(url, title);
        } catch (_) {}
      } else {
        try {
          _jsRequestCastSession();
        } catch (_) {}
        Future(() async {
          for (var i = 0; i < 30; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 500));
            try {
              if (_jsGetCastState() == 'CONNECTED') {
                _jsCastHls(url, title);
                return;
              }
            } catch (_) {}
          }
        });
      }
    }

    if (!available.value) return const SizedBox.shrink();
    return IconButton(
      tooltip: connected.value ? 'Cast to device' : 'Cast to TV',
      icon: Icon(
        connected.value ? Icons.cast_connected : Icons.cast,
        color: color,
      ),
      onPressed: onTap,
    );
  }
}
