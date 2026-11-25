import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:travel_assistant/services.dart';
import 'package:travel_assistant/pending_service.dart';
import 'package:travel_assistant/supplement_pdf_importer.dart';
import 'package:travel_assistant/material_merge_service.dart';

class InvoiceFiles implements ProcessingClient {
  String number = '26000000000000000001';
  int cents = 4800;
  bool unknown = false, failMerge = false;
  int invoices = 0;
  final purposes = <dynamic>[];
  @override
  Future<dynamic> call(String method, Map<String, dynamic> p) async {
    final path = p['path'] as String;
    if (path.endsWith('.jpg')) return payment(path);
    purposes.add(p['purpose']);
    invoices++;
    if (failMerge && invoices > 1) throw StateError('文件损坏');
    return {
      'path': path,
      'name': 'invoice.pdf',
      'hash': 'invoice',
      'purpose': p['purpose'],
      'document': unknown
          ? {'type': 'unknown'}
          : {
              'type': 'invoice',
              'category': 'intercity',
              'platform': 'rail',
              'number': number,
              'totalCents': cents,
              'issueDate': '2026-11-20'
            }
    };
  }
}

Map<String, dynamic> payment(String path) => {
      'path': path,
      'hash': path,
      'name': 'payment.jpg',
      'ocr': {
        'category': 'intercity',
        'platform': 'rail',
        'paymentDate': '2026-11-20',
        'paymentCandidate': {'cents': 4800}
      }
    };
Map<String, dynamic> fixture({int payments = 1}) => {
      'id': 'test',
      'name': '合成测试',
      'toleranceCents': 100,
      'groups': <dynamic>[],
      'unmatchedMaterials': <dynamic>[],
      'unmatchedPayments': [
        for (var i = 0; i < payments; i++) payment('C:/synthetic/p$i.jpg')
      ],
      'mailHistory': [
        {
          'account': 'test@qq.com',
          'pending': [
            for (var i = 0; i < 2; i++)
              {
                'folder': 'INBOX',
                'uidValidity': '1',
                'uid': '$i',
                'subject': '电子发票 价税合计金额为48.00 发票号码:2600000000000000000${i + 1}',
                'reason': '请补充 PDF'
              }
          ]
        }
      ]
    };

void main() {
  late Directory temp;
  late String pdf;
  late InvoiceFiles engine;
  late SupplementPdfImporter importer;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('supplement-test-');
    pdf = (await File('${temp.path}/invoice.pdf').writeAsString('synthetic'))
        .path;
    engine = InvoiceFiles();
    importer = SupplementPdfImporter(engine, temp.path);
  });
  tearDown(() async => temp.delete(recursive: true));

  test(
      'extra invoice automatically matches existing payment without confirmation',
      () async {
    final original = fixture(), before = jsonEncode(fixture());
    final result = await importer.importFiles(original, [pdf]);
    expect(result['groups'].single['payments'].length, 1);
    expect(result['groups'].single['suggestionComplete'], true);
    expect(result['groups'].single['confirmed'], false);
    expect(result['unmatchedPayments'], isEmpty);
    expect(engine.purposes, everyElement('invoice'));
    expect(jsonEncode(original), before);
  });
  test(
      'equal candidates remain pending instead of choosing an arbitrary payment',
      () async {
    final result = await importer.importFiles(fixture(payments: 2), [pdf]);
    expect(result['groups'].single['payments'], isEmpty);
    expect(result['unmatchedPayments'].length, 2);
  });
  test('invoice can be added first and matched after payment arrives',
      () async {
    var result = await importer.importFiles(fixture(payments: 0), [pdf]);
    expect(result['groups'].single['payments'], isEmpty);
    result = await MaterialMerger(engine, temp.path).merge(result, mailFiles: [
      {'path': 'C:/synthetic/p.jpg'}
    ]);
    expect(result['groups'].single['payments'].length, 1);
    expect(engine.purposes, everyElement('invoice'));
  });
  test('correct mail import records provenance and closes only selected mail',
      () async {
    final task = fixture();
    final mail = pendingItems(task).firstWhere((i) => i.kind == 'mail');
    final result = await importer.importFiles(task, [pdf], mail: mail);
    expect(pendingItems(result).where((i) => i.kind == 'mail').length, 1);
    expect(result['issueDecisions'].single['id'], mail.id);
    expect(result['groups'].single['mailSource']['uid'], '0');
    expect(result['groups'].single['mailSource']['account'], 'test@qq.com');
    expect(result['groups'].single['payments'].length, 1);
  });
  test('wrong invoice number or amount cannot change task or close mail',
      () async {
    for (final mismatch in ['number', 'amount']) {
      final task = fixture(), before = jsonEncode(fixture());
      engine.number = mismatch == 'number'
          ? '26000000000000000009'
          : '26000000000000000001';
      engine.cents = mismatch == 'amount' ? 4900 : 4800;
      await expectLater(
          importer.importFiles(task, [pdf], mail: pendingItems(task).first),
          throwsStateError);
      expect(jsonEncode(task), before);
    }
  });
  test(
      'duplicate invoice does not create duplicate fees or steal protected payments',
      () async {
    var task = await importer.importFiles(fixture(), [pdf]);
    task['groups'].single['confirmed'] = true;
    task['groups'].single['invoiceCents'] = 4700;
    final result =
        await importer.importFiles(task, [pdf], mail: pendingItems(task).first);
    expect(result['groups'].length, 1);
    expect(result['groups'].single['confirmed'], true);
    expect(result['groups'].single['invoiceCents'], 4700);
    expect(result['importIssues'], isEmpty);
    expect(result['groups'].single['payments'].length, 1);
    engine.cents = 5000;
    await expectLater(importer.importFiles(result, [pdf]), throwsStateError);
  });
  test('unknown PDF stays available for manual entry, but cannot resolve email',
      () async {
    engine.unknown = true;
    final task = fixture();
    final result = await importer.importFiles(task, [pdf]);
    expect(result['groups'], isEmpty);
    expect(result['unmatchedMaterials'].length, 1);
    await expectLater(
        importer.importFiles(task, [pdf], mail: pendingItems(task).first),
        throwsStateError);
  });
  test('invalid drops and second inspection failure leave original task intact',
      () async {
    final task = fixture(),
        before = jsonEncode(fixture()),
        mail = pendingItems(fixture()).first;
    for (final paths in [
      [pdf, pdf],
      ['${temp.path}/missing.pdf'],
      [temp.path],
      ['C:/x.jpg']
    ]) {
      await expectLater(
          importer.importFiles(task, paths, mail: mail), throwsStateError);
    }
    engine.failMerge = true;
    await expectLater(
        importer.importFiles(task, [pdf], mail: mail), throwsStateError);
    expect(jsonEncode(task), before);
  });
}
