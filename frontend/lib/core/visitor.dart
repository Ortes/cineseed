import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:web/web.dart' as web;

/// The visitor's name, asked once and kept in this browser. The backend logs
/// it with every film added, downloaded or watched.
abstract final class Visitor {
  static const _key = 'cineseed.name';

  static String? get name {
    final v = web.window.localStorage.getItem(_key)?.trim();
    return v == null || v.isEmpty ? null : v;
  }

  static set name(String? v) => web.window.localStorage.setItem(_key, v ?? '');
}

/// Shows [child] once the visitor has given a name; until then, only a form
/// asking for it.
class NameGate extends HookWidget {
  const NameGate({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final name = useState(Visitor.name);
    if (name.value != null) return child;

    // Above the router's Navigator: the text field needs an Overlay of its own.
    // The entry's builder only runs for what it creates, so the form is its own
    // widget: one built here would keep its first (disabled) button forever.
    return Overlay(
      initialEntries: [
        OverlayEntry(
          builder: (_) => _NameForm(
            onSubmit: (v) {
              Visitor.name = v;
              name.value = v;
            },
          ),
        ),
      ],
    );
  }
}

class _NameForm extends HookWidget {
  const _NameForm({required this.onSubmit});

  final ValueChanged<String> onSubmit;

  @override
  Widget build(BuildContext context) {
    final field = useTextEditingController();
    useListenable(field);

    void submit() {
      final v = field.text.trim();
      if (v.isNotEmpty) onSubmit(v);
    }

    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Who are you?',
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: field,
                  autofocus: true,
                  decoration: const InputDecoration(labelText: 'Your name'),
                  onSubmitted: (_) => submit(),
                ),
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: field.text.trim().isEmpty ? null : submit,
                  child: const Text('Continue'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
