import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:travel_assistant/open_invoice_link.dart';
import 'package:travel_assistant/pending_service.dart';

void main() {
  test(
      'opens only supported official shortlink without putting URL into command',
      () async {
    const url = 'https://a.51fapiao.cn/v/TEST123';
    var called = false;
    await openOfficialInvoiceLink(url, launcher: (program, args, env) async {
      called = true;
      expect(args.join(' '), isNot(contains(url)));
      expect(env['TRAVEL_INVOICE_URL'], url);
      return ProcessResult(0, 0, '', '');
    });
    expect(called, isTrue);
    for (final invalid in [
      'http://a.51fapiao.cn/v/TEST',
      'https://a.51fapiao.cn.evil.test/v/TEST',
      'https://user@a.51fapiao.cn/v/TEST',
      'https://a.51fapiao.cn:8443/v/TEST',
      'https://a.51fapiao.cn/v/TEST?cmd=abc'
    ]) {
      expect(isOfficialInvoiceLink(invalid), isFalse);
    }
  });
  test(
      'mail pending official URL survives decisions and keeps old entries compatible',
      () {
    final task = <String, dynamic>{
      'mailHistory': [
        {
          'account': 'fake@example.test',
          'pending': [
            {
              'subject': '测试发票',
              'reason': '网页下载',
              'uid': '1',
              'downloadUrl': 'https://a.51fapiao.cn/v/TEST'
            }
          ]
        }
      ]
    };
    final item = pendingItems(task).single;
    expect(item.isMaterial, isFalse);
    expect(item.downloadUrl, 'https://a.51fapiao.cn/v/TEST');
    expect(PendingItem.fromJson(item.toJson()).downloadUrl, item.downloadUrl);
    expect(
        PendingItem.fromJson({
          'id': 'legacy',
          'kind': 'mail',
          'title': '旧邮件',
          'reason': '旧提示'
        }).downloadUrl,
        isNull);
  });
}
