import 'dart:convert';
import 'dart:io';
import 'package:sqlite3/sqlite3.dart';
import 'package:travel_assistant/services.dart';
import 'package:travel_assistant/app_preferences.dart';
import 'package:travel_assistant/payment_layout.dart';

void check(bool condition, String message) {
  if (!condition) throw StateError(message);
}

Future<void> main(List<String> args) async {
  final root = args.single,
      directory = await Directory('${args.single}/.local')
          .createTemp('preferences-check-');
  final file = File('${directory.path}/old.sqlite');
  final original = jsonEncode({
    'id': 'legacy',
    'name': '旧版差旅',
    'toleranceCents': 100,
    'groups': [],
    'mailHistory': [
      {
        'provider': 'qq',
        'account': 'previous@qq.com',
        'importedAt': '2026-10-30T10:00:00+08:00'
      }
    ]
  });
  final old = sqlite3.open(file.path);
  old.execute(
      'CREATE TABLE tasks (id TEXT PRIMARY KEY, name TEXT NOT NULL, body TEXT NOT NULL)');
  old.execute('INSERT INTO tasks(id,name,body)VALUES(?,?,?)',
      ['legacy', '旧版差旅', original]);
  old.execute('PRAGMA user_version = 1');
  old.close();
  var store = TaskStore(file);
  try {
    check(await store.loadDefaultMailbox() == null, '首次升级不应虚构账号');
    check(
        jsonEncode((await store.loadPaymentLayout()).toJson()) ==
            jsonEncode(const PaymentLayout.defaults().toJson()),
        '升级默认保留横向2×4');
    await store.savePaymentLayout(
        PaymentLayout(orientation: 'portrait', rows: 3, columns: 2));
    check(
        (await store.customSelect('PRAGMA user_version').getSingle())
                .read<int>('user_version') ==
            2,
        '旧数据库应升级到设置版本');
    final before = (await store
            .customSelect("SELECT body FROM tasks WHERE id='legacy'")
            .getSingle())
        .read<String>('body');
    check(before == original, '迁移必须保持旧差旅 JSON 原样');
    await store.saveDefaultMailbox(mostRecentMailbox(await store.load())!);
    await store.createTask('新建差旅一');
    check((await store.loadDefaultMailbox())!.account == 'previous@qq.com',
        '新建任务不清空本机默认邮箱');
    await store.saveDefaultMailbox(MailboxIdentity.fromJson({
      'provider': '163',
      'account': ' NEW@163.COM ',
      'authorization_code': 'SYNTHETIC-SECRET-DO-NOT-STORE'
    }));
    await store.createTask('新建差旅二');
    final raw = (await store
            .customSelect(
                "SELECT value FROM app_settings WHERE key='default_mailbox'")
            .getSingle())
        .read<String>('value');
    check(
        jsonEncode(jsonDecode(raw)) ==
            jsonEncode({'provider': '163', 'account': 'new@163.com'}),
        '设置只保存服务商和规范化账号，不能包含授权码');
    await store.close();
    store = TaskStore(file);
    check(
        jsonEncode((await store.loadPaymentLayout()).toJson()) ==
            jsonEncode({'orientation': 'portrait', 'rows': 3, 'columns': 2}),
        '退出重开及新建差旅均沿用支付截图排版');
    check((await store.loadDefaultMailbox())!.account == 'new@163.com',
        '退出重开后保留默认邮箱');
    check((await store.load()).length == 3, '新增设置不影响差旅管理');
    for (final task in await store.load()) {
      await store.deleteTask(task['id']);
    }
    check((await store.loadDefaultMailbox())!.account == 'new@163.com',
        '删除差旅不删除本机默认邮箱');
    check((await store.loadPaymentLayout()).perPage == 6, '删除全部差旅仍保留全局排版');
    for (final malformed in [
      'not json',
      '[]',
      '{}',
      '{"orientation":"portrait","rows":0,"columns":2}',
      '{"orientation":"landscape","rows":2,"columns":null}'
    ]) {
      await store.customStatement(
          "UPDATE app_settings SET value=? WHERE key='payment_layout'",
          [malformed]);
      check(
          (await store.loadPaymentLayout()).landscape &&
              (await store.loadPaymentLayout()).perPage == 8,
          '损坏排版配置回退横向2×4');
    }
    for (final malformed in ['not json', '[]', '{"account":7}']) {
      await store.customStatement(
          "UPDATE app_settings SET value=? WHERE key='default_mailbox'",
          [malformed]);
      check(await store.loadDefaultMailbox() == null, '损坏的邮箱配置不能阻止打开工作空间');
    }
    stdout.writeln(
        'PASS: version 1 -> 2 migration preserves task JSON; global mailbox survives new tasks, deletion and reopen');
    stdout.writeln(
        'PASS: account/provider only; no authorization code in settings; malformed settings handled');
    stdout.writeln(
        'PASS: global payment layout survives new tasks, restart and deleting all tasks; invalid settings fall back to defaults');
    stdout.writeln(
        'Independent database: ${file.path}; live database under $root was not modified.');
  } finally {
    await store.close();
  }
}
