import 'package:cineseed/core/providers.dart';
import 'package:cineseed/main.dart';
import 'package:cineseed_shared/cineseed_shared.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('App builds', (tester) async {
    // The library polls the backend from its first frame; a widget test must
    // not hit the network (it left a pending timer that failed the test).
    await tester.pumpWidget(ProviderScope(
      overrides: [
        libraryProvider
            .overrideWith((ref) => Stream.value(const <TorrentState>[])),
      ],
      child: const CineseedApp(),
    ));
    expect(find.byType(MaterialApp), findsOneWidget);
  });
}
