import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:travel_assistant/pending_service.dart';
import 'package:travel_assistant/association_service.dart';
import 'package:travel_assistant/export_service.dart';
import 'association_service_test.dart' show fixture, payment, itinerary;

void main() {
  test(
      'duplicate pending buckets show one item and assigned materials stay out',
      () {
    final task = fixture();
    task['unmatchedMaterials'] = [payment('a')];
    expect(pendingItems(task).length, 2);
    task['groups'][0]['payments'] = [
      {...payment('a'), 'cents': 10000}
    ];
    expect(pendingItems(task).single.material!['hash'], 'b');
  });
  test(
      'ignore persists in JSON and restore returns original evidence without changing source or costs',
      () {
    final source = fixture(), before = jsonEncode(fixture());
    final item = pendingItems(source).first;
    var task = decidePending(source, item, 'ignored');
    task = jsonDecode(jsonEncode(task));
    expect(pendingItems(task).length, 1);
    expect(task['ignoredMaterials'].length, 1);
    expect(task['groups'], source['groups']);
    expect(jsonEncode(source), before);
    expect(() => buildExportManifest(materialRecords(task['groups']), 100),
        throwsStateError);
    final ignored = pendingItems(task, includeHandled: true)
        .singleWhere((i) => i.state == 'ignored');
    task = decidePending(task, ignored, 'restore');
    expect(pendingItems(task).length, 2);
    expect(task['ignoredMaterials'], isEmpty);
    expect(task['unmatchedPayments'].map((m) => m['hash']), contains('a'));
  });
  test(
      'ignored itinerary stays out of association candidates even though PDF library retains it',
      () {
    final source = fixture(), m = itinerary('trip');
    source['unmatchedMaterials'] = [m];
    source['pdfMaterials'] = [m];
    final item =
        pendingItems(source).singleWhere((i) => i.material?['hash'] == 'trip');
    final ignored = decidePending(source, item, 'ignored');
    expect(AssociationEditor(ignored, 0).itineraries, isEmpty);
    expect(ignored['pdfMaterials'], [m]);
  });
  test(
      'actual association resolves pending automatically; material cannot be marked solved or ignored while assigned',
      () {
    final source = fixture(), item = pendingItems(source).first;
    expect(() => decidePending(source, item, 'resolved'), throwsStateError);
    final editor = AssociationEditor(source, 0)..choose(0, 'a');
    final updated = editor.build();
    expect(
        pendingItems(updated).every((i) => i.material?['hash'] != 'a'), isTrue);
    expect(() => decidePending(updated, item, 'ignored'), throwsStateError);
  });
  test('import and mail notes support independent ignore resolve and restore',
      () {
    final source = fixture();
    source['unmatchedPayments'] = [];
    source['importIssues'] = ['坏文件.pdf: 无法读取'];
    source['mailHistory'] = [
      {
        'account': 'test@qq.com',
        'pending': [
          {'uid': '1', 'subject': '电子发票', 'reason': '仅下载链接'}
        ]
      }
    ];
    var task = decidePending(source, pendingItems(source).first, 'resolved');
    expect(pendingItems(task).length, 1);
    task = decidePending(task, pendingItems(task).single, 'ignored');
    expect(pendingItems(task), isEmpty);
    final handled = pendingItems(task, includeHandled: true);
    expect(handled.map((i) => i.state).toSet(), {'resolved', 'ignored'});
    task = decidePending(task, handled.first, 'restore');
    expect(pendingItems(task).length, 1);
  });
}
