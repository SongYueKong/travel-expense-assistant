import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:travel_assistant/pending_service.dart';

const origin = {
  'account': 'test@qq.com',
  'folder': 'INBOX',
  'uidValidity': '100',
  'uid': '1'
};
const missing = 'invoice.ofd：ZIP 内未找到 PDF，需从原邮件取得 PDF 后补充';
Map<String, dynamic> taskFixture() => {
      'groups': <dynamic>[],
      'mailSources': [
        {'path': 'C:/synthetic/invoice.pdf', ...origin}
      ],
      'mailHistory': [
        {
          'account': 'test@qq.com',
          'pending': <Map<String, dynamic>>[
            {...origin, 'reason': missing}
          ]
        }
      ]
    };

void main() {
  test(
      'existing same-message PDF removes old and new no-PDF notes without modifying task',
      () {
    for (final coded in [false, true]) {
      final task = taskFixture();
      if (coded) {
        task['mailHistory'][0]['pending'][0]['code'] = 'archive_no_pdf';
      }
      task['mailHistory'][0]['pending'][0].remove('account');
      final before = jsonEncode(task);
      expect(pendingItems(task), isEmpty);
      expect(jsonEncode(task), before);
    }
  });
  test(
      'stored PDF catalog sources and group mail sources also identify the same message',
      () {
    for (final useGroup in [false, true]) {
      final task = taskFixture();
      task['mailSources'] = <dynamic>[];
      if (useGroup) {
        task['groups'] = [
          {'path': 'C:/synthetic/invoice.pdf', 'mailSource': origin}
        ];
      } else {
        task['pdfMaterials'] = [
          {
            'path': 'C:/synthetic/invoice.pdf',
            'pdfSources': [origin]
          }
        ];
      }
      expect(pendingItems(jsonDecode(jsonEncode(task))), isEmpty);
    }
  });
  test(
      'different message, account, folder, validity or missing identity cannot hide notes',
      () {
    for (final change in [
      {'uid': '2'},
      {'account': 'other@qq.com'},
      {'folder': 'Other'},
      {'uidValidity': '101'},
      {'uidValidity': null}
    ]) {
      final task = taskFixture();
      task['mailHistory'][0]['pending'][0].addAll(change);
      expect(pendingItems(task).length, 1);
    }
    final noPdf = taskFixture()..['mailSources'] = <dynamic>[];
    expect(pendingItems(noPdf).length, 1);
  });
  test(
      'broken, encrypted and failed PDF notes remain despite another usable PDF',
      () {
    final task = taskFixture();
    task['mailHistory'][0]['pending'].addAll([
      {...origin, 'reason': 'ZIP 附件无法读取，可能已损坏'},
      {...origin, 'reason': 'ZIP 中的 PDF 已加密'},
      {...origin, 'reason': '标为 PDF 的附件内容无法识别'},
      {...origin, 'reason': missing, 'code': 'other_failure'}
    ]);
    expect(pendingItems(task).length, 4);
    task['mailHistory'][0]['failures'] = [
      {...origin, 'reason': missing}
    ];
    expect(pendingItems(task).length, 5);
  });
  test('a PDF that failed inspection cannot satisfy the message', () {
    final task = taskFixture();
    task['pdfMaterials'] = [
      {'path': 'C:/synthetic/invoice.pdf', 'failedInspection': true}
    ];
    expect(pendingItems(task).where((i) => i.kind == 'mail').length, 1);
  });
}
