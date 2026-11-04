import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:travel_assistant/export_review.dart';

Map<String, dynamic> manifest(List<String> categories) => {
      'summary': [
        for (final c in categories) {'category': c, 'reimbursementCents': 0}
      ]
    };

void main() {
  test(
      'all presence combinations report missing receipt categories in fixed order',
      () {
    const keys = ['intercity', 'local', 'hotel'];
    const labels = ['城市间交通费', '市内交通费', '住宿费'];
    for (var mask = 0; mask < 8; mask++) {
      final data = manifest([
        for (var i = 0; i < 3; i++)
          if (mask & (1 << i) != 0) keys[i]
      ]);
      expect(missingExpenseCategories(data), [
        for (var i = 0; i < 3; i++)
          if (mask & (1 << i) == 0) labels[i]
      ]);
    }
    final data = manifest(['meal', 'unknown']);
    expect(missingExpenseCategories(data), labels);
    expect(missingExpenseCategories({}), labels);
    expect(
        missingExpenseCategories({
          'summary': [
            {'kind': 'allowance', 'category': 'hotel'}
          ]
        }),
        labels);
  });

  testWidgets('missing categories require explicit return or continue choice',
      (tester) async {
    bool? decision;
    await tester.pumpWidget(MaterialApp(
        home: Builder(
            builder: (context) => Scaffold(
                body: TextButton(
                    onPressed: () async {
                      decision = await confirmExpenseCategories(
                          context, manifest(['intercity']));
                    },
                    child: const Text('导出'))))));
    await tester.tap(find.text('导出'));
    await tester.pumpAndSettle();
    expect(find.text('• 市内交通费'), findsOneWidget);
    expect(find.text('• 住宿费'), findsOneWidget);
    expect(find.text('• 城市间交通费'), findsNothing);
    expect(decision, isNull);
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    await tester.tap(find.text('返回检查'));
    await tester.pumpAndSettle();
    expect(decision, isFalse);
    decision = null;
    await tester.tap(find.text('导出'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('已核验，继续导出'));
    await tester.pumpAndSettle();
    expect(decision, isTrue);
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('complete receipt categories proceed without a dialog',
      (tester) async {
    bool? decision;
    await tester.pumpWidget(MaterialApp(
        home: Builder(
            builder: (context) => Scaffold(
                body: TextButton(
                    onPressed: () async {
                      decision = await confirmExpenseCategories(
                          context, manifest(['intercity', 'local', 'hotel']));
                    },
                    child: const Text('导出'))))));
    await tester.tap(find.text('导出'));
    await tester.pumpAndSettle();
    expect(decision, isTrue);
    expect(find.byType(AlertDialog), findsNothing);
  });
}
