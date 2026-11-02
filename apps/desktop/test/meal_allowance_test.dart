import 'package:travel_assistant/trip_date_picker.dart';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:travel_assistant/meal_allowance.dart';
import 'package:travel_assistant/trip_dates.dart';
import 'package:travel_assistant/trip_settings_dialog.dart';
import 'package:travel_assistant/export_service.dart';
import 'export_readiness_test.dart' show matched;

Map<String, dynamic> mealTask() => {
      'name': '北京出差',
      'groups': <dynamic>[],
      'toleranceCents': 100,
      ...TripPeriod(DateTime(2026, 12, 31), DateTime(2027, 1, 2)).toJson()
    };
void main() {
  test(
      'inclusive days cover same day leap day and year boundaries with exact cents',
      () {
    for (final (start, end, days) in [
      ('2026-10-31', '2026-10-31', 1),
      ('2028-02-28', '2028-03-01', 3),
      ('2026-12-31', '2027-01-02', 3)
    ]) {
      final task = {
        ...mealTask(),
        ...TripPeriod(DateTime.parse(start), DateTime.parse(end)).toJson()
      };
      expect(MealAllowance.fromTask(task).amountCents, days * 10000);
      task['mealDailyRateCents'] = 12345;
      expect(MealAllowance.fromTask(task).amountCents, days * 12345);
    }
    expect(MealAllowance.fromTask({'name': '旧任务'}).amountCents, 0);
    expect(
        MealAllowance.fromTask({...mealTask(), 'mealAllowanceEnabled': false})
            .included,
        isFalse);
    expect(
        MealAllowance.fromTask({...mealTask(), 'mealDailyRateCents': -1}).error,
        isNotNull);
  });
  test(
      'settings replace known date suffix preserve receipt data and isolate source',
      () {
    final task = mealTask();
    task['name'] = '北京（2026-12-31 至 2027-01-02）（副本）';
    task['groups'] = [matched()];
    final before = jsonEncode(task);
    final updated = applyTripSettings(task,
        baseName: tripBaseName(task),
        period: TripPeriod(DateTime(2027, 1, 5), DateTime(2027, 1, 5)),
        dailyRateCents: 8000,
        mealEnabled: true);
    expect(updated['name'], '北京（副本）（2027-01-05 至 2027-01-05）');
    expect(updated['groups'], task['groups']);
    updated['groups'][0]['invoiceCents'] = 1;
    expect(jsonEncode(task), before);
  });
  test(
      'export adds meal after individual receipt minima without fake attachments or numbering',
      () {
    final task = mealTask();
    task['groups'] = [matched()];
    final before = jsonEncode(task);
    final manifest = buildTaskExportManifest(task);
    expect(manifest['grandTotals'], {
      'invoiceCents': 10000,
      'paymentCents': 9950,
      'reimbursementCents': 39950
    });
    expect(manifest['invoices'].single['number'], '001');
    expect(manifest['pictures'].single['number'], '001');
    expect(manifest['summary'].last['days'], 3);
    expect(manifest['summary'].last['dailyRateCents'], 10000);
    expect(jsonEncode(task), before);
  });
  test(
      'meal alone exports but incomplete receipts and invalid enabled meal still block',
      () {
    final task = mealTask();
    expect(buildTaskExportManifest(task)['grandTotals']['reimbursementCents'],
        30000);
    task['groups'] = [matched()];
    task['groups'][0]['payments'] = <dynamic>[];
    expect(() => buildTaskExportManifest(task), throwsStateError);
    task['groups'] = <dynamic>[];
    task['tripEndDate'] = 'bad';
    task['mealAllowanceEnabled'] = true;
    expect(() => buildTaskExportManifest(task), throwsStateError);
    expect(() => buildTaskExportManifest({'groups': [], 'toleranceCents': 100}),
        throwsStateError);
    final free = {...mealTask(), 'mealDailyRateCents': 0};
    expect(
        buildTaskExportManifest(free)['grandTotals']['reimbursementCents'], 0);
  });
  testWidgets('settings edit dates rate and name and save one validated change',
      (tester) async {
    final source = mealTask();
    source['name'] = '北京出差（2026-12-31 至 2027-01-02）';
    Map<String, dynamic>? saved;
    await tester.pumpWidget(MaterialApp(
        home: Builder(
            builder: (context) => Scaffold(
                body: TextButton(
                    child: const Text('设置'),
                    onPressed: () => showDialog(
                        context: context,
                        builder: (_) => TripSettingsDialog(
                            task: source,
                            commit: (change) async {
                              saved = applyTripSettings(source,
                                  baseName: change.baseName,
                                  period: change.period,
                                  dailyRateCents: change.dailyRateCents,
                                  mealEnabled: change.mealEnabled);
                              return saved!;
                            })))))));
    await tester.tap(find.text('设置'));
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('trip-settings-name')))
            .controller!
            .text,
        '北京出差');
    await tester.tap(find.byKey(const ValueKey('trip-settings-dates')));
    await tester.pumpAndSettle();
    Navigator.of(tester.element(find.byType(TripDatePicker))).pop(
        DateTimeRange(start: DateTime(2027, 2, 28), end: DateTime(2027, 3, 2)));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const ValueKey('meal-daily-rate')), '80.50');
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('3 天（含首尾日） × 80.50 元／天 = 241.50 元'));
    expect(find.text('3 天（含首尾日） × 80.50 元／天 = 241.50 元'), findsOneWidget);
    await tester.tap(find.text('保存设置'));
    await tester.pumpAndSettle();
    expect(saved!['name'], '北京出差（2027-02-28 至 2027-03-02）');
    expect(MealAllowance.fromTask(saved!).amountCents, 24150);
    expect(tester.takeException(), isNull);
  });
}
