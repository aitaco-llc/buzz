import 'package:buzz/features/age_gate/age_restriction_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('shows the 18+ restriction without a bypass', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: AgeRestrictionPage()));

    expect(find.text('aitaco is for people 18 and older'), findsOneWidget);
    expect(
      find.text("You must be 18 or older to use aitaco under aitaco's Terms."),
      findsOneWidget,
    );
    expect(find.byType(TextButton), findsNothing);
    expect(find.byType(FilledButton), findsNothing);
    expect(find.byType(ElevatedButton), findsNothing);
  });
}
