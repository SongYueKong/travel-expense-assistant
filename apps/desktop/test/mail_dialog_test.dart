import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:travel_assistant/mail_dialog.dart';
import 'package:travel_assistant/services.dart';
import 'package:travel_assistant/trip_dates.dart';

class FakeProcessor implements ProcessingClient {
  final List<Map<String, dynamic>> calls = [];
  final Map<String, String> saved = {};
  Future<dynamic> Function(Map<String, dynamic>)? lookup;
  bool failSave = false, failTest = false;
  Completer<void>? saveDelay;
  String key(Map<String, dynamic> p) =>
      '${p['provider']}/${p['account'].toString().trim().toLowerCase()}';
  @override
  Future<dynamic> call(String method, Map<String, dynamic> params) async {
    calls.add({'method': method, 'params': params});
    if (method == 'mail.credential.get') {
      if (lookup != null) return lookup!(params);
      final value = saved[key(params)];
      return value == null
          ? {'found': false}
          : {'found': true, 'authorization_code': value};
    }
    if (method == 'mail.credential.save') {
      if (failSave) throw StateError('本地凭据存储暂不可用');
      if (saveDelay != null) await saveDelay!.future;
      saved[key(params)] = params['authorization_code'];
      return {'saved': true};
    }
    if (method == 'mail.credential.delete') {
      return {'deleted': saved.remove(key(params)) != null};
    }
    if (method == 'mail.test') {
      if (failTest) throw StateError('邮箱认证失败');
      return {
        'folders': [
          {'mailbox': 'INBOX', 'name': '收件箱'}
        ]
      };
    }
    if (method == 'mail.start') return {'jobId': 'local-test'};
    if (method == 'mail.status') {
      return {
        'state': 'done',
        'complete': true,
        'account': 'test@qq.com',
        'startDate': '2026-10-01',
        'endDate': '2026-10-30',
        'downloaded': 1,
        'duplicates': 0,
        'files': [
          {'path': 'local-only.pdf', 'filename': '发票.pdf'}
        ],
        'pending': [],
        'failures': []
      };
    }
    throw StateError('Unexpected method');
  }
}

Future<void> openDialog(
    WidgetTester tester, FakeProcessor client, void Function(dynamic) result,
    {Map<String, dynamic>? previous, TripPeriod? tripPeriod}) async {
  await tester.pumpWidget(MaterialApp(
      home: Builder(
          builder: (context) => Scaffold(
              body: TextButton(
                  onPressed: () async {
                    result(await showDialog<Map<String, dynamic>>(
                        context: context,
                        builder: (_) => MailImportDialog(
                            engine: client,
                            previous: previous,
                            tripPeriod: tripPeriod)));
                  },
                  child: const Text('打开邮箱'))))));
  await tester.tap(find.text('打开邮箱'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
      'editing code during pending explicit save does not claim new input was saved',
      (tester) async {
    final client = FakeProcessor()..saveDelay = Completer<void>();
    await openDialog(tester, client, (_) {});
    await tester.enterText(find.byType(TextField).at(0), 'test@qq.com');
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).at(1), 'CODE-BEFORE-SAVE');
    await tester.ensureVisible(find.text('保存授权码'));
    await tester.tap(find.text('保存授权码'));
    await tester.pump();
    await tester.enterText(find.byType(TextField).at(1), 'CODE-AFTER-SAVE');
    client.saveDelay!.complete();
    await tester.pumpAndSettle();
    expect(client.saved['qq/test@qq.com'], 'CODE-BEFORE-SAVE');
    expect(
        tester.widget<TextField>(find.byType(TextField).at(1)).controller!.text,
        'CODE-AFTER-SAVE');
    expect(find.text('已保存先前输入的授权码，当前修改尚未保存'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
      'saved code is loaded masked for previous account and can be forgotten',
      (tester) async {
    final client = FakeProcessor()..saved['qq/test@qq.com'] = 'SAVED-TEST-CODE';
    await openDialog(tester, client, (_) {},
        previous: {'provider': 'qq', 'account': 'test@qq.com'});
    expect(
        tester.widget<TextField>(find.byType(TextField).at(1)).controller!.text,
        'SAVED-TEST-CODE');
    expect(tester.widget<TextField>(find.byType(TextField).at(1)).obscureText,
        isTrue);
    await tester.ensureVisible(find.text('忘记授权码'));
    await tester.tap(find.text('忘记授权码'));
    await tester.pumpAndSettle();
    expect(client.saved, isEmpty);
    expect(
        tester.widget<TextField>(find.byType(TextField).at(1)).controller!.text,
        isEmpty);
    expect(find.text('已删除本机保存的授权码'), findsOneWidget);
  });

  testWidgets('explicit save and successful connection remember the code',
      (tester) async {
    final client = FakeProcessor();
    await openDialog(tester, client, (_) {});
    await tester.enterText(find.byType(TextField).at(0), 'test@qq.com');
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).at(1), 'FIRST-TEST-CODE');
    await tester.ensureVisible(find.text('保存授权码'));
    await tester.tap(find.text('保存授权码'));
    await tester.pumpAndSettle();
    expect(client.saved['qq/test@qq.com'], 'FIRST-TEST-CODE');
    await tester.enterText(find.byType(TextField).at(1), 'SECOND-TEST-CODE');
    await tester.ensureVisible(find.text('测试连接并读取文件夹'));
    await tester.tap(find.text('测试连接并读取文件夹'));
    await tester.pumpAndSettle();
    expect(client.saved['qq/test@qq.com'], 'SECOND-TEST-CODE');
    expect(find.text('授权码已在本机加密保存'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'late lookup from another account cannot overwrite current account',
      (tester) async {
    final pending = Completer<dynamic>();
    final client = FakeProcessor();
    client.lookup = (p) async => p['account'] == 'first@qq.com'
        ? pending.future
        : {'found': true, 'authorization_code': 'SECOND-ACCOUNT-CODE'};
    await openDialog(tester, client, (_) {});
    await tester.enterText(find.byType(TextField).at(0), 'first@qq.com');
    await tester.pump();
    await tester.enterText(find.byType(TextField).at(0), 'second@qq.com');
    await tester.pumpAndSettle();
    pending.complete({'found': true, 'authorization_code': 'OLD-ACCOUNT-CODE'});
    await tester.pumpAndSettle();
    expect(
        tester.widget<TextField>(find.byType(TextField).at(1)).controller!.text,
        'SECOND-ACCOUNT-CODE');
    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('163 个人邮箱').last);
    await tester.pumpAndSettle();
    expect(
        tester.widget<TextField>(find.byType(TextField).at(1)).controller!.text,
        isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'pending saved-code lookup does not replace manually entered code',
      (tester) async {
    final pending = Completer<dynamic>(), client = FakeProcessor();
    client.lookup = (_) => pending.future;
    await openDialog(tester, client, (_) {});
    await tester.enterText(find.byType(TextField).at(0), 'test@qq.com');
    await tester.pump();
    await tester.enterText(find.byType(TextField).at(1), 'MANUALLY-ENTERED');
    pending.complete({'found': true, 'authorization_code': 'STORED-TEST'});
    await tester.pumpAndSettle();
    expect(
        tester.widget<TextField>(find.byType(TextField).at(1)).controller!.text,
        'MANUALLY-ENTERED');
  });

  testWidgets('failed login does not overwrite existing credential',
      (tester) async {
    final client = FakeProcessor()
      ..saved['qq/test@qq.com'] = 'OLD-VALID-CODE'
      ..failTest = true;
    await openDialog(tester, client, (_) {},
        previous: {'provider': 'qq', 'account': 'test@qq.com'});
    await tester.enterText(find.byType(TextField).at(1), 'INVALID-TEST-CODE');
    await tester.ensureVisible(find.text('测试连接并读取文件夹'));
    await tester.tap(find.text('测试连接并读取文件夹'));
    await tester.pumpAndSettle();
    expect(client.saved['qq/test@qq.com'], 'OLD-VALID-CODE');
    expect(client.calls.where((c) => c['method'] == 'mail.credential.save'),
        isEmpty);
  });

  testWidgets(
      'failed local save is visible and imported report never contains code',
      (tester) async {
    final client = FakeProcessor()..failSave = true;
    dynamic received;
    await openDialog(tester, client, (value) => received = value);
    await tester.enterText(find.byType(TextField).at(0), 'test@qq.com');
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).at(1), 'TEST-ONLY-NO-LEAK');
    await tester.ensureVisible(find.text('获取并导入'));
    await tester.tap(find.text('获取并导入'));
    await tester.pumpAndSettle();
    expect(received, isNull);
    expect(find.textContaining('授权码未能保存'), findsOneWidget);
    await tester.ensureVisible(find.text('导入已获取的 1 份 PDF'));
    await tester.tap(find.text('导入已获取的 1 份 PDF'));
    await tester.pumpAndSettle();
    expect(received, isNotNull);
    expect(received.toString(), isNot(contains('TEST-ONLY-NO-LEAK')));
  });
  testWidgets('missing credentials do not issue a request', (tester) async {
    final client = FakeProcessor();
    await openDialog(tester, client, (_) {});
    await tester.ensureVisible(find.text('获取并导入'));
    await tester.tap(find.text('获取并导入'));
    await tester.pumpAndSettle();
    expect(client.calls, isEmpty);
    expect(find.text('请填写完整邮箱地址和客户端授权码'), findsOneWidget);
  });

  testWidgets('successful fetch returns safe report without authorization code',
      (tester) async {
    final client = FakeProcessor();
    dynamic received;
    await openDialog(tester, client, (value) => received = value);
    await tester.enterText(find.byType(TextField).at(0), 'test@qq.com');
    await tester.enterText(find.byType(TextField).at(1), 'TEST-ONLY-SECRET');
    await tester.ensureVisible(find.text('获取并导入'));
    await tester.tap(find.text('获取并导入'));
    await tester.pumpAndSettle();
    expect(received, isNotNull);
    expect(received['report']['account'], 'test@qq.com');
    expect(received.toString(), isNot(contains('TEST-ONLY-SECRET')));
    final request =
        client.calls.firstWhere((c) => c['method'] == 'mail.start')['params'];
    expect(request['authorization_code'], 'TEST-ONLY-SECRET');
    expect(request['folders'], ['INBOX']);
    expect(client.saved['qq/test@qq.com'], 'TEST-ONLY-SECRET');
    expect(tester.takeException(), isNull);
  });
}
