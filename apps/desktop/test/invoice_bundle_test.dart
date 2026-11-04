import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:travel_assistant/invoice_bundle.dart';
import 'package:travel_assistant/pdf_catalog.dart';
import 'package:travel_assistant/pending_service.dart';
import 'package:travel_assistant/invoice_bundle_dialog.dart';
import 'package:travel_assistant/association_service.dart';
import 'package:travel_assistant/export_service.dart';
import 'package:travel_assistant/reconciliation_service.dart';
import 'package:travel_assistant/material_merge_service.dart';
import 'package:travel_assistant/trip_folder_storage.dart';
import 'association_service_test.dart' show invoice, payment, NoInspection;

Map<String, dynamic> fixture() {
  final a = invoice('fee-a', category: 'intercity'),
      b = invoice('fee-b', category: 'intercity');
  for (final pair in [(a, 500), (b, 1200)]) {
    pair.$1['invoiceCents'] = pair.$2;
    pair.$1['document'] = {
      ...pair.$1['document'],
      'type': 'invoice',
      'platform': 'rail',
      'totalCents': pair.$2
    };
  }
  final p = payment('pay', category: 'intercity', cents: 1700);
  p['ocr']['platform'] = 'rail';
  return {
    'id': 'bundle-fixture-01',
    'name': '共同支付测试',
    'createdAt': '2026-11-04T10:00:00',
    'toleranceCents': 100,
    'groups': [a, b],
    'unmatchedPayments': [p],
    'unmatchedMaterials': <dynamic>[]
  };
}

Map<String, dynamic> selectedTask([int paid = 1700]) {
  final task = fixture();
  task['unmatchedPayments'][0]['ocr']['paymentCandidate']['cents'] = paid;
  final bundled = combineInvoiceGroups(task, {0, 1}, primary: 0);
  final editor = AssociationEditor(bundled, 0);
  editor.choose(0, 'pay');
  return editor.build();
}

void main() {
  test(
      'multiple invoices compare against one actual payment and export only once',
      () {
    final source = fixture(), before = jsonEncode(source);
    final bundled = combineInvoiceGroups(source, {0, 1}, primary: 0);
    expect(jsonEncode(source), before);
    final editor = AssociationEditor(bundled, 0);
    expect(editor.charge(0).cents, 1700);
    expect(editor.recommended('pay', 0), isTrue);
    editor.choose(0, 'pay');
    final task = editor.build();
    expect(assessGroups(records(task['groups']), 100).single.ready, isTrue);
    final manifest = buildTaskExportManifest(task);
    expect(manifest['invoices'].map((i) => i['number']).toList(),
        ['001-01', '001-02']);
    expect(manifest['pictures'].length, 1);
    expect(manifest['pictures'].single['relatedInvoiceNumbers'],
        ['001-01', '001-02']);
    expect(manifest['summary'].length, 2);
    expect(manifest['grandTotals'], {
      'invoiceCents': 1700,
      'paymentCents': 1700,
      'reimbursementCents': 1700
    });
  });

  test(
      'group minimum and integer allocation do not multiply or lose paid cents',
      () {
    for (final amount in [1699, 1700, 1701]) {
      final manifest = buildTaskExportManifest(selectedTask(amount));
      expect(manifest['grandTotals']['paymentCents'], amount);
      expect(manifest['grandTotals']['reimbursementCents'],
          amount < 1700 ? amount : 1700);
    }
    expect(allocateBundleAmount(100, [1, 1, 1]), [34, 33, 33]);
    expect(allocateBundleAmount(100, [0, 100]), [0, 100]);
  });

  test('PDF catalog and pending list retain every original invoice', () {
    final task = fixture();
    task['unmatchedMaterials'] = [task['groups'][1]];
    final bundled =
        cleanPending(combineInvoiceGroups(task, {0, 1}, primary: 1));
    expect(bundled['unmatchedMaterials'], isEmpty);
    final catalog = buildPdfCatalog(bundled);
    expect(catalog.length, 2);
    expect(catalog.map((e) => e.material['document']['totalCents']).toSet(),
        {500, 1200});
    final third = invoice('fee-c', category: 'intercity');
    third['invoiceCents'] = 300;
    bundled['groups'].add(third);
    final extended = combineInvoiceGroups(bundled, {0, 1}, primary: 1);
    expect(invoiceMembers(records(extended['groups']).single).length, 3);
    expect(extended['groups'][0]['invoiceCents'], 2000);
    expect(splitInvoiceGroup(extended, 0)['groups'].length, 3);
  });

  test('companion itinerary remains assigned inside a combined invoice', () {
    final task = fixture();
    final companion = {
      'path': '/synthetic/travel.pdf',
      'name': 'travel.pdf',
      'hash': 'companion',
      'document': {'type': 'itinerary', 'complete': true, 'trips': <dynamic>[]}
    };
    task['groups'][1]['itineraries'] = [companion['path']];
    task['groups'][1]['itineraryMaterials'] = [companion];
    task['unmatchedMaterials'] = [companion];
    final combined =
        cleanPending(combineInvoiceGroups(task, {0, 1}, primary: 0));
    expect(combined['unmatchedMaterials'], isEmpty);
    expect(buildPdfCatalog(combined).where((e) => e.kind == 'itinerary').length,
        1);
    final editor = AssociationEditor(combined, 0)..choose(0, 'pay');
    final saved = editor.build();
    expect(saved['unmatchedMaterials'], isEmpty);
    expect(buildTaskExportManifest(saved)['invoices'][1]['itineraries'],
        [companion['path']]);
  });

  test('split restores two invoice records and releases the payment once', () {
    final task = selectedTask();
    final split = splitInvoiceGroup(task, 0);
    expect(records(split['groups']).map((g) => g['invoiceCents']), [500, 1200]);
    expect(
        records(split['groups']).every((g) => records(g['payments']).isEmpty),
        isTrue);
    expect(split['unmatchedPayments'].length, 1);
    expect(() => buildTaskExportManifest(split), throwsStateError);
    expect(isInvoiceBundle(records(task['groups']).single), isTrue);
  });

  test('duplicate invoice and payment evidence cannot bypass validation', () {
    final task = selectedTask();
    final duplicate = Map<String, dynamic>.from(
        invoiceMembers(records(task['groups']).single).first);
    task['groups'].add(duplicate);
    expect(assessGroups(records(task['groups']), 100).first.ready, isFalse);
    expect(() => buildTaskExportManifest(task), throwsStateError);
    final bad = selectedTask();
    bad['groups'][0]['invoiceCents'] = 1701;
    expect(() => buildTaskExportManifest(bad), throwsStateError);
    final original = fixture();
    original['groups'][1]['category'] = 'hotel';
    expect(() => combineInvoiceGroups(original, {0, 1}, primary: 0),
        throwsStateError);
  });

  test('different payments must be detached before combining', () {
    final task = fixture();
    task['groups'][0]
        ['payments'] = [payment('p-a', category: 'intercity', cents: 500)];
    task['groups'][1]
        ['payments'] = [payment('p-b', category: 'intercity', cents: 1200)];
    expect(
        () => combineInvoiceGroups(task, {0, 1}, primary: 0), throwsStateError);
    expect(task['groups'].length, 2);
    final shared = selectedTask();
    final other = invoice('other', category: 'intercity');
    other['payments'] = [shared['groups'][0]['payments'][0]];
    shared['groups'].add(other);
    expect(() => buildTaskExportManifest(shared), throwsStateError);
    expect(
        () => AssociationEditor(selectedTask(), 0).addSlot(), throwsStateError);
  });

  test('recalculation preserves bundle and reserves every member invoice',
      () async {
    final source = selectedTask();
    final merged = await MaterialMerger(NoInspection(), 'unused')
        .merge(source, recalculateManual: true);
    expect(merged['groups'].length, 1);
    expect(invoiceMembers(records(merged['groups']).single).length, 2);
    expect(buildTaskExportManifest(merged)['pictures'].length, 1);
  });

  test('folder save and reopen preserve both invoice files and shared payment',
      () async {
    final temp = await Directory.systemTemp.createTemp('invoice-bundle-store-');
    addTearDown(() => temp.delete(recursive: true));
    final task = selectedTask();
    final group = records(task['groups']).single;
    for (final member in invoiceMembers(group)) {
      final file = File('${temp.path}/${member['hash']}.pdf');
      await file.writeAsString('synthetic invoice ${member['hash']}');
      member['path'] = file.path;
    }
    group['path'] = invoiceMembers(group).first['path'];
    final pic = File('${temp.path}/pay.png');
    await pic.writeAsString('synthetic payment');
    group['payments'][0]['path'] = pic.path;
    task['pdfMaterials'] = <dynamic>[];
    final storage = TripFolderStorage(Directory('${temp.path}/trips'));
    await storage.save(task);
    final reopened = (await storage.readAll()).single;
    final m = invoiceMembers(records(reopened['groups']).single);
    expect(m.length, 2);
    for (final member in m) {
      expect(await File(member['path']).exists(), isTrue);
    }
    expect(buildTaskExportManifest(reopened)['pictures'].length, 1);
  });

  testWidgets('selecting another invoice returns an isolated combined task',
      (tester) async {
    Map<String, dynamic>? result;
    final source = fixture();
    await tester.pumpWidget(MaterialApp(
        home: Builder(
            builder: (context) => Scaffold(
                body: TextButton(
                    onPressed: () async {
                      result = await showDialog<Map<String, dynamic>>(
                          context: context,
                          builder: (_) =>
                              InvoiceBundleDialog(task: source, groupIndex: 0));
                    },
                    child: const Text('组合'))))));
    await tester.tap(find.text('组合'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(CheckboxListTile).last);
    await tester.pumpAndSettle();
    expect(find.text('发票合计：¥17.00'), findsOneWidget);
    await tester.tap(find.text('合并并选择支付'));
    await tester.pumpAndSettle();
    expect(result!['groups'].length, 1);
    expect(source['groups'].length, 2);
  });
}
