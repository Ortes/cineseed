import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_web_plugins/url_strategy.dart';
import 'package:go_router/go_router.dart';

import 'core/api_client.dart';
import 'core/debug_log.dart';
import 'core/providers.dart';
import 'core/theme.dart';
import 'router.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  usePathUrlStrategy();
  GoRouter.optionURLReflectsImperativeAPIs = true;

  await _resolveDebugMode();

  runApp(const ProviderScope(child: CineseedApp()));
}

/// Decides whether verbose logging is on for this page-load. Two sources:
///  - `?debug=1` in the URL — a client-only override (instant, no server needed).
///  - the backend's `GET /api/config` `debugMode` — mirrors the server's
///    `CINESEED_DEBUG` so one server switch drives both halves.
/// When on, sets [DebugLog.enabled] and a `window` flag the `video_player_web_hls`
/// fork reads to log hls.js fragment/stall/error events with the same prefix.
Future<void> _resolveDebugMode() async {
  var enabled = Uri.base.queryParameters['debug'] == '1';
  if (!enabled) {
    try {
      enabled = await ApiClient(apiBase).fetchDebugMode();
    } catch (_) {
      // No /api/config (old backend) or unreachable → debug stays off. This is
      // an optional config read, not a masked playback error.
    }
  }
  if (enabled) {
    DebugLog.enabled = true;
    // Signal the player fork (decoupled via a JS global so no fork symbol needs
    // importing here; harmless on a fork build that doesn't read it).
    globalContext.setProperty('__cineseedHlsVerbose'.toJS, true.toJS);
    DebugLog.log('PLAYER', 'verbose debug mode ON');
  }
}

class CineseedApp extends StatelessWidget {
  const CineseedApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp.router(
    title: 'Cineseed',
    debugShowCheckedModeBanner: false,
    theme: buildCineseedTheme(),
    routerConfig: router,
  );
}
