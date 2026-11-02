import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:travel_assistant/payment_identity.dart';
import 'package:travel_assistant/export_service.dart';
import 'package:travel_assistant/import_service.dart';
import 'payment_duplicates_test.dart' show FakeFiles;
import 'association_service_test.dart' show invoice;

Map<String, dynamic> receipt(String name) => {
      'path': 'C:/test/$name.jpg',
      'hash': name,
      'ocr': {},
      'paymentContentEvidence': {
        'version': 1,
        'facts': {
          'platform': 'didi',
          'cents': 4606,
          'paid': '2026-10-29T19:50:22+08:00',
          'ride': '2026-10-29T18:51:46+08:00',
          'description': '滴滴快车白师傅行程',
          'method': '支付宝'
        },
        'rows': {
          for (final k in [
            'amount',
            'paymentDateTime',
            'rideDateTime',
            'description',
            'method'
          ])
            k: {
              'bits': base64Encode(Uint8List.fromList(List.filled(1536, 170))),
              'ink': 6144
            }
        },
        'body': base64Encode(Uint8List.fromList(List.filled(2048, 245)))
      }
    };

void main() {
  test(
      'confirmed duplicate hashes persist even if later OCR cannot read the screenshot',
      () async {
    final a = receipt('a'), b = receipt('b');
    final result = await FolderImporter(FakeFiles([a, b]), 'unused')
        .importPaths([a['path'], b['path']], 100);
    final kept = Map<String, dynamic>.from(result['materials'].single);
    expect(kept['paymentDuplicateHashes'], contains('b'));
    final future = {'path': 'C:/test/copied.jpg', 'hash': 'b', 'ocr': {}};
    expect(MaterialIdentityIndex([kept]).find(future), same(kept));
    expect(a['paymentDuplicateHashes'], isNull);
  });
  test(
      'different whole-image hashes with matching facts and bill evidence find existing payment',
      () {
    final a = receipt('assigned'), b = receipt('new');
    expect(samePaymentContent(a, b), isTrue);
    final index = MaterialIdentityIndex([a]);
    expect(index.find(b), same(a));
    expect(index.add(b), same(a));
    expect(index.find({'hash': 'new', 'path': 'C:/test/renamed.jpg'}), same(a));
  });
  test(
      'matching amount is insufficient if exact-second time description method or order differ',
      () {
    for (final field in ['paid', 'ride', 'description', 'method', 'cents']) {
      final a = receipt('a'), b = receipt('b');
      b['paymentContentEvidence']['facts'][field] = 'different';
      expect(samePaymentContent(a, b), isFalse);
    }
  });
  test(
      'different visible field glyphs or body reject duplicate despite same OCR facts',
      () {
    final a = receipt('a'),
        b = receipt('b'),
        bytes = base64Decode(
            receipt('b')['paymentContentEvidence']['rows']['amount']['bits']);
    for (var i = 0; i < 16; i++) {
      bytes[i] ^= 255;
    }
    b['paymentContentEvidence']['rows']['amount']['bits'] = base64Encode(bytes);
    expect(samePaymentContent(a, b), isFalse);
    final c = receipt('c');
    c['paymentContentEvidence']['body'] = base64Encode(Uint8List(2048));
    expect(samePaymentContent(a, c), isFalse);
  });
  test(
      'different transaction IDs and incomplete visual evidence cannot be merged',
      () {
    final a = receipt('a'), b = receipt('b');
    a['ocr']['paymentTransactionId'] = '20261029000000000001';
    b['ocr']['paymentTransactionId'] = '20261029000000000002';
    expect(samePaymentContent(a, b), isFalse);
    final c = receipt('c'), d = receipt('d');
    d['paymentContentEvidence']['rows'].remove('rideDateTime');
    expect(samePaymentContent(c, d), isFalse);
  });
  test(
      'same bill evidence in different invoice groups blocks double reimbursement',
      () {
    final a = invoice('a'), b = invoice('b');
    a['payments'] = [
      {...receipt('a'), 'cents': 4606}
    ];
    b['payments'] = [
      {...receipt('b'), 'cents': 4606}
    ];
    a['suggestionComplete'] = true;
    b['suggestionComplete'] = true;
    expect(() => buildExportManifest([a, b], 100), throwsStateError);
  });
}
