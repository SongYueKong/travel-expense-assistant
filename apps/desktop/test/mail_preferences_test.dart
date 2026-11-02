import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:travel_assistant/app_preferences.dart';
import 'package:travel_assistant/mail_dialog.dart';
import 'mail_dialog_test.dart' show FakeProcessor;

class MemoryPreferences implements MailboxPreferences {
  MailboxIdentity? saved;
  Completer<MailboxIdentity?>? pendingRead;
  bool failSave = false;
  final writes = <Map<String, String>>[];
  @override
  Future<MailboxIdentity?> loadDefaultMailbox() async =>
      pendingRead == null ? saved : pendingRead!.future;
  @override
  Future<void> saveDefaultMailbox(MailboxIdentity value) async {
    if (failSave) throw StateError('设置写入失败');
    saved = value;
    writes.add(value.toJson());
  }
}

Future<void> open(
    WidgetTester tester, MemoryPreferences prefs, FakeProcessor engine,
    {Map<String, dynamic>? previous}) async {
  await tester.pumpWidget(MaterialApp(
      home: Builder(
          builder: (context) => Scaffold(
              body: TextButton(
                  onPressed: () => showDialog(
                      context: context,
                      builder: (_) => MailImportDialog(
                          engine: engine,
                          preferences: prefs,
                          previous: previous)),
                  child: const Text('新建后导入'))))));
  await tester.tap(find.text('新建后导入'));
  await tester.pumpAndSettle();
}

String field(WidgetTester tester, int index) =>
    tester.widget<TextField>(find.byType(TextField).at(index)).controller!.text;

void main() {
  testWidgets('failed mailbox login does not replace previously saved default',
      (tester) async {
    final prefs = MemoryPreferences()
          ..saved = MailboxIdentity('qq', 'existing@qq.com'),
        engine = FakeProcessor()..failTest = true;
    await open(tester, prefs, engine);
    await tester.enterText(find.byType(TextField).at(0), 'new@qq.com');
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).at(1), 'INVALID-CODE');
    await tester.ensureVisible(find.text('测试连接并读取文件夹'));
    await tester.tap(find.text('测试连接并读取文件夹'));
    await tester.pumpAndSettle();
    expect(prefs.saved!.account, 'existing@qq.com');
    expect(prefs.writes, isEmpty);
    expect(find.textContaining('邮箱认证失败'), findsOneWidget);
  });
  testWidgets(
      'account can be remembered even when credential vault write fails',
      (tester) async {
    final prefs = MemoryPreferences(),
        engine = FakeProcessor()..failSave = true;
    await open(tester, prefs, engine);
    await tester.enterText(find.byType(TextField).at(0), 'person@qq.com');
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).at(1), 'TEST-CODE');
    await tester.ensureVisible(find.text('测试连接并读取文件夹'));
    await tester.tap(find.text('测试连接并读取文件夹'));
    await tester.pumpAndSettle();
    expect(prefs.saved!.account, 'person@qq.com');
    expect(engine.saved, isEmpty);
    expect(find.textContaining('授权码未能保存'), findsOneWidget);
  });
  test(
      'history recovers most recent valid mailbox and only serializes provider and account',
      () {
    final saved = mostRecentMailbox([
      {
        'mailHistory': [
          {
            'provider': 'qq',
            'account': 'old@qq.com',
            'importedAt': '2026-10-29T10:00:00+08:00'
          }
        ]
      },
      {
        'mailHistory': [
          null,
          {'account': 7},
          {
            'provider': '163',
            'account': ' NEW@163.COM ',
            'importedAt': '2026-10-31T10:00:00+08:00',
            'authorization_code': 'never-store'
          }
        ]
      }
    ]);
    expect(saved!.toJson(), {'provider': '163', 'account': 'new@163.com'});
    expect(() => MailboxIdentity('qq', 'name@163.com'), throwsFormatException);
  });
  testWidgets(
      'new trip loads default account and corresponding saved credential without previous task history',
      (tester) async {
    final prefs = MemoryPreferences()
      ..saved = MailboxIdentity('163', 'default@163.com');
    final engine = FakeProcessor()..saved['163/default@163.com'] = 'TEST-CODE';
    await open(tester, prefs, engine);
    expect(field(tester, 0), 'default@163.com');
    expect(field(tester, 1), 'TEST-CODE');
    expect(tester.widget<TextField>(find.byType(TextField).at(1)).obscureText,
        isTrue);
    expect(find.text('163 个人邮箱'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
      'successful save remembers mailbox for next new trip and never stores code in preferences',
      (tester) async {
    final prefs = MemoryPreferences(), engine = FakeProcessor();
    await open(tester, prefs, engine);
    await tester.enterText(find.byType(TextField).at(0), 'person@qq.com');
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).at(1), 'TEST-CODE');
    await tester.ensureVisible(find.text('保存授权码'));
    await tester.tap(find.text('保存授权码'));
    await tester.pumpAndSettle();
    expect(prefs.writes.single, {'provider': 'qq', 'account': 'person@qq.com'});
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('新建后导入'));
    await tester.pumpAndSettle();
    expect(field(tester, 0), 'person@qq.com');
    expect(field(tester, 1), 'TEST-CODE');
    expect(tester.takeException(), isNull);
  });
  testWidgets(
      'manual account save works without authorization code or a network login',
      (tester) async {
    final prefs = MemoryPreferences(), engine = FakeProcessor();
    await open(tester, prefs, engine);
    await tester.enterText(find.byType(TextField).at(0), 'remember@qq.com');
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('保存为本机默认邮箱'));
    await tester.pumpAndSettle();
    expect(prefs.saved!.account, 'remember@qq.com');
    expect(
        engine.calls.any((c) =>
            c['method'] == 'mail.test' ||
            c['method'] == 'mail.credential.save'),
        isFalse);
  });
  testWidgets('late default lookup cannot replace newly typed account or code',
      (tester) async {
    final prefs = MemoryPreferences()
          ..pendingRead = Completer<MailboxIdentity?>(),
        engine = FakeProcessor();
    await open(tester, prefs, engine);
    await tester.enterText(find.byType(TextField).at(0), 'typed@qq.com');
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).at(1), 'NEW-CODE');
    prefs.pendingRead!.complete(MailboxIdentity('163', 'old@163.com'));
    await tester.pumpAndSettle();
    expect(field(tester, 0), 'typed@qq.com');
    expect(field(tester, 1), 'NEW-CODE');
    expect(tester.takeException(), isNull);
  });
  testWidgets(
      'default account takes precedence over another trip history and save failure is visible',
      (tester) async {
    final prefs = MemoryPreferences()
      ..saved = MailboxIdentity('163', 'default@163.com')
      ..failSave = true;
    await open(tester, prefs, FakeProcessor(),
        previous: {'provider': 'qq', 'account': 'old@qq.com'});
    expect(field(tester, 0), 'default@163.com');
    await tester.tap(find.byTooltip('保存为本机默认邮箱'));
    await tester.pumpAndSettle();
    expect(find.textContaining('默认邮箱未能保存'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
