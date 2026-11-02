import 'dart:convert';
import 'dart:io';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:travel_assistant/hotel_check.dart';
import 'package:travel_assistant/hotel_check_dialog.dart';
import 'package:travel_assistant/export_service.dart';
import 'package:travel_assistant/services.dart';
import 'package:travel_assistant/trip_folder_storage.dart';
import 'hotel_check_test.dart' show different;

const png =
    'iVBORw0KGgoAAAANSUhEUgAAAAQAAAAECAIAAAAmkwkpAAAAE0lEQVR4nGP8//8/AwwwwVl4OQCWbgMF7ZjH1AAAAABJRU5ErkJggg==';
void imageProof(Map<String, dynamic> g, String path) {
  g['hotelVerification'] = {
    'proof': {
      'kind': 'image',
      'basis': HotelCheck(g).basis,
      'material': {
        'path': path,
        'name': '情况说明.png',
        'hash': 'statement',
        'document': {'type': 'supportingDocument'}
      }
    }
  };
}

class StatementProcessor implements ProcessingClient {
  Map<String, dynamic>? request;
  @override
  Future<dynamic> call(String method, Map<String, dynamic> params) async {
    request = params;
    return {
      'path': params['path'],
      'hash': 'statement',
      'document': {'type': 'supportingDocument'}
    };
  }
}

void main() {
  test(
      'all supported image extensions resolve and export at unchanged amounts; changed parties invalidate proof',
      () {
    for (final extension in hotelStatementImages) {
      final g = different();
      imageProof(g, 'C:/test/statement.${extension.toUpperCase()}');
      expect(HotelCheck(g).resolved, true);
      final manifest = buildExportManifest([g], 100);
      expect(manifest['invoices'][0]['supportingDocuments'],
          ['C:/test/statement.${extension.toUpperCase()}']);
      expect(manifest['grandTotals']['reimbursementCents'], 9950);
      g['payments'][0]['ocr']['payeeName'] = '更换收款单位';
      expect(HotelCheck(g).resolved, false);
    }
    final invalid = different();
    imageProof(invalid, 'C:/test/statement.exe');
    expect(HotelCheck(invalid).resolved, false);
    imageProof(invalid, 'C:/test/statement.pdf');
    expect(HotelCheck(invalid).resolved, false);
  });
  test(
      'image statement is archived independently and proof binding survives reload and folder rename',
      () async {
    final temp = await Directory.systemTemp.createTemp('hotel-image-proof-');
    try {
      final source = File('${temp.path}/statement.png');
      await source.writeAsBytes(base64Decode(png));
      final invoice = File('${temp.path}/invoice.pdf');
      await invoice.writeAsString('storage fixture');
      final payment = File('${temp.path}/payment.jpg');
      await payment.writeAsString('storage fixture');
      final g = different();
      g['path'] = invoice.path;
      g['payments'][0]['path'] = payment.path;
      imageProof(g, source.path);
      final store = TripFolderStorage(Directory('${temp.path}/records'));
      final task = {
        'id': 'hotel-image',
        'name': '图片说明测试',
        'groups': [g],
        'toleranceCents': 100
      };
      await store.save(task);
      var loaded = (await store.readAll()).single;
      expect(HotelCheck(loaded['groups'][0]).resolved, true);
      final path = loaded['groups'][0]['hotelVerification']['proof']['material']
          ['path'] as String;
      expect(path, contains('情况说明'));
      expect(await File(path).readAsBytes(), await source.readAsBytes());
      loaded['name'] = '重命名后';
      await store.save(loaded);
      loaded = (await store.readAll()).single;
      expect(HotelCheck(loaded['groups'][0]).resolved, true);
    } finally {
      await temp.delete(recursive: true);
    }
  });
  testWidgets('attach image with statement role, preview and save proof',
      (tester) async {
    tester.view.physicalSize = const Size(1440, 1100);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final temp = Directory.systemTemp.createTempSync('hotel-proof-dialog-');
    final file = File('${temp.path}/statement.png');
    file.writeAsBytesSync(base64Decode(png));
    final engine = StatementProcessor();
    Map<String, dynamic>? saved;
    await tester.pumpWidget(MaterialApp(
        home: HotelCheckDialog(
            group: different(),
            engine: engine,
            materialDirectory: temp.path,
            pickStatement: () async => XFile(file.path),
            commit: (g) async => saved = g)));
    await tester.pumpAndSettle();
    await tester.runAsync(() => precacheImage(
        FileImage(file), tester.element(find.byType(HotelCheckDialog))));
    await tester.ensureVisible(find.text('添加／替换情况说明（PDF／图片）'));
    await tester.tap(find.text('添加／替换情况说明（PDF／图片）'));
    await tester.pumpAndSettle();
    expect(engine.request!['purpose'], 'statement');
    expect(find.text('点击放大查看情况说明'), findsOneWidget);
    await tester.tap(find.text('保存核对结果'));
    for (var i = 0; i < 20 && saved == null; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pumpAndSettle();
    }
    expect(HotelCheck(saved!).resolved, true);
    expect(HotelCheck(saved!).proof!['kind'], 'image');
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await temp.delete(recursive: true);
    });
    expect(tester.takeException(), isNull);
  });
}
