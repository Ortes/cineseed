import 'dart:js_interop';

import 'package:flutter/material.dart';
import 'package:web/web.dart' as web;

import '../../core/api_client.dart';

/// Shows why the tracker returned no results: its message, then the page it
/// served (e.g. C411's "Incident en cours"), rendered in a fully sandboxed
/// iframe — no scripts, no same-origin access.
class TrackerErrorView extends StatelessWidget {
  const TrackerErrorView({super.key, required this.error});

  final TrackerError error;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            error.message,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
          const SizedBox(height: 12),
          Expanded(
            child: HtmlElementView.fromTagName(
              tagName: 'iframe',
              onElementCreated: (e) {
                final iframe = e as web.HTMLIFrameElement;
                iframe.setAttribute('sandbox', '');
                iframe.style
                  ..border = 'none'
                  ..width = '100%'
                  ..height = '100%';
                iframe.srcdoc = error.body.toJS;
              },
            ),
          ),
        ],
      ),
    );
  }
}
