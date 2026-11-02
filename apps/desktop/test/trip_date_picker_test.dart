import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:travel_assistant/trip_date_picker.dart';
import 'package:travel_assistant/app_localizations.dart';

Future<void> openPicker(WidgetTester tester,
    {DateTimeRange? initial, ValueChanged<DateTimeRange?>? onResult}) async {
  await tester.pumpWidget(MaterialApp(
      locale: appLocale,
      supportedLocales: appSupportedLocales,
      localizationsDelegates: appLocalizationDelegates,
      home: Builder(
          builder: (context) => Scaffold(
              body: TextButton(
                  onPressed: () async {
                    final result = await showDialog<DateTimeRange>(
                        context: context,
                        builder: (_) => TripDatePicker(
                            today: DateTime(2026, 11, 2),
                            initialDateRange: initial ??
                                DateTimeRange(
                                    start: DateTime(2026, 11, 2),
                                    end: DateTime(2026, 11, 2))));
                    onResult?.call(result);
                  },
                  child: const Text('打开'))))));
  await tester.tap(find.text('打开'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
      'recent view opens previous and current months with strong year/month labels',
      (tester) async {
    await openPicker(tester);
    expect(find.text('2026年10月'), findsOneWidget);
    expect(find.text('2026年11月'), findsOneWidget);
    expect(find.text('2026年12月'), findsNothing);
    final title = tester.widget<Text>(find.text('2026年10月'));
    expect(title.style!.fontWeight, FontWeight.w700);
    expect(title.style!.fontSize, greaterThanOrEqualTo(20));
    expect(tester.takeException(), isNull);
  });
  testWidgets(
      'cross month selection returns exact inclusive range and requires end selection',
      (tester) async {
    DateTimeRange? result;
    await openPicker(tester, onResult: (r) => result = r);
    await tester.tap(find.byKey(const ValueKey('trip-day-2026-10-30')));
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '确定'))
            .onPressed,
        isNull);
    await tester.tap(find.byKey(const ValueKey('trip-day-2026-11-02')));
    await tester.pumpAndSettle();
    expect(find.textContaining('共 4 天'), findsOneWidget);
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
    expect(result!.start, DateTime.utc(2026, 10, 30));
    expect(result!.end, DateTime.utc(2026, 11, 2));
  });
  testWidgets(
      'older dates are retained and month navigation crosses year then returns to current',
      (tester) async {
    await openPicker(tester,
        initial: DateTimeRange(
            start: DateTime(2025, 12, 31), end: DateTime(2026, 1, 2)));
    expect(find.text('2025年12月'), findsOneWidget);
    expect(find.text('2026年1月'), findsOneWidget);
    await tester.tap(find.byTooltip('前一个月'));
    await tester.pumpAndSettle();
    expect(find.text('2025年11月'), findsOneWidget);
    await tester.tap(find.text('回到本月'));
    await tester.pumpAndSettle();
    expect(find.text('2026年11月'), findsOneWidget);
    expect(find.textContaining('开始：2025-12-31'), findsOneWidget);
    await tester.tap(find.byTooltip('后一个月'));
    await tester.pumpAndSettle();
    expect(find.text('2026年12月'), findsOneWidget);
  });
  testWidgets('same-day trips and cancellation are supported', (tester) async {
    DateTimeRange? result;
    await openPicker(tester, onResult: (r) => result = r);
    final day = find.byKey(const ValueKey('trip-day-2026-10-29'));
    await tester.tap(day);
    await tester.pumpAndSettle();
    await tester.tap(day);
    await tester.pumpAndSettle();
    expect(find.textContaining('共 1 天'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(result, isNull);
  });
  testWidgets('manual entry validates dates and supports leap day',
      (tester) async {
    DateTimeRange? result;
    await openPicker(tester, onResult: (r) => result = r);
    final element = tester.element(find.byType(TripDatePicker));
    await tester.tap(find
        .byTooltip(MaterialLocalizations.of(element).inputDateModeButtonLabel));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, '2026-02-30');
    await tester.enterText(find.byType(TextField).last, '2026-03-01');
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
    expect(find.textContaining('请输入有效的起止日期'), findsOneWidget);
    await tester.enterText(find.byType(TextField).first, '2028-02-29');
    await tester.enterText(find.byType(TextField).last, '2028-03-01');
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
    expect(result!.start, DateTime.utc(2028, 2, 29));
    expect(result!.end, DateTime.utc(2028, 3, 1));
  });
  testWidgets(
      'supported date bounds keep both visible months inside allowed years',
      (tester) async {
    await openPicker(tester,
        initial: DateTimeRange(start: DateTime(2000), end: DateTime(2000)));
    expect(find.text('2000年1月'), findsOneWidget);
    expect(find.text('2000年2月'), findsOneWidget);
    expect(
        tester
            .widget<IconButton>(
                find.byKey(const ValueKey('trip-month-previous')))
            .onPressed,
        isNull);
  });
}
