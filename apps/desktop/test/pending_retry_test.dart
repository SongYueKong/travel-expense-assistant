import 'package:flutter_test/flutter_test.dart';
import 'package:travel_assistant/import_service.dart';
import 'package:travel_assistant/material_merge_service.dart';
import 'package:travel_assistant/pending_service.dart';
import 'package:travel_assistant/services.dart';

class RetryFiles implements ProcessingClient {
  bool fail = true;
  int calls = 0;
  @override
  Future<dynamic> call(String method, Map<String, dynamic> params) async {
    calls++;
    if (fail) throw StateError('文件暂不可读');
    return {
      'path': params['path'],
      'name': 'bad.pdf',
      'hash': 'recovered',
      'document': {'type': 'unknown'},
      'text': '恢复可读但尚未分类'
    };
  }
}

Future<Map<String, dynamic>> failedTask(RetryFiles client) async {
  final imported = await FolderImporter(client, 'unused')
      .importPaths(['C:/test/bad.pdf'], 100);
  return {
    'id': 'retry',
    'name': '重试',
    'toleranceCents': 100,
    'groups': [],
    'unmatchedMaterials': imported['unmatchedMaterials'],
    'unmatchedPayments': [],
    'importIssues': imported['issues']
  };
}

void main() {
  test(
      'unreadable file stays pending across retries and can recover without stale error',
      () async {
    final client = RetryFiles();
    var task = await failedTask(client);
    expect(pendingItems(task).length, 1);
    expect(pendingItems(task).single.material!['failedInspection'], isTrue);
    task = await MaterialMerger(client, 'unused').merge(task);
    expect(pendingItems(task).length, 1);
    expect(task['importIssues'].length, 1);
    client.fail = false;
    task = await MaterialMerger(client, 'unused').merge(task);
    expect(task['importIssues'], isEmpty);
    expect(task['unmatchedMaterials'].length, 1);
    expect(
        pendingItems(task).single.material!['failedInspection'], isNot(true));
    expect(client.calls, 3);
  });
  test(
      'ignored failed file is excluded before read and can be restored for retry',
      () async {
    final client = RetryFiles();
    var task = await failedTask(client);
    task = decidePending(task, pendingItems(task).single, 'ignored');
    final calls = client.calls;
    task = await MaterialMerger(client, 'unused').merge(task, mailFiles: [
      {'path': 'C:/test/bad.pdf', 'name': 'bad.pdf'}
    ]);
    expect(pendingItems(task), isEmpty);
    expect(client.calls, calls);
    task = decidePending(
        task, pendingItems(task, includeHandled: true).single, 'restore');
    client.fail = false;
    task = await MaterialMerger(client, 'unused').merge(task);
    expect(task['importIssues'], isEmpty);
    expect(client.calls, calls + 1);
  });
  test('unattempted historical error remains until user handles it', () async {
    final client = RetryFiles();
    final task = {
      'id': 'legacy',
      'name': '旧任务',
      'toleranceCents': 100,
      'groups': [],
      'unmatchedPayments': [],
      'unmatchedMaterials': [],
      'importIssues': ['原目录已移动，请补充材料']
    };
    final updated = await MaterialMerger(client, 'unused').merge(task);
    expect(client.calls, 0);
    expect(pendingItems(updated).single.reason, '原目录已移动，请补充材料');
  });
}
