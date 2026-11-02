import 'dart:convert';
import 'dart:io';
import 'package:travel_assistant/services.dart';
import 'package:travel_assistant/export_service.dart';

void check(bool value, String reason) {
  if (!value) throw StateError(reason);
}

Future<void> main(List<String> args) async {
  final root = args.single;
  final directory =
      await Directory('$root/.local').createTemp('task-management-check-');
  final evidence = File('${directory.path}/original-evidence.txt');
  await evidence.writeAsString('Original evidence must survive task deletion');
  final db = File('${directory.path}/test.sqlite');
  var store = TaskStore(db);
  try {
    final source = <String, dynamic>{
      'id': 'legacy-task',
      'name': '原始差旅',
      'toleranceCents': 100,
      'groups': [
        {
          'name': '酒店发票',
          'path': evidence.path,
          'category': 'hotel',
          'invoiceCents': 10000,
          'document': {
            'type': 'invoice',
            'number': 'fixture-number',
            'totalCents': 10000
          },
          'confirmed': true,
          'complete': true,
          'itineraries': [],
          'payments': [
            {'path': evidence.path, 'hash': 'payment', 'cents': 9950}
          ]
        }
      ],
      'pdfMaterials': [
        {'path': evidence.path}
      ],
      'mailHistory': [
        {'provider': 'qq', 'account': 'test@qq.com'}
      ]
    };
    await store.save(source);
    final created = await store.createTask('  新差旅  ');
    check(created['name'] == '新差旅' && created['id'] != source['id'],
        '新建应规范名称并分配独立 ID');
    final renamed = await store.renameTask(source['id'], '北京 "科研" 差旅');
    final expected = {...source, 'name': renamed['name']};
    check(jsonEncode(renamed) == jsonEncode(expected), '重命名不能改变材料、金额或确认状态');
    for (final row
        in await store.customSelect('SELECT name, body FROM tasks').get()) {
      check(
          row.read<String>('name') ==
              jsonDecode(row.read<String>('body'))['name'],
          '名称列和 JSON 必须一致');
    }
    final beforeFailures = jsonEncode(await store.load());
    for (final action in [
      () => store.renameTask(source['id'], '   '),
      () => store.renameTask(source['id'], '新差旅'),
      () => store.copyTask(source['id'], '新差旅'),
      () => store.renameTask('missing', '有效名称'),
    ]) {
      var rejected = false;
      try {
        await action();
      } catch (_) {
        rejected = true;
      }
      check(rejected, '无效管理操作应明确失败');
      check(jsonEncode(await store.load()) == beforeFailures, '失败后数据库必须保持原样');
    }
    final copy = await store.copyTask(source['id'], '差旅副本');
    check(copy['groups'][0]['payments'][0]['cents'] == 9950, '复制应保留支付关联和净额');
    check(
        copy['groups'][0]['confirmed'] == false &&
            copy['groups'][0]['complete'] == false,
        '副本必须重新核对');
    final manifest = buildExportManifest(
        (copy['groups'] as List).cast<Map<String, dynamic>>(), 100);
    check(
        manifest['grandTotals']['reimbursementCents'] == 9950 &&
            manifest['reviewedInvoices'] == 0,
        '副本匹配完整即可导出，无需额外复核');
    copy['groups'][0]['payments'][0]['cents'] = 1;
    await store.save(copy);
    final original =
        (await store.load()).singleWhere((t) => t['id'] == source['id']);
    check(original['groups'][0]['payments'][0]['cents'] == 9950, '修改副本不能影响原任务');
    await store.close();
    store = TaskStore(db);
    check((await store.load()).length == 3, '创建、重命名、复制结果关闭重开后应保留');
    await store.deleteTask(copy['id']);
    check((await store.load()).length == 2, '删除只移除目标任务');
    check(
        await evidence.readAsString() ==
            'Original evidence must survive task deletion',
        '删除不能修改原始文件');
    await store.deleteTask(source['id']);
    await store.deleteTask(created['id']);
    await store.close();
    store = TaskStore(db);
    check((await store.load()).isEmpty, '最后一个任务删除后重开应为空');
    final newTask = await store.createTask('删除后新建');
    check(newTask['name'] == '删除后新建', '空列表仍可创建任务');
    stdout.writeln('PASS: create / rename / copy / delete and SQLite reopen');
    stdout.writeln(
        'PASS: validation rollback, reset copied confirmations, original data and files preserved');
    stdout.writeln('Only an independent test database was edited.');
  } finally {
    await store.close();
  }
}
