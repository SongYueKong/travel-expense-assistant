import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:travel_assistant/hotel_check.dart';
import 'package:travel_assistant/hotel_check_dialog.dart';
import 'package:travel_assistant/export_service.dart';
import 'package:travel_assistant/pdf_catalog.dart';
import 'export_readiness_test.dart' show matched;
import 'mail_dialog_test.dart' show FakeProcessor;

Map<String, dynamic> different() {
  final g = matched();
  g['payments'][0]['ocr']['payeeName'] = '另一收款公司';
  return g;
}

void proof(Map<String, dynamic> g, String kind) {
  g['hotelVerification'] = {
    'proof': {
      'kind': kind,
      'basis': HotelCheck(g).basis,
      if (kind == 'pdf')
        'material': {
          'name': '情况说明.pdf',
          'path': 'C:/test/statement.pdf',
          'hash': 'statement'
        }
    }
  };
}

void main() {
  test(
      'normalization ignores whitespace and parentheses but preserves legal company words',
      () {
    final g = matched();
    g['document']['sellerName'] = '测试酒店（上海）有限公司';
    g['payments'][0]['ocr']['payeeName'] = '测 试 酒 店 ( 上 海 ) 有 限 公 司';
    expect(HotelCheck(g).same, isTrue);
    g['payments'][0]['ocr']['payeeName'] = '测试酒店(上海)管理有限公司';
    expect(HotelCheck(g).resolved, isFalse);
    g['document'].remove('sellerName');
    expect(HotelCheck(g).known, isFalse);
    expect(() => buildExportManifest([g], 100), throwsStateError);
  });
  test(
      'mismatch needs current proof, is not bypassed by review and proof expires after reassignment',
      () {
    final g = different();
    g['confirmed'] = true;
    expect(() => buildExportManifest([g], 100), throwsStateError);
    proof(g, 'paper');
    expect(HotelCheck(g).resolved, isTrue);
    expect(buildExportManifest([g], 100)['summary'][0]['description'],
        contains('纸质情况说明'));
    g['payments'][0]['hash'] = 'changed';
    expect(HotelCheck(g).resolved, isFalse);
  });
  test(
      'PDF proof participates in export and catalog without changing amounts or original groups',
      () {
    final g = different();
    proof(g, 'pdf');
    final before = jsonEncode(g), manifest = buildExportManifest([g], 100);
    expect(manifest['invoices'][0]['supportingDocuments'],
        ['C:/test/statement.pdf']);
    expect(manifest['grandTotals']['reimbursementCents'], 9950);
    expect(jsonEncode(g), before);
    expect(
        buildPdfCatalog({
          'groups': [g]
        }).any((e) => e.uses.contains('001 酒店情况说明')),
        isTrue);
    g['payments'][0]['ocr']['payeeName'] = '又一公司';
    expect(HotelCheck(g).resolved, isFalse);
  });
  testWidgets(
      'paper proof can resolve mismatch in dialog and is cleared by name edits',
      (tester) async {
    tester.view.physicalSize = const Size(1440, 1100);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    Map<String, dynamic>? saved;
    await tester.pumpWidget(MaterialApp(
        home: HotelCheckDialog(
            group: different(),
            engine: FakeProcessor(),
            materialDirectory: 'unused',
            commit: (g) async => saved = g)));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byType(CheckboxListTile));
    await tester.tap(find.byType(CheckboxListTile));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const ValueKey('hotel-payee-0')), '重新核对公司');
    await tester.pumpAndSettle();
    expect(tester.widget<CheckboxListTile>(find.byType(CheckboxListTile)).value,
        isFalse);
    await tester.ensureVisible(find.byType(CheckboxListTile));
    await tester.tap(find.byType(CheckboxListTile));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存核对结果'));
    await tester.pumpAndSettle();
    expect(HotelCheck(saved!).resolved, isTrue);
    expect(HotelCheck(saved!).proof!['kind'], 'paper');
    expect(tester.takeException(), isNull);
  });
}
