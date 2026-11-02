import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:travel_core/travel_core.dart';
import 'package:travel_assistant/taxi_dialog.dart';
import 'package:travel_assistant/material_merge_service.dart';
import 'package:travel_assistant/services.dart';
import 'package:travel_assistant/export_service.dart';
import 'package:travel_assistant/association_service.dart';
import 'package:travel_assistant/trip_folder_storage.dart';

Map<String, dynamic> payment(String id,
        {int cents = 3500, String category = 'unknown', String? date}) =>
    {
      'path': 'C:/fixture/$id.jpg',
      'hash': id,
      'name': '$id.jpg',
      'paymentIdentityVersion': 2,
      'imagePixelHash': id,
      'ocr': {
        'category': category,
        if (date != null) 'paymentDate': date,
        'paymentCandidate': {'cents': cents}
      },
    };

class TaxiEngine implements ProcessingClient {
  final Map<String, Map<String, dynamic>> files;
  TaxiEngine(List<Map<String, dynamic>> materials)
      : files = {for (final m in materials) m['path']: m};
  @override
  Future<dynamic> call(String method, Map<String, dynamic> params) async {
    if (method == 'inspect') {
      return jsonDecode(jsonEncode(files[params['path']]!));
    }
    if (method == 'image.identity') {
      return {'paymentIdentityVersion': 2, 'imagePixelHash': params['path']};
    }
    throw StateError(method);
  }
}

Map<String, dynamic> task(List<Map<String, dynamic>> taxis,
        {List<Map<String, dynamic>> payments = const []}) =>
    {
      'id': 'taxi-test',
      'name': '出租车测试',
      'toleranceCents': 100,
      'groups': taxis,
      'unmatchedPayments': payments,
      'unmatchedMaterials': [],
    };

void main() {
  test(
      'optional date matches by amount; supplied date requires same day; does not weaken normal trips',
      () {
    const p = PaymentEvidence(id: 'p', category: 'unknown', cents: 3500);
    const undated =
        ChargeToMatch(id: 't', category: 'local', cents: 3500, paperTaxi: true);
    expect(suggestPayments([undated], [p])['t']!.selected, p);
    final dated = ChargeToMatch(
        id: 't',
        category: 'local',
        cents: 3500,
        paperTaxi: true,
        date: DateTime(2026, 10, 16));
    expect(suggestPayments([dated], [p])['t']!.selected, isNull);
    final same = PaymentEvidence(
        id: 'p', category: 'local', cents: 3500, date: DateTime(2026, 10, 16));
    expect(suggestPayments([dated], [same])['t']!.selected, same);
    expect(
        suggestPayments([
          dated
        ], [
          PaymentEvidence(
              id: 'p',
              category: 'local',
              cents: 3500,
              date: DateTime(2026, 10, 17))
        ])['t']!
            .selected,
        isNull);
    expect(
        suggestPayments(
                [const ChargeToMatch(id: 'd', category: 'local', cents: 3500)],
                [same])['d']!
            .selected,
        isNull);
    expect(
        suggestPayments([
          undated
        ], [
          const PaymentEvidence(id: 'rail', category: 'intercity', cents: 3500)
        ])['t']!
            .selected,
        isNull);
  });
  test(
      'existing screenshot matches; later screenshots also match; unpaired record survives',
      () async {
    final p = payment('p');
    final merger = MaterialMerger(TaxiEngine([p]), 'unused');
    final t = newTaxiRecord(3500, null);
    final empty = await merger.merge(task([t]));
    expect(empty['groups'].single['suggestionComplete'], false);
    expect(() => buildTaskExportManifest(empty), throwsStateError);
    final later = await merger.merge(empty, mailFiles: [p]);
    expect(later['groups'].single['payments'].single['cents'], 3500);
    final manifest = buildTaskExportManifest(later);
    expect(manifest['invoices'].single['paperTaxi'], true);
    expect(manifest['invoices'].single['number'],
        manifest['pictures'].single['number']);
    expect(manifest['grandTotals']['reimbursementCents'], 3500);
    final existing =
        await merger.merge(task([newTaxiRecord(3500, null)], payments: [p]));
    expect(existing['groups'].single['suggestionComplete'], true);
    // 人工关联及复核后的纸票无发票路径，也必须保留且不重复匹配支付。
    existing['groups'].single['confirmed'] = true;
    final again = await merger.merge(existing);
    expect(again['groups'].length, 1);
    expect(again['groups'].single['confirmed'], true);
    expect(again['unmatchedPayments'], isEmpty);
  });
  test(
      'ambiguous screenshots and competing paper tickets require manual selection',
      () async {
    final a = payment('a'), b = payment('b');
    final result = await MaterialMerger(TaxiEngine([a, b]), 'unused')
        .merge(task([newTaxiRecord(3500, null)], payments: [a, b]));
    expect(result['groups'].single['payments'], isEmpty);
    final editor = AssociationEditor(result, 0);
    editor.choose(0, 'a');
    final selected = editor.build();
    expect(selected['groups'].single['suggestionComplete'], true);
    expect(
        buildTaskExportManifest(selected)['grandTotals']['reimbursementCents'],
        3500);
    expect(() => editor.addSlot(), throwsStateError);
    final t1 = newTaxiRecord(3500, null), t2 = newTaxiRecord(3500, null);
    t2['hash'] = 'taxi-second';
    final disputed = await MaterialMerger(TaxiEngine([a]), 'unused')
        .merge(task([t1, t2], payments: [a]));
    expect(
        (disputed['groups'] as List)
            .cast<Map<String, dynamic>>()
            .every((g) => (g['payments'] as List).isEmpty),
        true);
  });
  test('tolerance, discount and reimbursement use actual smaller amount',
      () async {
    final p = payment('p', cents: 3300);
    p['ocr']['discountCandidate'] = {'cents': 200};
    final result = await MaterialMerger(TaxiEngine([p]), 'unused')
        .merge(task([newTaxiRecord(3500, null)], payments: [p]));
    expect(result['groups'].single['suggestionComplete'], true);
    expect(buildTaskExportManifest(result)['grandTotals']['reimbursementCents'],
        3300);
  });
  test(
      'paper records without invoice files persist and reload in independent folder',
      () async {
    final temp = await Directory.systemTemp.createTemp('taxi-storage-');
    try {
      final storage = TripFolderStorage(temp);
      await storage.save(task([newTaxiRecord(3500, DateTime(2026, 10, 16))]));
      final reloaded = (await storage.readAll()).single;
      expect(reloaded['groups'].single['paperTaxi'], true);
      expect(
          reloaded['groups'].single['document']['expenseDate'], '2026-10-16');
      expect(reloaded['groups'].single['invoiceCents'], 3500);
    } finally {
      await temp.delete(recursive: true);
    }
  });
  testWidgets(
      'continuous entry saves once per click, resets fields and retains successful entries after close',
      (tester) async {
    final saved = <int>[];
    await tester.pumpWidget(MaterialApp(
        home: Builder(
            builder: (context) => Scaffold(
                body: TextButton(
                    onPressed: () => showDialog<void>(
                        context: context,
                        builder: (_) => TaxiDialog(commit: (c, d) async {
                              saved.add(c);
                              return '已登记';
                            })),
                    child: const Text('open'))))));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '35');
    await tester.tap(find.text('保存并继续添加'));
    await tester.pumpAndSettle();
    expect(saved, [3500]);
    expect(find.text('第 1 张已保存：已登记'), findsOneWidget);
    await tester.enterText(find.byType(TextField), '0');
    await tester.tap(find.text('保存并完成'));
    await tester.pumpAndSettle();
    expect(saved, [3500]);
    await tester.enterText(find.byType(TextField), '28.50');
    await tester.tap(find.text('保存并完成'));
    await tester.pumpAndSettle();
    expect(saved, [3500, 2850]);
    expect(find.byType(TaxiDialog), findsNothing);
  });
}
