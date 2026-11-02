import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:travel_assistant/trip_folder_storage.dart';
import 'package:travel_assistant/hotel_check.dart';

void main() {
  late Directory sandbox;
  late TripFolderStorage storage;
  late Map<String, dynamic> source;
  setUp(() async {
    sandbox = await Directory.systemTemp.createTemp('trip-folders-test-');
    storage = TripFolderStorage(Directory('${sandbox.path}/差旅记录'));
    final files = <String, String>{};
    for (final name in [
      'invoice.pdf',
      'trip.pdf',
      'payment.jpg',
      'statement.pdf'
    ]) {
      final file = File('${sandbox.path}/$name');
      await file.writeAsString('independent fixture $name');
      files[name] = file.path;
    }
    final group = <String, dynamic>{
      'hash': 'invoice-hash',
      'path': files['invoice.pdf'],
      'name': '住宿发票.pdf',
      'category': 'hotel',
      'invoiceCents': 10000,
      'document': {'type': 'invoice', 'sellerName': '销售酒店'},
      'payments': [
        {
          'hash': 'payment-hash',
          'path': files['payment.jpg'],
          'name': '支付截图.jpg',
          'cents': 9950,
          'ocr': {'payeeName': '收款酒店'}
        }
      ],
      'itineraries': [files['trip.pdf']],
      'confirmed': true
    };
    group['hotelVerification'] = {
      'proof': {
        'kind': 'pdf',
        'basis': HotelCheck(group).basis,
        'material': {'path': files['statement.pdf'], 'name': '说明.pdf'}
      }
    };
    source = {
      'id': 'fixture-12345678',
      'name': '北京出差（2026-10-27 至 2026-10-29）',
      'toleranceCents': 100,
      'groups': [group],
      'pdfMaterials': [
        {
          'path': files['invoice.pdf'],
          'document': {'type': 'invoice'}
        }
      ]
    };
  });
  test(
      'self-contained relative JSON, categorized copies and hotel proof survive reopen and move',
      () async {
    final saved = await storage.save(source), folder = saved['taskDirectory'];
    final record = jsonDecode(await File('$folder/差旅记录.json').readAsString());
    expect(record['task']['groups'][0]['path'], startsWith('发票/'));
    expect(record['task']['groups'][0]['payments'][0]['path'],
        startsWith('支付截图/'));
    expect(record['task']['groups'][0]['itineraries'][0], startsWith('行程单/'));
    expect(
        record['task']['groups'][0]['hotelVerification']['proof']['material']
            ['path'],
        startsWith('情况说明/'));
    expect(record['task']['taskDirectory'], isNull);
    expect(HotelCheck(saved['groups'][0]).resolved, isTrue);
    expect(source['groups'][0]['path'], '${sandbox.path}/invoice.pdf');
    final moved = Directory('${sandbox.path}/迁移后的全部差旅');
    await storage.root.rename(moved.path);
    final loaded = (await TripFolderStorage(moved).readAll()).single;
    expect(
        await File(loaded['groups'][0]['payments'][0]['path']).readAsString(),
        'independent fixture payment.jpg');
    expect(HotelCheck(loaded['groups'][0]).resolved, isTrue);
    expect(loaded['groups'][0]['invoiceCents'], 10000);
  });
  test(
      'saving reopened trip with mixed separators does not rename its own folder',
      () async {
    final saved = await storage.save(source);
    final reopened =
        TripFolderStorage(Directory(storage.root.path.replaceAll('\\', '/')));
    final task = (await reopened.readAll()).single;
    if (Platform.isWindows) {
      // 复现重启后枚举目录与新拼接路径的斜杠写法不同。
      expect(
          reopened.locations[task['id']]!.absolute.path,
          isNot(Directory('${reopened.root.path}/${reopened.folderName(task)}')
              .absolute
              .path));
    }
    final before = await reopened.locations[task['id']]!.resolveSymbolicLinks();
    final statement = File('${sandbox.path}/explanation.png');
    await statement.writeAsString('image storage fixture');
    final group = (task['groups'] as List).cast<Map<String, dynamic>>().single;
    group['hotelVerification'] = {
      'proof': {
        'kind': 'image',
        'basis': HotelCheck(group).basis,
        'material': {'path': statement.path, 'name': '说明.png'}
      }
    };
    final updated = await reopened.save(task);
    expect(await Directory(updated['taskDirectory']).resolveSymbolicLinks(),
        before);
    expect(HotelCheck(updated['groups'][0]).resolved, true);
    expect(
        await File(updated['groups'][0]['hotelVerification']['proof']
                ['material']['path'])
            .exists(),
        true);
    expect(updated['id'], saved['id']);
    final reloaded = (await reopened.readAll()).single;
    await reopened.save(reloaded);
    expect(HotelCheck(reloaded['groups'][0]).resolved, true);
  });
  test(
      'different IDs with colliding shortened folder names never overwrite existing record',
      () async {
    final saved = await storage.save(source);
    final file = File('${saved['taskDirectory']}/差旅记录.json');
    final before = await file.readAsString();
    final conflicting = {...source, 'id': 'fixture-different-id'};
    expect(storage.folderName(conflicting), storage.folderName(source));
    await expectLater(storage.save(conflicting), throwsStateError);
    expect(await file.readAsString(), before);
  });
  test(
      'rename updates folder and paths; copies contain independent files; delete uses trash',
      () async {
    var saved = await storage.save(source);
    final old = saved['taskDirectory'];
    saved['name'] = '上海新名称';
    saved = await storage.save(saved);
    expect(await Directory(old).exists(), isFalse);
    expect(saved['taskDirectory'], contains('上海新名称'));
    expect(await File(saved['groups'][0]['path']).exists(), isTrue);
    final copy =
        await storage.save({...saved, 'id': 'copy-87654321', 'name': '副本'});
    expect(copy['groups'][0]['path'], isNot(saved['groups'][0]['path']));
    await File(saved['groups'][0]['payments'][0]['path'])
        .writeAsString('modified fixture');
    expect(await File(copy['groups'][0]['payments'][0]['path']).readAsString(),
        'independent fixture payment.jpg');
    final original = storage.locations[copy['id']]!;
    final trash = await storage.trash(copy['id']);
    expect(await File('${trash!.path}/差旅记录.json').exists(), isTrue);
    expect((await storage.readAll()).length, 1);
    await storage.restoreTrash(copy['id'], trash, original);
    expect((await storage.readAll()).length, 2);
  });
  test(
      'missing material fails before replacing record and rolls back folder rename',
      () async {
    final saved = await storage.save(source);
    final before =
        await File('${saved['taskDirectory']}/差旅记录.json').readAsString();
    final invalid = {
      ...saved,
      'name': '失败名称',
      'unmatchedPayments': [
        {'path': '${sandbox.path}/missing.jpg'}
      ]
    };
    await expectLater(
        storage.save(invalid), throwsA(isA<FileSystemException>()));
    expect(await File('${saved['taskDirectory']}/差旅记录.json').readAsString(),
        before);
    expect((await storage.readAll()).single['name'], source['name']);
  });
  test('relative path traversal is rejected', () async {
    final saved = await storage.save(source),
        file = File('${saved['taskDirectory']}/差旅记录.json');
    final envelope = jsonDecode(await file.readAsString());
    envelope['task']['groups'][0]['path'] = '发票/../../outside.pdf';
    await file.writeAsString(jsonEncode(envelope));
    await expectLater(storage.readAll(), throwsFormatException);
  });
}
