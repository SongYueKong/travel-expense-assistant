import 'package:travel_assistant/trip_date_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:travel_assistant/trip_dates.dart';
import 'package:travel_assistant/create_trip_dialog.dart';
import 'package:travel_assistant/task_rules.dart';
import 'mail_dialog_test.dart' show FakeProcessor, openDialog;

void main() {
  test(
      'trip name includes full start and end dates; email starts on trip day and ends next day',
      () {
    final period = TripPeriod(DateTime(2026, 10, 27), DateTime(2026, 10, 29));
    expect(period.taskName(' 北京出差 '), '北京出差（2026-10-27 至 2026-10-29）');
    expect(tripDate(period.mailStart), '2026-10-27');
    expect(tripDate(period.mailEnd), '2026-10-30');
    expect(period.toJson(),
        {'tripStartDate': '2026-10-27', 'tripEndDate': '2026-10-29'});
  });
  test('one-day month-end year-end and leap-day trips use calendar next day',
      () {
    for (final dates in [
      ['2026-10-31', '2026-10-31', '2026-11-01'],
      ['2026-12-31', '2027-01-02', '2027-01-03'],
      ['2028-02-28', '2028-02-28', '2028-02-29'],
      ['2028-02-29', '2028-02-29', '2028-03-01'],
      ['2100-12-31', '2100-12-31', '2101-01-01']
    ]) {
      final period =
          TripPeriod(DateTime.parse(dates[0]), DateTime.parse(dates[1]));
      expect(tripDate(period.mailEnd), dates[2]);
    }
    expect(TripPeriod.today(DateTime.utc(2026, 10, 30, 18)).toJson(),
        {'tripStartDate': '2026-10-31', 'tripEndDate': '2026-10-31'});
  });
  test(
      'invalid reversed partial dates are rejected and old undated tasks remain supported',
      () {
    expect(() => TripPeriod(DateTime(2026, 10, 30), DateTime(2026, 10, 29)),
        throwsFormatException);
    for (final task in [
      {},
      {'tripStartDate': '2026-10-27'},
      {'tripStartDate': '2026-02-30', 'tripEndDate': '2026-03-01'},
      {'tripStartDate': '2026-10-30', 'tripEndDate': '2026-10-29'}
    ]) {
      expect(TripPeriod.fromTask(Map<String, dynamic>.from(task)), isNull);
    }
    final task = {
      'id': 'dated',
      'name': '北京出差',
      'groups': [],
      ...TripPeriod(DateTime(2026, 10, 27), DateTime(2026, 10, 29)).toJson()
    };
    expect(TripPeriod.fromTask(duplicateTask(task, '副本'))!.label,
        '2026-10-27 至 2026-10-29');
  });
  testWidgets(
      'new trip previews date suffix and saves chosen period without overwriting base name',
      (tester) async {
    Map<String, dynamic>? received;
    await tester.pumpWidget(MaterialApp(
        home: Builder(
            builder: (context) => Scaffold(
                body: TextButton(
                    onPressed: () async {
                      received = await showDialog<Map<String, dynamic>>(
                          context: context,
                          builder: (_) => CreateTripDialog(
                              initialPeriod: TripPeriod(DateTime(2026, 10, 27),
                                  DateTime(2026, 10, 29)),
                              commit: (base, period) async => {
                                    'name': period.taskName(base),
                                    ...period.toJson()
                                  }));
                    },
                    child: const Text('新建'))))));
    await tester.tap(find.text('新建'));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const ValueKey('task-name-input')), '北京出差');
    await tester.pumpAndSettle();
    expect(find.text('任务名称预览：北京出差（2026-10-27 至 2026-10-29）'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('trip-date-range')));
    await tester.pumpAndSettle();
    final picker = tester.widget<TripDatePicker>(find.byType(TripDatePicker));
    expect(tripDate(picker.initialDateRange.start), '2026-10-27');
    Navigator.of(tester.element(find.byType(TripDatePicker))).pop(DateTimeRange(
        start: DateTime(2026, 12, 31), end: DateTime(2027, 1, 2)));
    await tester.pumpAndSettle();
    expect(find.text('任务名称预览：北京出差（2026-12-31 至 2027-01-02）'), findsOneWidget);
    await tester.tap(find.text('创建并从邮箱导入'));
    await tester.pumpAndSettle();
    expect(received, {
      'name': '北京出差（2026-12-31 至 2027-01-02）',
      'tripStartDate': '2026-12-31',
      'tripEndDate': '2027-01-02'
    });
    expect(tester.takeException(), isNull);
  });
  testWidgets(
      'email range initially follows trip period and remains manually adjustable',
      (tester) async {
    final engine = FakeProcessor();
    await openDialog(tester, engine, (_) {},
        previous: {'provider': 'qq', 'account': 'test@qq.com'},
        tripPeriod: TripPeriod(DateTime(2026, 12, 31), DateTime(2027, 1, 2)));
    expect(find.text('接收日期：2026-12-31 至 2027-01-03（北京时间）'), findsOneWidget);
    await tester.ensureVisible(find.text('接收日期：2026-12-31 至 2027-01-03（北京时间）'));
    await tester.tap(find.text('接收日期：2026-12-31 至 2027-01-03（北京时间）'));
    await tester.pumpAndSettle();
    Navigator.of(tester.element(find.byType(DateRangePickerDialog))).pop(
        DateTimeRange(
            start: DateTime(2026, 12, 30), end: DateTime(2027, 1, 5)));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).at(1), 'TEST-CODE');
    await tester.ensureVisible(find.text('获取并导入'));
    await tester.tap(find.text('获取并导入'));
    await tester.pumpAndSettle();
    final request =
        engine.calls.singleWhere((c) => c['method'] == 'mail.start')['params'];
    expect(request['start_date'], '2026-12-30');
    expect(request['end_date'], '2027-01-05');
    expect(tester.takeException(), isNull);
  });
}
