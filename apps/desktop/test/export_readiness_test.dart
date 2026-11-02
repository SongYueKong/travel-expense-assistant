import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:travel_assistant/export_service.dart';
import 'package:travel_assistant/reconciliation_service.dart';
import 'association_service_test.dart' show invoice, payment, itinerary;

Map<String, dynamic> matched({String category = 'hotel'}) {
  final g = invoice('invoice', category: category);
  g['payments'] = [
    {...payment('a', category: category), 'cents': 9950}
  ];
  g['suggestionComplete'] = true;
  if (category == 'local') {
    final m = itinerary('trip');
    g['itineraries'] = [m['path']];
    g['itineraryMaterials'] = [m];
    g['trips'] = m['document']['trips'];
    g['payments'][0]['tripIndex'] = 1;
    g['matchingPolicy'] = {
      'version': 2,
      'timeMatching': {'rideToleranceMinutes': 15, 'paymentDelayMinutes': 180}
    };
  }
  return g;
}

void main() {
  test(
      'fully matched unreviewed groups export without mutating flags or values',
      () {
    final g = matched(), before = jsonEncode(matched());
    final m = buildExportManifest([g], 100);
    expect(m['grandTotals']['reimbursementCents'], 9950);
    expect(m['reviewedInvoices'], 0);
    expect(m['draft'], isNot(true));
    expect(jsonEncode(g), before);
    g['confirmed'] = true;
    expect(buildExportManifest([g], 100)['grandTotals'], m['grandTotals']);
  });
  test('amounts take minimum within each group rather than after grand totals',
      () {
    final a = matched(), b = matched();
    b['path'] = 'C:/test/second.pdf';
    b['payments'] = [
      {...payment('b'), 'cents': 10050}
    ];
    expect(
        buildExportManifest([a, b], 100)['grandTotals']['reimbursementCents'],
        19950);
  });
  test(
      'old amount-only policy and invalid times require rematch or manual review',
      () {
    for (final time in ['2026-09-01T11:00:00+08:00', null]) {
      final g = matched(category: 'local');
      g.remove('matchingPolicy');
      if (time == null) {
        g['payments'][0]['ocr'].remove('rideDateTime');
      } else {
        g['payments'][0]['ocr']['rideDateTime'] = time;
      }
      expect(() => buildExportManifest([g], 100), throwsStateError);
    }
  });
  test(
      'amount-only policy must be recomputed while manual explicit choice is retained',
      () {
    final g = matched(category: 'local');
    g['matchingPolicy']['version'] = 3;
    expect(() => buildExportManifest([g], 100), throwsStateError);
    g['manuallyAssociated'] = true;
    expect(buildExportManifest([g], 100)['grandTotals']['reimbursementCents'],
        9950);
    g['manuallyAssociated'] = false;
    g['matchingPolicy']['version'] = 4;
    expect(buildExportManifest([g], 100)['grandTotals']['reimbursementCents'],
        9950);
  });
  test('city trips can export without materials-complete or review checkbox',
      () {
    final g = matched(category: 'local');
    expect(assessGroups([g], 100).single.problems, isEmpty);
    expect(buildExportManifest([g], 100)['pictures'][0]['number'], '001');
  });
  test('partial, missing, conflicting or stale city materials cannot export',
      () {
    final mutations = <void Function(Map<String, dynamic>)>[
      (g) => g['itineraries'] = <String>[],
      (g) => g['payments'] = <dynamic>[],
      (g) => g['payments'][0]['tripIndex'] = 2,
      (g) => g['suggestionComplete'] = false,
      (g) => g['itineraryMaterials'][0]['document']['expectedCount'] = 2,
      (g) => g['itineraryMaterials'][0]['document']['complete'] = false,
      (g) => g['trips'] = <dynamic>[],
    ];
    for (final change in mutations) {
      final g = matched(category: 'local');
      change(g);
      expect(() => buildExportManifest([g], 100), throwsStateError);
    }
  });
  test(
      'manual association explicitly overrides timing without requiring review',
      () {
    final g = matched(category: 'local');
    g['manuallyAssociated'] = true;
    g['payments'][0]['ocr']['rideDateTime'] = '2026-10-27T11:00:00+08:00';
    expect(buildExportManifest([g], 100)['grandTotals']['reimbursementCents'],
        9950);
  });
  test(
      'duplicate payments detected by path even if hashes differ or review set',
      () {
    final a = matched(), b = matched();
    b['payments'][0]['hash'] = 'different-hash';
    b['confirmed'] = true;
    expect(() => buildExportManifest([a, b], 100), throwsStateError);
    b['payments'][0]['path'] = 'C:/test/b.png';
    b['payments'][0]['hash'] = 'a';
    expect(() => buildExportManifest([a, b], 100), throwsStateError);
  });
}
