import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:travel_core/travel_core.dart';
import 'package:travel_assistant/matching_helpers.dart';
import 'package:travel_assistant/payment_time_dialog.dart';
import 'package:travel_assistant/association_service.dart';
import 'association_service_test.dart' show fixture, invoice;

Map<String, dynamic> screenshot() => {
      'hash': 'a',
      'name': '22元支付截图',
      'path': 'C:/test/a.jpg',
      'cents': 2200,
      'ocr': {
        'category': 'local',
        'platform': 'didi',
        'paymentCandidate': {'cents': 2200},
        'rideDateTime': '2026-10-28T15:42:50+08:00',
        'paymentDateTime': '2026-10-28T14:07:52+08:00'
      }
    };
final trip = ChargeToMatch(
    id: 'trip2',
    category: 'local',
    platform: 'didi',
    cents: 2200,
    startedAt: beijingTimestamp('2026-10-28 13:48:00'));
const corrected = {
  'rideDateTime': '2026-10-28 13:42:50',
  'paymentDateTime': '2026-10-28 14:07:52'
};

PaymentTiming assessWithTestWindow(
        ChargeToMatch charge, PaymentEvidence payment) =>
    assessPaymentTiming(charge, payment,
        settings: const TimeMatchSettings(
            rideToleranceMinutes: 15, paymentDelayMinutes: 180));
void main() {
  test(
      'misread 15:42 is outside ride window; verified 13:42 is 5 min 10 sec away',
      () {
    final raw = screenshot(), before = jsonEncode(screenshot());
    final bad = assessWithTestWindow(trip, paymentEvidence(raw));
    expect(bad.eligible, isFalse);
    expect(bad.distanceSeconds, 6890);
    expect(bad.reason, contains('超过时间范围'));
    final fixed = withPaymentTimes(raw, corrected);
    final good = assessWithTestWindow(trip, paymentEvidence(fixed));
    expect(good.eligible, isTrue);
    expect(good.distanceSeconds, 310);
    expect(
        suggestPayments([trip], [paymentEvidence(fixed)])['trip2']!
            .selected!
            .id,
        'a');
    expect(fixed['ocr']['rideDateTime'], '2026-10-28T15:42:50+08:00');
    expect(fixed['cents'], 2200);
    expect(jsonEncode(raw), before);
    expect(
        assessWithTestWindow(
                trip, paymentEvidence(withPaymentTimes(fixed, null)))
            .eligible,
        isFalse);
  });
  test('invalid dates are rejected but ride after payment is allowed', () {
    expect(
        () => withPaymentTimes(screenshot(),
            {'rideDateTime': '2026-02-30 12:00:00', 'paymentDateTime': null}),
        throwsFormatException);
    final values = {
      'rideDateTime': '2026-10-28 15:42:50',
      'paymentDateTime': '2026-10-28 14:07:52'
    };
    expect(withPaymentTimes(screenshot(), values)['timeOverrides'], values);
  });
  test(
      'saving time correction preserves payment amount and selected trip; source is isolated',
      () {
    final task = fixture(), g = invoice('local', category: 'local');
    g['invoiceCents'] = 2200;
    g['document']['platform'] = 'didi';
    g['trips'] = [
      {'index': 2, 'date': '2026-10-28', 'time': '13:48', 'cents': 2200}
    ];
    g['itineraries'] = ['C:/test/trip.pdf'];
    g['payments'] = [
      {...screenshot(), 'tripIndex': 2}
    ];
    g['manuallyAssociated'] = true;
    task['groups'] = [g];
    task['unmatchedPayments'] = [];
    final before = jsonEncode(task), editor = AssociationEditor(task, 0);
    editor.correctPaymentTimes('a', corrected);
    final saved = editor.build()['groups'][0]['payments'].single;
    expect(saved['tripIndex'], 2);
    expect(saved['cents'], 2200);
    expect(saved['timeOverrides'], corrected);
    expect(jsonEncode(task), before);
  });
  testWidgets('time dialog validates dates and allows ride after payment',
      (tester) async {
    PaymentTimeChange? result;
    await tester.pumpWidget(MaterialApp(
        home: Builder(
            builder: (context) => Scaffold(
                body: TextButton(
                    onPressed: () async {
                      result = await showDialog<PaymentTimeChange>(
                          context: context,
                          builder: (_) =>
                              PaymentTimeDialog(material: screenshot()));
                    },
                    child: const Text('纠正'))))));
    await tester.tap(find.text('纠正'));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const ValueKey('correct-ride-time')), '2026-02-30 12:00:00');
    await tester.tap(find.text('应用到核对草稿'));
    await tester.pumpAndSettle();
    expect(result, isNull);
    expect(find.textContaining('时间格式无效'), findsOneWidget);
    await tester.enterText(
        find.byKey(const ValueKey('correct-ride-time')), '2026-10-28 15:42:50');
    await tester.tap(find.text('应用到核对草稿'));
    await tester.pumpAndSettle();
    expect(result!.values, {
      'rideDateTime': '2026-10-28 15:42:50',
      'paymentDateTime': '2026-10-28 14:07:52'
    });
    expect(tester.takeException(), isNull);
  });
}
