import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:travel_core/travel_core.dart';
import 'package:travel_assistant/time_matching_dialog.dart';

void main() {
  testWidgets(
      'settings validate ranges and return custom windows with manual opt-in',
      (tester) async {
    TimeRematchRequest? result;
    await tester.pumpWidget(MaterialApp(
        home: Builder(
            builder: (context) => Scaffold(
                body: TextButton(
                    onPressed: () async {
                      result = await showDialog<TimeRematchRequest>(
                          context: context,
                          builder: (_) => const TimeMatchingDialog(
                              settings: TimeMatchSettings()));
                    },
                    child: const Text('打开'))))));
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsNWidgets(2));
    expect(
        tester.widget<TextField>(find.byType(TextField).first).controller!.text,
        '150');
    expect(
        tester.widget<TextField>(find.byType(TextField).last).controller!.text,
        '150');
    await tester.enterText(find.byType(TextField).first, '-1');
    await tester.tap(find.text('重新匹配'));
    await tester.pumpAndSettle();
    expect(result, isNull);
    expect(find.textContaining('时间范围无效'), findsOneWidget);
    await tester.enterText(find.byType(TextField).first, '20');
    await tester.enterText(find.byType(TextField).last, '240');
    await tester.ensureVisible(find.byType(CheckboxListTile));
    await tester.tap(find.byType(CheckboxListTile));
    await tester.pumpAndSettle();
    await tester.tap(find.text('重新匹配'));
    await tester.pumpAndSettle();
    expect(result!.settings.rideToleranceMinutes, 20);
    expect(result!.settings.paymentDelayMinutes, 240);
    expect(result!.includeManual, isTrue);
    expect(tester.takeException(), isNull);
  });
}
