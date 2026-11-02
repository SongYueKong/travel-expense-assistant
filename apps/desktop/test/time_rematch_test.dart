import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:travel_assistant/material_merge_service.dart';
import 'package:travel_assistant/services.dart';
import 'export_readiness_test.dart' show matched;

class Inspection implements ProcessingClient {
  int calls = 0;
  final Map<String, dynamic> materials;
  Inspection(this.materials);
  @override
  Future<dynamic> call(String method, Map<String, dynamic> params) async {
    calls++;
    return jsonDecode(jsonEncode(materials[params['path']]));
  }
}

Map<String, dynamic> task() {
  final g = matched(category: 'local');
  g['document'].addAll({'type': 'invoice', 'category': 'local'});
  g['manuallyAssociated'] = true;
  g['payments'][0]['manualPaymentCents'] = 9950;
  return {
    'id': 'test',
    'name': '独立测试',
    'toleranceCents': 100,
    'groups': [g],
    'unmatchedMaterials': [],
    'unmatchedPayments': [],
    'timeMatching': {'rideToleranceMinutes': 15, 'paymentDelayMinutes': 180}
  };
}

Inspection inspector(Map<String, dynamic> source) {
  final g = source['groups'][0],
      p = g['payments'][0],
      m = g['itineraryMaterials'][0];
  return Inspection({
    g['path']: {
      'path': g['path'],
      'name': 'invoice.pdf',
      'hash': 'invoice',
      'document': g['document']
    },
    m['path']: m,
    p['path']: {
      'path': p['path'],
      'name': 'a.png',
      'hash': 'a',
      'ocr': p['ocr']
    }
  });
}

void main() {
  test(
      'time overrides survive explicit rematch and original OCR remains available',
      () async {
    final source = task();
    source['groups'][0]['payments'][0]['timeOverrides'] = {
      'rideDateTime': '2026-10-27 09:55:00',
      'paymentDateTime': null
    };
    final result = await MaterialMerger(inspector(source), 'unused')
        .merge(source, recalculateManual: true);
    final p = result['groups'][0]['payments'][0];
    expect(p['timeOverrides'],
        source['groups'][0]['payments'][0]['timeOverrides']);
    expect(p['ocr']['rideDateTime'], '2026-10-27T10:00:00+08:00');
    expect(p['cents'], 9950);
  });
  test('rematch preserves manual choices by default and isolates source',
      () async {
    final source = task(),
        before = jsonEncode(task()),
        client = inspector(task());
    final result = await MaterialMerger(client, 'unused').merge(source);
    expect(client.calls, 0);
    expect(result['groups'][0]['manuallyAssociated'], isTrue);
    result['groups'][0]['payments'][0]['cents'] = 1;
    expect(jsonEncode(source), before);
  });
  test('rematch rejects a unique amount when ride date is days away', () async {
    final source = task();
    source['groups'][0]['payments'][0]['ocr']['rideDateTime'] =
        '2026-09-01T10:00:00+08:00';
    final result = await MaterialMerger(inspector(source), 'unused')
        .merge(source, recalculateManual: true);
    expect(result['groups'][0]['suggestionComplete'], isFalse);
    expect(result['groups'][0]['payments'], isEmpty);
    expect(result['groups'][0]['matchingPolicy']['mode'], 'dateTimeAndAmount');
    expect(source['groups'][0]['manuallyAssociated'], isTrue);
  });
  test(
      'explicit rematch retains corrected net amount and applies time settings',
      () async {
    final source = task(),
        before = jsonEncode(task()),
        client = inspector(task());
    source['timeMatching']['rideToleranceMinutes'] = 0;
    final result = await MaterialMerger(client, 'unused')
        .merge(source, recalculateManual: true);
    final g = result['groups'][0];
    expect(client.calls, 3);
    expect(g['payments'][0]['cents'], 9950);
    expect(g['payments'][0]['manualPaymentCents'], 9950);
    expect(g['matchingPolicy']['timeMatching']['rideToleranceMinutes'], 0);
    expect(g['confirmed'], isFalse);
    expect(g['suggestionComplete'], isTrue);
    source['timeMatching']['rideToleranceMinutes'] = 15;
    expect(jsonEncode(source), before);
  });
  test('reviewed or manually entered groups remain protected even with opt-in',
      () async {
    for (final flag in ['confirmed', 'manuallyEntered']) {
      final source = task();
      source['groups'][0][flag] = true;
      final client = inspector(source);
      final result = await MaterialMerger(client, 'unused')
          .merge(source, recalculateManual: true);
      expect(client.calls, 0);
      expect(result['groups'][0][flag], isTrue);
    }
  });
}
