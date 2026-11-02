import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:travel_assistant/mail_providers.dart';
import 'package:travel_assistant/app_preferences.dart';
import 'package:travel_assistant/open_folder.dart';
import 'mail_dialog_test.dart' show FakeProcessor, openDialog;

void main() {
  test(
      'all domestic presets validate infer and persist without cross-provider acceptance',
      () {
    for (final p in mailProviders) {
      for (final domain in p.domains) {
        final account = ' Test@$domain ';
        expect(validMailbox(p.id, account), isTrue);
        expect(providerForAccount(account), p.id);
        final identity = MailboxIdentity.fromJson({'account': account});
        expect(identity.provider, p.id);
        expect(
            MailboxIdentity.fromJson(jsonDecode(jsonEncode(identity.toJson())))
                .account,
            'test@$domain');
        expect(validMailbox(p.id, 'test@$domain.attacker'), isFalse);
      }
    }
    expect(validMailbox('qq', 'a@126.com'), isFalse);
    expect(validMailbox('126', 'a\n@126.com'), isFalse);
  });
  testWidgets(
      'new provider selection changes address hint and uses independent credential identity',
      (tester) async {
    final engine = FakeProcessor();
    await openDialog(tester, engine, (_) {},
        previous: {'provider': '126', 'account': 'test@126.com'});
    expect(find.text('126 个人邮箱'), findsOneWidget);
    expect(find.text('例如 name@126.com'), findsOneWidget);
    await tester.enterText(find.byType(TextField).last, 'TEST-CODE');
    await tester.ensureVisible(find.text('获取并导入'));
    await tester.tap(find.text('获取并导入'));
    await tester.pumpAndSettle();
    final request =
        engine.calls.singleWhere((c) => c['method'] == 'mail.start')['params'];
    expect(request['provider'], '126');
    expect(request['account'], 'test@126.com');
  });
  test(
      'explorer paths normalize mixed separators trailing slash and preserve Chinese spaces',
      () {
    expect(windowsFolderArgument('D:/差旅记录/北京 出差/'), r'D:\差旅记录\北京 出差');
    expect(windowsFolderArgument(r'\\server\共享目录/记录/'), r'\\server\共享目录\记录');
    expect(windowsFolderArgument('D:/'), r'D:\');
  });
  test('missing directory gives actionable failure before launching explorer',
      () async {
    final root = await Directory.systemTemp.createTemp('missing-folder-check-');
    await expectLater(openFolder('${root.path}/not-existing'),
        throwsA(isA<FileSystemException>()));
  });
}
