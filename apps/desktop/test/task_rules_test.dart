import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:travel_assistant/task_rules.dart';

TripTask sampleTask() => {
      'id': 'original',
      'name': '北京出差',
      'toleranceCents': 100,
      'groups': [
        {
          'name': '酒店发票',
          'invoiceCents': 10000,
          'confirmed': true,
          'complete': true,
          'document': {'type': 'invoice', 'totalCents': 10000},
          'payments': [
            {'path': 'C:/test/payment.png', 'cents': 9950}
          ],
          'itineraries': <String>[]
        }
      ],
      'unmatchedPayments': [
        {'path': 'C:/test/unmatched.png', 'cents': 2000}
      ],
      'pdfMaterials': [
        {'path': 'C:/test/invoice.pdf'}
      ],
      'mailHistory': [
        {'provider': 'qq', 'account': 'test@qq.com'}
      ],
    };

void main() {
  test('names are trimmed and empty or control-only names are rejected', () {
    expect(validateTaskName('  北京出差  '), '北京出差');
    expect(validateTaskName('报账："北京" 10月'), '报账："北京" 10月');
    for (final name in ['', '  ', '北京\n出差', '北京\x00出差']) {
      expect(() => validateTaskName(name), throwsFormatException);
    }
  });
  test('duplicate names are checked excluding the current task', () {
    final tasks = [
      {'id': 'one', 'name': 'Trip'},
      {'id': 'two', 'name': '上海出差'}
    ];
    expect(
        () => requireAvailableTaskName('trip', tasks), throwsFormatException);
    expect(() => requireAvailableTaskName('上海出差', tasks, exceptId: 'one'),
        throwsFormatException);
    requireAvailableTaskName('Trip', tasks, exceptId: 'one');
  });
  test('suggested copy names avoid existing copies', () {
    expect(suggestDuplicateName('北京出差', []), '北京出差（副本）');
    expect(
        suggestDuplicateName('北京出差', [
          {'name': '北京出差（副本）'},
          {'name': '北京出差（副本 2）'}
        ]),
        '北京出差（副本 3）');
  });
  test(
      'copy keeps evidence but resets confirmation and owns independent nested data',
      () {
    final source = sampleTask(), before = jsonEncode(sampleTask());
    final copy = duplicateTask(source, '北京出差（副本）');
    expect(copy['id'], isNot(source['id']));
    expect(copy['name'], '北京出差（副本）');
    expect(copy['copiedFromTaskId'], 'original');
    expect(copy['groups'][0]['confirmed'], isFalse);
    expect(copy['groups'][0]['complete'], isFalse);
    expect(copy['groups'][0]['payments'][0]['cents'], 9950);
    expect(copy['pdfMaterials'][0]['path'], 'C:/test/invoice.pdf');
    copy['groups'][0]['payments'][0]['cents'] = 1;
    copy['unmatchedPayments'][0]['cents'] = 1;
    expect(jsonEncode(source), before);
  });
}
