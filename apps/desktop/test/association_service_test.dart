import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:travel_assistant/association_service.dart';
import 'package:travel_assistant/export_service.dart';
import 'package:travel_assistant/material_merge_service.dart';
import 'package:travel_assistant/services.dart';

MaterialRecord payment(String id,
        {int cents = 10000,
        String category = 'hotel',
        String rideTime = '10:00'}) =>
    {
      'hash': id,
      'name': '$id.png',
      'path': 'C:/test/$id.png',
      'ocr': {
        'payeeName': '测试酒店有限公司',
        'paymentCandidate': {'cents': cents},
        'category': category,
        'platform': 'hotel',
        'paymentDate': '2026-10-27',
        'rideDateTime': '2026-10-27T$rideTime:00+08:00'
      }
    };

MaterialRecord invoice(String id, {String category = 'hotel'}) => {
      'hash': id,
      'name': '$id.pdf',
      'path': 'C:/test/$id.pdf',
      'invoiceCents': 10000,
      'category': category,
      'document': {
        'sellerName': '测试酒店有限公司',
        'number': id,
        'totalCents': 10000,
        'platform': 'hotel',
        'expenseDate': '2026-10-27'
      },
      'payments': <MaterialRecord>[],
      'itineraries': <String>[],
      'trips': <MaterialRecord>[],
      'suggestionComplete': false,
      'confirmed': false,
      'complete': false,
    };

MaterialRecord fixture() => {
      'id': 'test',
      'name': '候选测试',
      'toleranceCents': 100,
      'groups': [invoice('one'), invoice('two')],
      'unmatchedPayments': [payment('a'), payment('b', cents: 10050)],
      'unmatchedMaterials': <MaterialRecord>[],
    };

MaterialRecord itinerary(String id, {int index = 1, bool complete = true}) => {
      'path': 'C:/test/$id.pdf',
      'hash': id,
      'name': '$id.pdf',
      'document': {
        'type': 'itinerary',
        'platform': 'hotel',
        'totalCents': 10000,
        'complete': complete,
        'trips': [
          {
            'index': index,
            'date': '2026-10-27',
            'time': '10:00',
            'cents': 10000
          }
        ]
      }
    };

class NoInspection implements ProcessingClient {
  @override
  Future<dynamic> call(String method, MaterialRecord params) async =>
      throw StateError('人工关联材料不应重新识别');
}

MaterialRecord completeTripDocument() => {
      'type': 'itinerary',
      'platform': 'didi',
      'totalCents': 9339,
      'expectedCount': 2,
      'complete': true,
      'trips': [
        {'index': 1, 'date': '2026-10-27', 'time': '15:21', 'cents': 4710},
        {'index': 2, 'date': '2026-10-29', 'time': '18:56', 'cents': 4629},
      ],
    };

MaterialRecord incompleteTripTask() {
  final task = fixture(), g = invoice('local', category: 'local');
  final document = completeTripDocument();
  document['trips'] = [document['trips'][0]];
  document['complete'] = false;
  final m = {
    'path': 'C:/test/itinerary.pdf',
    'hash': 'itinerary',
    'name': '行程单B.pdf',
    'document': document
  };
  final a = payment('a', cents: 4710, category: 'local');
  a['ocr']['platform'] = 'didi';
  g['invoiceCents'] = 9339;
  g['document']['totalCents'] = 9339;
  g['document']['platform'] = 'didi';
  g['itineraries'] = [m['path']];
  g['itineraryMaterials'] = [m];
  g['trips'] = document['trips'];
  g['payments'] = [
    {...a, 'cents': 4700, 'tripIndex': 1}
  ];
  final b = payment('b', cents: 4629, category: 'local');
  b['ocr']['platform'] = 'didi';
  b['ocr']['paymentDate'] = '2026-10-29';
  task['groups'] = [g];
  task['unmatchedPayments'] = [b];
  return task;
}

void main() {
  test(
      'refreshing missing itinerary row preserves corrected payment and adds an empty slot',
      () {
    final source = incompleteTripTask(),
        before = jsonEncode(incompleteTripTask());
    final e = AssociationEditor(source, 0);
    e.amounts[0] = 4699;
    e.refreshItinerary(completeTripDocument(), text: '两笔完整行程');
    expect(e.selected, ['a', null]);
    expect(e.amounts, [4699, null]);
    expect(e.trips.length, 2);
    expect(e.selectionComplete, isFalse);
    e.choose(1, 'b');
    final result = e.build();
    expect(result['groups'][0]['suggestionComplete'], isTrue);
    expect(result['groups'][0]['confirmed'], isFalse);
    expect(result['groups'][0]['complete'], isFalse);
    expect(
        result['groups'][0]['itineraryMaterials'][0]['document']['trips']
            .length,
        2);
    expect(records(result['groups'][0]['payments']).map((p) => p['tripIndex']),
        [1, 2]);
    expect(jsonEncode(source), before);
  });

  test('refresh does not move an old payment to a changed trip', () {
    final e = AssociationEditor(incompleteTripTask(), 0);
    final fresh = completeTripDocument();
    fresh['trips'][0]['time'] = '16:00';
    e.refreshItinerary(fresh);
    expect(e.selected, [null, null]);
    final result = e.build();
    expect(
        records(result['unmatchedPayments']).map(evidenceKey), contains('a'));
    expect(result['groups'][0]['suggestionComplete'], isFalse);
  });

  test(
      'failed row count, duplicate index or inconsistent total leaves draft intact',
      () {
    final e = AssociationEditor(incompleteTripTask(), 0);
    final before = jsonEncode(e.task);
    final badTotal = completeTripDocument()..['totalCents'] = 9340;
    final badRows = completeTripDocument();
    badRows['trips'] = [badRows['trips'][0]];
    final duplicates = completeTripDocument();
    duplicates['trips'][1]['index'] = 1;
    for (final doc in [badTotal, badRows, duplicates]) {
      expect(() => e.refreshItinerary(doc), throwsStateError);
      expect(jsonEncode(e.task), before);
      expect(e.selected, ['a']);
      expect(e.amounts, [4700]);
    }
  });
  test('ambiguous candidates are individually selectable; source is isolated',
      () {
    final source = fixture(), before = jsonEncode(fixture());
    final e = AssociationEditor(source, 0);
    expect(e.recommended('a', 0), isTrue);
    expect(e.recommended('b', 0), isTrue);
    e.choose(0, 'b');
    final result = e.build(), g = records(result['groups']).first;
    expect(records(g['payments']).single['hash'], 'b');
    expect(g['suggestionComplete'], isTrue);
    expect(g['manuallyAssociated'], isTrue);
    expect(g['confirmed'], isFalse);
    expect(g['complete'], isFalse);
    expect(records(result['unmatchedPayments']).single['hash'], 'a');
    expect(jsonEncode(source), before);
    expect(() => buildExportManifest(records(result['groups']), 100),
        throwsStateError);
  });

  test(
      'saving corrections clears confirmation and reimbursement still takes minimum',
      () {
    final source = fixture();
    source['groups'] = [invoice('one')];
    source['groups'][0]['complete'] = true;
    source['groups'][0]['confirmed'] = true;
    final e = AssociationEditor(source, 0)..choose(0, 'a');
    e.amounts[0] = 9950;
    final g = records(e.build()['groups']).single;
    expect(g['confirmed'], isFalse);
    expect(g['complete'], isFalse);
    g['complete'] = true;
    g['confirmed'] = true;
    expect(buildExportManifest([g], 100)['grandTotals']['reimbursementCents'],
        9950);
  });

  test('occupied payments cannot be stolen, including unconfirmed groups', () {
    final source = fixture();
    source['groups'][1]['payments'] = [
      {...payment('a'), 'cents': 10000}
    ];
    final e = AssociationEditor(source, 0);
    expect(e.occupied('a', 0), contains('002'));
    expect(() => e.choose(0, 'a'), throwsStateError);
    expect(records(source['groups'][1]['payments']).single['hash'], 'a');
  });

  test(
      'changing a previously corrected net amount back to OCR value updates override',
      () {
    final source = fixture();
    source['groups'] = [invoice('one')];
    var e = AssociationEditor(source, 0)..choose(0, 'a');
    e.amounts[0] = 9950;
    e = AssociationEditor(e.build(), 0);
    e.amounts[0] = 10000;
    final g = e.build()['groups'][0];
    expect(g['payments'][0]['manualPaymentCents'], 10000);
    expect(buildExportManifest([g], 100)['grandTotals']['reimbursementCents'],
        10000);
  });

  test('clearing a selection releases payment for another group', () {
    var source = fixture();
    var e = AssociationEditor(source, 0)..choose(0, 'a');
    source = e.build();
    e = AssociationEditor(source, 0)..choose(0, null);
    source = e.build();
    expect(
        records(source['unmatchedPayments']).map(evidenceKey), contains('a'));
    expect(source['groups'][0]['suggestionComplete'], isFalse);
    e = AssociationEditor(source, 1)..choose(0, 'a');
    expect(records(e.build()['groups'][1]['payments']).single['hash'], 'a');
  });

  test('same payment cannot be used in two slots, even if draft is tampered',
      () {
    final e = AssociationEditor(fixture(), 0)
      ..choose(0, 'a')
      ..addSlot();
    expect(() => e.choose(1, 'a'), throwsStateError);
    e.selected[1] = 'a';
    e.amounts[1] = 10000;
    expect(e.build, throwsStateError);
  });

  test('unknown OCR can be manually allocated but requires positive amount',
      () {
    final source = fixture();
    source['unmatchedMaterials'] = [
      {'path': 'C:/test/unknown.png', 'hash': 'unknown', 'name': 'unknown.png'}
    ];
    final e = AssociationEditor(source, 0)..choose(0, 'unknown');
    expect(e.recommended('unknown', 0), isFalse);
    expect(e.build, throwsStateError);
    e.amounts[0] = 0;
    expect(e.build, throwsStateError);
    e.amounts[0] = 9999;
    final result = e.build();
    expect(records(result['groups'][0]['payments']).single['cents'], 9999);
    expect(records(result['unmatchedMaterials']), isEmpty);
  });

  test(
      'local trips preserve actual indices, reject duplicates and permit partial save',
      () {
    final source = fixture();
    source['groups'][0] = invoice('local', category: 'local');
    final m = itinerary('itinerary', index: 4);
    m['document']['trips'].add(
        {'index': 8, 'date': '2026-10-27', 'time': '11:00', 'cents': 10050});
    source['unmatchedMaterials'] = [m];
    source['unmatchedPayments'] = [
      payment('a', category: 'local'),
      payment('b', cents: 10050, category: 'local')
    ];
    final e = AssociationEditor(source, 0);
    e.selectItinerary(e.itineraries.keys.single);
    expect(e.selected.length, 2);
    e.choose(0, 'a');
    expect(e.selectionComplete, isFalse);
    expect(e.build()['groups'][0]['suggestionComplete'], isFalse);
    expect(() => e.choose(1, 'a'), throwsStateError);
    e.choose(1, 'b');
    final g = e.build()['groups'][0];
    expect(g['suggestionComplete'], isTrue);
    expect(records(g['payments']).map((p) => p['tripIndex']), [4, 8]);
  });

  test(
      'switching itinerary clears former trip allocations and releases evidence',
      () {
    final source = fixture();
    source['groups'][0] = invoice('local', category: 'local');
    source['unmatchedMaterials'] = [itinerary('first'), itinerary('second')];
    final e = AssociationEditor(source, 0);
    final keys = e.itineraries.keys.toList();
    e.selectItinerary(keys[0]);
    e.choose(0, 'a');
    e.selectItinerary(keys[1]);
    expect(e.selected.single, isNull);
    final result = e.build();
    expect(
        records(result['unmatchedPayments']).map(evidenceKey), contains('a'));
    expect(records(result['unmatchedMaterials']).map((m) => m['hash']),
        contains('first'));
  });

  test(
      'incomplete itinerary cannot enable confirmation even with payment selected',
      () {
    final source = fixture();
    source['groups'][0] = invoice('local', category: 'local');
    source['unmatchedMaterials'] = [itinerary('partial', complete: false)];
    final e = AssociationEditor(source, 0);
    e.selectItinerary(e.itineraries.keys.single);
    e.choose(0, 'a');
    expect(e.build()['groups'][0]['suggestionComplete'], isFalse);
  });

  test(
      'deleting group makes its payment and itinerary available without duplicates',
      () {
    final source = fixture();
    source['groups'][0] = invoice('local', category: 'local');
    source['unmatchedMaterials'] = [itinerary('released')];
    final e = AssociationEditor(source, 0);
    e.selectItinerary(e.itineraries.keys.single);
    e.choose(0, 'a');
    final result = removeAssociationGroup(e.build(), 0);
    expect(records(result['groups']).length, 1);
    expect(records(result['unmatchedPayments']).map(evidenceKey).toSet(),
        {'a', 'b'});
    expect(records(result['unmatchedMaterials']).single['hash'], 'released');
  });

  test('itinerary assigned to another invoice cannot be selected', () {
    final source = fixture();
    source['groups'][0] = invoice('local', category: 'local');
    source['groups'][1]['itineraries'] = ['C:/test/occupied.pdf'];
    source['unmatchedMaterials'] = [itinerary('occupied')];
    final e = AssociationEditor(source, 0);
    expect(
        () => e.selectItinerary(e.itineraries.keys.single), throwsStateError);
    expect(e.group['itineraries'], isEmpty);
  });

  test('manual associations survive later material merge before confirmation',
      () async {
    final source = fixture();
    source['groups'] = [invoice('one')];
    source['unmatchedPayments'] = [payment('a')];
    final e = AssociationEditor(source, 0)..choose(0, 'a');
    final result =
        await MaterialMerger(NoInspection(), 'unused').merge(e.build());
    final g = records(result['groups']).single;
    expect(records(g['payments']).single['hash'], 'a');
    expect(g['confirmed'], isFalse);
    expect(g['manuallyAssociated'], isTrue);
  });
}
