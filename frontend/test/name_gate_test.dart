import 'package:cineseed/core/visitor.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('Continue enables once a name is typed', (t) async {
    await t.pumpWidget(const MaterialApp(home: NameGate(child: Text('in'))));
    FilledButton btn() => t.widget<FilledButton>(find.byType(FilledButton));
    expect(btn().onPressed, isNull);
    await t.enterText(find.byType(TextField), 'Bob');
    await t.pump();
    expect(btn().onPressed, isNotNull);
  });
}
