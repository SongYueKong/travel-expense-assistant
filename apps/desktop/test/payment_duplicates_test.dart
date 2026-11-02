import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:travel_assistant/import_service.dart';
import 'package:travel_assistant/services.dart';
import 'package:travel_assistant/association_service.dart';
import 'package:travel_assistant/export_service.dart';
import 'association_service_test.dart' show fixture, invoice, payment;

class FakeFiles implements ProcessingClient {
  final Map<String, Map<String, dynamic>> files;
  FakeFiles(List<Map<String, dynamic>> values)
      : files = {for (final m in values) m['path']: m};
  @override
  Future<dynamic> call(String method, Map<String, dynamic> params) async =>
      jsonDecode(jsonEncode(files[params['path']]));
}

Map<String, dynamic> image(String id, {String? pixels, String? transaction}) =>
    {
      ...payment(id),
      'imagePixelHash': pixels ?? id,
      'ocr': {
        ...payment(id)['ocr'],
        if (transaction != null) 'paymentTransactionId': transaction,
        if (transaction != null) 'transactionIdKind': 'transaction'
      }
    };

Future<Map<String, dynamic>> importImages(List<Map<String, dynamic>> images,
        {List<Map<String, dynamic>> reserved = const [],
        List<Map<String, dynamic>> excluded = const []}) =>
    FolderImporter(FakeFiles(images), 'unused').importPaths(
        images.map((m) => m['path'] as String).toList(), 100,
        reservedPaymentMaterials: reserved, excludedMaterials: excluded);

void main() {
  test('different names with same bytes or decoded pixels keep one screenshot',
      () async {
    final a = image('a'), b = image('b');
    b['hash'] = 'a';
    var result = await importImages([a, b]);
    expect(result['unmatchedPayments'].length, 1);
    expect(result['duplicatePayments'].length, 1);
    result = await importImages(
        [image('a', pixels: 'same'), image('b', pixels: 'same')]);
    expect(result['unmatchedPayments'].length, 1);
    expect(result['unmatchedMaterials'], isEmpty);
  });
  test(
      'same transaction removes duplicate despite different pixels and OCR amount',
      () async {
    final a = image('a', transaction: '20261027000000000000001'),
        b = image('b', transaction: '20261027000000000000001');
    b['ocr']['paymentCandidate']['cents'] = 9999;
    final result = await importImages([a, b]);
    expect(result['unmatchedPayments'].length, 1);
    expect(result['unmatchedPayments'][0]['hash'], 'a');
    expect(result['duplicatePayments'][0]['keptName'], 'a.png');
  });
  test(
      'same amount and time but different transactions remain separate candidates',
      () async {
    final result = await importImages([
      image('a', transaction: '20261027000000000000001'),
      image('b', transaction: '20261027000000000000002')
    ]);
    expect(result['unmatchedPayments'].length, 2);
    expect(result['duplicatePayments'], isEmpty);
  });
  test(
      'reimport against assigned or ignored identity cannot resurrect duplicate',
      () async {
    final existing = image('existing', transaction: '20261027000000000000001');
    final duplicate = image('new', transaction: '20261027000000000000001');
    final result = await importImages([duplicate], reserved: [existing]);
    expect(result['unmatchedPayments'], isEmpty);
    expect(result['unmatchedMaterials'], isEmpty);
    expect(result['duplicatePayments'].length, 1);
    final ignored = await importImages([duplicate], excluded: [existing]);
    expect(ignored['materials'], isEmpty);
  });
  test(
      'identity aliases prevent later bytes-only copy of transaction duplicate',
      () async {
    final a = image('a', transaction: '20261027000000000000001'),
        b = image('b', transaction: '20261027000000000000001'),
        c = image('c');
    c['hash'] = 'b';
    final result = await importImages([a, b, c]);
    expect(result['unmatchedPayments'].length, 1);
    expect(result['duplicatePayments'].length, 2);
  });
  test(
      'manual assignment and export reject transaction duplicate even if file hashes differ',
      () {
    final source = fixture(),
        a = image('a', transaction: '20261027000000000000001'),
        b = image('b', transaction: '20261027000000000000001');
    source['unmatchedPayments'] = [a, b];
    source['groups'][1]['payments'] = [
      {...a, 'cents': 10000}
    ];
    final editor = AssociationEditor(source, 0);
    expect(() => editor.choose(0, 'b'), throwsStateError);
    final g = invoice('other');
    g['payments'] = [
      {...b, 'cents': 10000}
    ];
    g['suggestionComplete'] = true;
    source['groups'][1]['suggestionComplete'] = true;
    expect(() => buildExportManifest([source['groups'][1], g], 100),
        throwsStateError);
  });
}
