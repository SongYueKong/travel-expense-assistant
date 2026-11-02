import 'package:flutter_test/flutter_test.dart';
import 'package:travel_core/travel_core.dart';
import 'package:travel_assistant/export_service.dart';
import 'package:travel_assistant/matching_helpers.dart';
import 'package:travel_assistant/reconciliation_service.dart';
import 'package:travel_assistant/association_service.dart';
import 'package:travel_assistant/material_merge_service.dart';
import 'time_rematch_test.dart' as rematch;
import 'export_readiness_test.dart' show matched;

void main() {
  test(
      'coupon beyond tolerance is applied through material reimport and trip linking',
      () async {
    final source = rematch.task();
    final p = source['groups'][0]['payments'][0];
    p['cents'] = 9650;
    p['manualPaymentCents'] = 9650;
    p['ocr']['discountCandidate'] = {'cents': 350};
    final result = await MaterialMerger(rematch.inspector(source), 'unused')
        .merge(source, recalculateManual: true);
    expect(result['groups'][0]['suggestionComplete'], isTrue);
    expect(result['groups'][0]['payments'].single['tripIndex'], 1);
    expect(
        buildExportManifest(
            (result['groups'] as List).cast<Map<String, dynamic>>(),
            100)['grandTotals']['reimbursementCents'],
        9650);
  });
  final charge = ChargeToMatch(
      id: 'c', category: 'hotel', cents: 10000, date: DateTime(2026, 10, 27));
  PaymentEvidence p(String id, int cents, int discount) => PaymentEvidence(
      id: id,
      category: 'hotel',
      cents: cents,
      discountCents: discount,
      date: DateTime(2026, 10, 27));
  test(
      'exact coupon difference is accepted beyond tolerance and mismatch is not widened',
      () {
    final s = suggestPayments([charge], [p('a', 9650, 350)],
        toleranceCents: 100)['c']!;
    expect(s.selected?.id, 'a');
    expect(s.reason, contains('优惠 3.50'));
    for (final payment in [
      p('a', 9650, 349),
      p('a', 9650, 0),
      p('a', 10350, 350),
      p('a', 9650, -350)
    ]) {
      expect(suggestPayments([charge], [payment])['c']!.selected, isNull);
    }
  });
  test('exact discount cannot bypass date or ride-time filters', () {
    expect(
        suggestPayments([
          charge
        ], [
          PaymentEvidence(
              id: 'p',
              category: 'hotel',
              cents: 9650,
              discountCents: 350,
              date: DateTime(2025, 1, 1))
        ])['c']!
            .selected,
        isNull);
    final trip = ChargeToMatch(
        id: 't',
        category: 'local',
        cents: 10000,
        startedAt: DateTime.utc(2026, 10, 27, 2));
    expect(
        suggestPayments([
          trip
        ], [
          PaymentEvidence(
              id: 'p',
              category: 'local',
              cents: 9650,
              discountCents: 350,
              rideAt: DateTime.utc(2026, 10, 28, 2))
        ])['t']!
            .selected,
        isNull);
  });
  test('coupon matches still respect ties and competing expenses', () {
    expect(
        suggestPayments([charge], [p('a', 9650, 350), p('b', 9650, 350)])['c']!
            .selected,
        isNull);
    expect(
        suggestPayments([
          charge,
          ChargeToMatch(
              id: 'b',
              category: 'hotel',
              cents: 10000,
              date: DateTime(2026, 10, 27))
        ], [
          p('a', 9650, 350)
        ]).values.every((s) => s.selected == null),
        isTrue);
  });
  test(
      'coupon evidence survives candidate ranking and export stays actual paid amount',
      () {
    final g = matched();
    g['payments'][0]['cents'] = 9650;
    g['payments'][0]['ocr']
        ['discountCandidate'] = {'cents': 350, 'sources': []};
    expect(paymentEvidence(g['payments'][0]).discountCents, 350);
    expect(groupDiscountExplains(g), isTrue);
    final task = {
      'name': '折扣测试',
      'toleranceCents': 100,
      'groups': [g],
      'unmatchedPayments': [],
      'unmatchedMaterials': []
    };
    final e = AssociationEditor(task, 0);
    expect(e.recommended('a', 0), isTrue);
    expect(buildExportManifest([g], 100)['grandTotals']['reimbursementCents'],
        9650);
    expect(g['payments'][0]['cents'], 9650);
  });
}
