import 'dart:convert';
import 'dart:io';
import 'package:sqlite3/sqlite3.dart' as sql;
import 'package:travel_assistant/services.dart';
import 'package:travel_assistant/app_preferences.dart';

void check(bool condition, String reason) {
  if (!condition) throw StateError(reason);
}

Future<void> main(List<String> args) async {
  final root = args.single;
  final sandbox =
      await Directory('$root/.local').createTemp('trip-folder-integration-');
  final dbFile = File('${sandbox.path}/index.sqlite'),
      tripRoot = Directory('${sandbox.path}/差旅记录');
  final live = sql.sqlite3
      .open('$root/.local/travel.sqlite', mode: sql.OpenMode.readOnly);
  final original = jsonDecode(live
      .select('SELECT body FROM tasks ORDER BY rowid DESC LIMIT 1')
      .single['body'] as String) as Map<String, dynamic>;
  live.close();
  var store = TaskStore(dbFile);
  await store.save(original);
  await store.saveDefaultMailbox(MailboxIdentity('163', 'folder-test@163.com'));
  await store.close();
  store = TaskStore(dbFile, tripDirectory: tripRoot);
  try {
    final migrated = (await store.load()).single;
    check(migrated['id'] == original['id'], '迁移保留原任务ID');
    check(await Directory('${sandbox.path}/folder-migration-backups').exists(),
        '迁移前保存数据库备份');
    final beforeGroups = original['groups'] as List,
        afterGroups = migrated['groups'] as List;
    for (var i = 0; i < beforeGroups.length; i++) {
      check(afterGroups[i]['invoiceCents'] == beforeGroups[i]['invoiceCents'],
          '迁移不改变发票金额');
      check(
          jsonEncode(afterGroups[i]['trips']) ==
              jsonEncode(beforeGroups[i]['trips']),
          '迁移不改变逐条行程');
      check((afterGroups[i]['path'] as String).startsWith(tripRoot.path),
          '发票必须位于独立目录');
      check(
          await File(afterGroups[i]['path']).length() ==
              await File(beforeGroups[i]['path']).length(),
          '原发票与副本长度一致');
      final a = afterGroups[i]['payments'] as List,
          b = beforeGroups[i]['payments'] as List;
      for (var j = 0; j < a.length; j++) {
        check(a[j]['cents'] == b[j]['cents'], '支付净额不变');
        check(jsonEncode(a[j]['ocr']) == jsonEncode(b[j]['ocr']), '原OCR保持原样');
      }
    }
    final persisted = jsonDecode(
        await File('${migrated['taskDirectory']}/差旅记录.json').readAsString());
    check(persisted['task']['groups'][0]['path'].toString().startsWith('发票/'),
        'JSON使用相对路径');
    final copy = await store.copyTask(migrated['id'], '文件夹副本');
    check(copy['taskDirectory'] != migrated['taskDirectory'], '复制产生独立目录');
    check(copy['groups'][0]['path'] != migrated['groups'][0]['path'],
        '复制材料不共享文件');
    final oldFolder = copy['taskDirectory'];
    final renamed = await store.renameTask(copy['id'], '重命名 "副本" / 验收');
    check(!await Directory(oldFolder).exists(), '重命名同步调整文件夹');
    check(await File(renamed['groups'][0]['path']).exists(), '重命名后材料可读取');
    final external = await File(renamed['groups'][0]['path'])
        .copy('${sandbox.path}/export-test.pdf');
    await store.recordExport(renamed, external.path);
    check(renamed['exports'][0]['path'].toString().contains('导出文件'),
        '导出副本归档到差旅文件夹');
    final beforeFailure = jsonEncode(
        (await store.load()).singleWhere((t) => t['id'] == renamed['id']));
    var failed = false;
    try {
      await store.save({
        ...renamed,
        'name': '应回滚的名称',
        'unmatchedPayments': [
          {'path': '${sandbox.path}/missing.jpg'}
        ]
      });
    } catch (_) {
      failed = true;
    }
    check(failed, '缺材料时应失败');
    check(
        jsonEncode((await store.load())
                .singleWhere((t) => t['id'] == renamed['id'])) ==
            beforeFailure,
        '失败保存不改变索引记录');
    await store.customStatement(
        "CREATE TRIGGER reject_name BEFORE UPDATE ON tasks WHEN NEW.name='拒绝名称' BEGIN SELECT RAISE(ABORT,'fixture rejection'); END");
    var indexFailed = false;
    try {
      await store.renameTask(renamed['id'], '拒绝名称');
    } catch (_) {
      indexFailed = true;
    }
    check(indexFailed, '索引写入故障应明确失败');
    check(await Directory(renamed['taskDirectory']).exists(), '索引失败恢复原文件夹');
    check(
        jsonDecode(await File('${renamed['taskDirectory']}/差旅记录.json')
                .readAsString())['task']['name'] ==
            renamed['name'],
        '索引失败恢复原JSON');
    await store.customStatement('DROP TRIGGER reject_name');
    await store.close();
    final raw = sql.sqlite3.open(dbFile.path);
    raw.execute('DELETE FROM tasks');
    raw.close();
    store = TaskStore(dbFile, tripDirectory: tripRoot);
    check((await store.load()).length == 2, '清空索引后可从JSON恢复列表');
    check((await store.loadDefaultMailbox())!.account == 'folder-test@163.com',
        '保留全局邮箱设置');
    await store.deleteTask(renamed['id']);
    check((await store.load()).length == 1, '删除同步移除索引');
    check(!await Directory(renamed['taskDirectory']).exists(), '删除目录移入回收站');
    check(await Directory('${tripRoot.path}/.回收站').exists(), '回收站保留完整目录');
    await store.close();
    store = TaskStore(dbFile, tripDirectory: tripRoot);
    check((await store.load()).length == 1, '重开不会从旧索引复活删除记录');
    stdout.writeln(
        'PASS: real-task migration, backup, relative JSON, unchanged amounts/OCR, independent copy, rename, export archive, missing-file rollback, index recovery, trash and reopen');
    stdout.writeln('Only isolated fixture modified: ${sandbox.path}');
  } finally {
    await store.close();
  }
}
