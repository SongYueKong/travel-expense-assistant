import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:travel_assistant/association_service.dart';
import 'association_service_test.dart'
    show fixture, invoice, payment, itinerary;
import 'association_dialog_test.dart' show openEditor;

MaterialRecord candidate(String id,
    {int cents = 10000, String? ride = '10:00', String? paid}) {
  final m = payment(id, cents: cents, category: 'local');
  m['ocr']['platform'] = 'didi';
  if (ride == null) {
    m['ocr'].remove('rideDateTime');
  } else {
    m['ocr']['rideDateTime'] = '2026-10-27T$ride:00+08:00';
  }
  if (paid != null) m['ocr']['paymentDateTime'] = paid;
  return m;
}

MaterialRecord sortTask(List<MaterialRecord> payments,
    {bool twoTrips = false}) {
  final task = fixture(),
      g = invoice('local', category: 'local'),
      m = itinerary('sort');
  g['document']['platform'] = 'didi';
  m['document']['platform'] = 'didi';
  if (twoTrips) {
    m['document']['trips'].add(
        {'index': 2, 'date': '2026-10-27', 'time': '11:00', 'cents': 10050});
  }
  g['invoiceCents'] = twoTrips ? 20050 : 10000;
  m['document']['totalCents'] = g['invoiceCents'];
  g['itineraries'] = [m['path']];
  g['itineraryMaterials'] = [m];
  g['trips'] = m['document']['trips'];
  task['groups'] = [g];
  task['unmatchedPayments'] = payments;
  return task;
}

List<String> ordered(AssociationEditor editor) =>
    editor.sortedCandidates(0, editor.payments.keys);

void main() {
  test(
      'absolute amount difference precedes time; positive and negative differences are symmetric',
      () {
    final editor = AssociationEditor(
        sortTask([
          candidate('under', cents: 9950, ride: '09:59'),
          candidate('over', cents: 10050),
          candidate('closest-price', cents: 9990, ride: '10:14'),
          candidate('exact', ride: '10:10')
        ]),
        0);
    expect(ordered(editor), ['exact', 'closest-price', 'over', 'under']);
    expect(editor.selected, [null]);
  });
  test(
      'unknown times follow known times and unknown amounts follow known amounts; ties are stable',
      () {
    final unknown = candidate('unknown-money')
      ..['ocr'].remove('paymentCandidate');
    final a = candidate('a')..['name'] = 'same.png',
        b = candidate('b')..['name'] = 'same.png';
    final editor = AssociationEditor(
        sortTask([unknown, candidate('unknown-time', ride: null), b, a]), 0);
    expect(ordered(editor), ['a', 'b', 'unknown-time', 'unknown-money']);
    expect(editor.sortedCandidates(0, editor.payments.keys.toList().reversed),
        ordered(editor));
  });
  test(
      'corrected timestamps and net amounts determine ranking without modifying source data',
      () {
    final source = sortTask(
            [candidate('a', ride: '10:01'), candidate('b', ride: '10:05')]),
        before = jsonEncode(source);
    final editor = AssociationEditor(source, 0);
    expect(ordered(editor), ['a', 'b']);
    editor.correctPaymentTimes(
        'a', {'rideDateTime': '2026-10-27 10:12:00', 'paymentDateTime': null});
    expect(ordered(editor), ['b', 'a']);
    editor.payments['b']!['manualPaymentCents'] = 10001;
    expect(ordered(editor), ['a', 'b']);
    expect(jsonEncode(source), before);
  });
  test(
      'payment-only timestamps cross midnight; ride timestamp is used when present',
      () {
    final task = sortTask([
      candidate('paid', ride: null, paid: '2026-10-28T00:10:00+08:00'),
      candidate('ride', ride: '23:55', paid: '2026-10-28T01:00:00+08:00')
    ]);
    task['groups'][0]['trips'][0]['time'] = '23:50';
    final editor = AssociationEditor(task, 0);
    expect(ordered(editor), ['ride', 'paid']);
    expect(editor.candidateTimeDifferenceSeconds('paid', 0), 1200);
  });
  test(
      'hotel and intercity compare calendar dates including corrected payment date',
      () {
    for (final category in ['hotel', 'intercity']) {
      final task = fixture();
      task['groups'] = [invoice('invoice', category: category)];
      task['unmatchedPayments'] = [
        candidate('later', paid: '2026-10-28T00:00:00+08:00'),
        candidate('same-day', paid: '2026-10-27T23:59:00+08:00'),
        candidate('earlier', paid: '2026-10-26T23:55:00+08:00')
      ];
      final editor = AssociationEditor(task, 0);
      expect(ordered(editor), ['same-day', 'earlier', 'later']);
      expect(editor.candidateTimeDifferenceSeconds('same-day', 0), 0);
      editor.correctPaymentTimes('later',
          {'rideDateTime': null, 'paymentDateTime': '2026-10-27 22:00:00'});
      expect(ordered(editor), ['later', 'same-day', 'earlier']);
    }
  });
  testWidgets(
      'candidate cards follow amount and time order even with focused material and after trip change',
      (tester) async {
    final a = candidate('a-larger', cents: 10050),
        b = candidate('b-later', ride: '10:10'),
        c = candidate('c-nearer', ride: '10:01');
    final task = sortTask([a, b, c], twoTrips: true),
        before = jsonEncode(sortTask([a, b, c], twoTrips: true));
    await openEditor(tester, task, (_) {}, focus: a);
    List<String> cardOrder() => find
        .byWidgetPredicate((w) =>
            w.key is ValueKey<String> &&
            (w.key as ValueKey<String>).value.startsWith('choose-'))
        .evaluate()
        .map((e) => (e.widget.key as ValueKey<String>).value.substring(7))
        .toList();
    expect(cardOrder(), ['c-nearer', 'b-later', 'a-larger']);
    expect(find.text('排序：金额差绝对值优先，其次时间差；未知差值靠后。'), findsOneWidget);
    await tester.ensureVisible(find.byType(DropdownButtonFormField<int>));
    await tester.tap(find.byType(DropdownButtonFormField<int>));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('行程 2 ·').last);
    await tester.pumpAndSettle();
    expect(cardOrder(), ['a-larger', 'b-later', 'c-nearer']);
    expect(jsonEncode(task), before);
    expect(tester.takeException(), isNull);
  });
}
