import 'package:travel_assistant/trip_date_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:travel_assistant/app_localizations.dart';
import 'package:travel_assistant/create_trip_dialog.dart';
import 'package:travel_assistant/trip_settings_dialog.dart';
import 'package:travel_assistant/trip_dates.dart';
import 'package:travel_assistant/mail_dialog.dart';
import 'mail_dialog_test.dart' show FakeProcessor;

void main() {
  for (final entry in ['new', 'settings', 'mail']) {
    testWidgets('$entry calendar uses Chinese months weekdays and input labels',
        (tester) async {
      tester.view.physicalSize = const Size(1440, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final period = TripPeriod(DateTime(2026, 10, 27), DateTime(2026, 10, 29));
      final task = {'name': '北京出差', ...period.toJson()};
      final dialog = switch (entry) {
        'new' => CreateTripDialog(
            initialPeriod: period, commit: (name, dates) async => {}),
        'settings' =>
          TripSettingsDialog(task: task, commit: (change) async => task),
        _ => MailImportDialog(engine: FakeProcessor(), tripPeriod: period),
      };
      await tester.pumpWidget(MaterialApp(
          locale: appLocale,
          supportedLocales: appSupportedLocales,
          localizationsDelegates: appLocalizationDelegates,
          home: Builder(
              builder: (context) => Scaffold(
                  body: TextButton(
                      onPressed: () =>
                          showDialog(context: context, builder: (_) => dialog),
                      child: const Text('打开'))))));
      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();
      final button = entry == 'new'
          ? find.byKey(const ValueKey('trip-date-range'))
          : entry == 'settings'
              ? find.byKey(const ValueKey('trip-settings-dates'))
              : find.text('接收日期：2026-10-27 至 2026-10-30（北京时间）');
      await tester.ensureVisible(button);
      await tester.tap(button);
      await tester.pumpAndSettle();
      final element = tester.element(entry == 'mail'
          ? find.byType(DateRangePickerDialog)
          : find.byType(TripDatePicker));
      final localizations = MaterialLocalizations.of(element);
      expect(Localizations.localeOf(element), appLocale);
      expect(localizations.narrowWeekdays, ['日', '一', '二', '三', '四', '五', '六']);
      expect(localizations.formatMonthYear(DateTime(2026, 10)), '2026年10月');
      expect(find.text('2026年10月'), findsWidgets);
      expect(
          find.textContaining(RegExp(
              r'\b(Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec|Mon|Tue|Wed|Thu|Fri|Sat|Sun)\b',
              caseSensitive: false)),
          findsNothing);
      await tester.tap(find.byTooltip(localizations.inputDateModeButtonLabel));
      await tester.pumpAndSettle();
      expect(find.text(localizations.dateRangeStartLabel), findsOneWidget);
      expect(find.text(localizations.dateRangeEndLabel), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
