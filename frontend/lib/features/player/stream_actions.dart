import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/providers.dart';

/// Actions that resolve a backend URL for ONE file and hand it to the user.
/// [fileIndex] names the file inside a multi-file torrent (null = the primary,
/// largest video); the library acts on whole torrents, the file picker on a
/// chosen episode.

/// Resolves the stream URL (presigned S3 when complete, local growing-file
/// route otherwise) and copies it. The user pastes it into VLC ▸ File ▸ Open
/// Network — VLC tolerates both modes (HEVC, Dolby, growing files).
Future<void> copyStreamUrl(
  BuildContext context,
  WidgetRef ref,
  String hash, {
  int? fileIndex,
}) async {
  final messenger = ScaffoldMessenger.of(context);
  String url;
  try {
    url = await ref
        .read(apiClientProvider)
        .streamUrl(hash, fileIndex: fileIndex);
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text('Could not get URL: $e')));
    return;
  }
  if (!context.mounted) return;
  await copyUrlToClipboard(
    context,
    url,
    'Stream URL copied — paste into VLC ▸ Open Network',
    'Tap Copy, then paste into VLC ▸ Open Network.',
  );
}

/// Resolves the download URL (presigned S3 sent with `Content-Disposition:
/// attachment`) and hands it to the platform via `url_launcher`. The URL's
/// `attachment` disposition makes the browser save the file rather than
/// navigate to it — no new tab, no copy/paste.
Future<void> downloadFile(
  BuildContext context,
  WidgetRef ref,
  String hash, {
  int? fileIndex,
}) async {
  final messenger = ScaffoldMessenger.of(context);
  String url;
  try {
    url = await ref
        .read(apiClientProvider)
        .downloadUrl(hash, fileIndex: fileIndex);
  } catch (e) {
    messenger.showSnackBar(
      SnackBar(content: Text('Could not start download: $e')),
    );
    return;
  }
  final ok = await launchUrl(Uri.parse(url), webOnlyWindowName: '_self');
  if (!context.mounted) return;
  messenger.showSnackBar(
    SnackBar(
      content: Text(ok ? 'Download started' : 'Could not start download'),
    ),
  );
}

/// Copies [url] to the clipboard and shows [successMessage].
///
/// On Flutter web the async URL fetch happens before this call, so the browser
/// may reject the write (lost user-gesture context → "Clipboard is not
/// available in the context"). When that happens we fall back to a dialog with
/// the URL in a SelectableText and a Copy button that fires inside a fresh
/// gesture; [dialogHint] is the instruction shown above it.
Future<void> copyUrlToClipboard(
  BuildContext context,
  String url,
  String successMessage,
  String dialogHint,
) async {
  final messenger = ScaffoldMessenger.of(context);
  try {
    await Clipboard.setData(ClipboardData(text: url));
    messenger.showSnackBar(SnackBar(content: Text(successMessage)));
  } catch (_) {
    if (!context.mounted) return;
    await _showCopyUrlDialog(context, url, dialogHint);
  }
}

Future<void> _showCopyUrlDialog(BuildContext context, String url, String hint) {
  final messenger = ScaffoldMessenger.of(context);
  return showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('URL'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(hint),
          const SizedBox(height: 12),
          SelectableText(url, maxLines: 4),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: const Text('Close'),
        ),
        FilledButton.icon(
          icon: const Icon(Icons.content_copy),
          label: const Text('Copy'),
          onPressed: () async {
            try {
              await Clipboard.setData(ClipboardData(text: url));
              if (ctx.mounted) Navigator.of(ctx).pop();
              messenger.showSnackBar(const SnackBar(content: Text('Copied')));
            } catch (e) {
              messenger.showSnackBar(
                SnackBar(content: Text('Copy failed: $e — select manually')),
              );
            }
          },
        ),
      ],
    ),
  );
}
