import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:travel_assistant/pending_dialog.dart';
import 'package:travel_assistant/pending_service.dart';
import 'package:travel_assistant/association_service.dart';
import 'association_service_test.dart' show fixture;

Future<void> open(WidgetTester tester,
    {required Future<void> Function(Map<String, dynamic>) save,
    Future<Map<String, dynamic>?> Function(Map<String, dynamic>, PendingItem)?
        resolve,
    Size size = const Size(1280, 900)}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(MaterialApp(
      home: Builder(
          builder: (context) => Scaffold(
              body: TextButton(
                  onPressed: () => showDialog(
                      context: context,
                      builder: (_) => PendingIssuesDialog(
                          task: fixture(),
                          onSave: save,
                          onResolve: resolve ?? (_, __) async => null,
                          onRetry: (t) async => t)),
                  child: const Text('打开待办'))))));
  await tester.tap(find.text('打开待办'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
      'details preview ignore and restore save each change without completing invoice evidence',
      (tester) async {
    final saved = <Map<String, dynamic>>[];
    await open(tester, save: (t) async => saved.add(copyTask(t)));
    expect(find.text('识别／修正金额：¥100.00'), findsOneWidget);
    expect(find.byType(InteractiveViewer), findsOneWidget);
    await tester.tap(find.text('忽略此项'));
    await tester.pumpAndSettle();
    expect(saved.length, 1);
    expect(saved.last['ignoredMaterials'][0]['hash'], 'a');
    expect(saved.last['groups'][0]['suggestionComplete'], isFalse);
    await tester.tap(find.text('已忽略／已解决（1）'));
    await tester.pumpAndSettle();
    expect(find.text('状态：已忽略'), findsOneWidget);
    await tester.tap(find.text('恢复待处理'));
    await tester.pumpAndSettle();
    expect(saved.length, 2);
    expect(saved.last['ignoredMaterials'], isEmpty);
    expect(pendingItems(saved.last).length, 2);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
      'resolve opens actual association callback then removes only assigned pending evidence',
      (tester) async {
    Map<String, dynamic>? saved;
    await open(tester,
        save: (t) async => saved = t,
        resolve: (task, item) async {
          expect(item.material!['hash'], 'a');
          return (AssociationEditor(task, 0)..choose(0, 'a')).build();
        });
    await tester.tap(find.text('处理／关联'));
    await tester.pumpAndSettle();
    expect(saved!['groups'][0]['payments'][0]['hash'], 'a');
    expect(pendingItems(saved!).single.material!['hash'], 'b');
    expect(saved!['groups'][0]['confirmed'], isFalse);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
      'save failure preserves pending item and shows error at small window size',
      (tester) async {
    await open(tester,
        save: (_) async => throw StateError('保存失败测试'),
        size: const Size(800, 650));
    await tester.tap(find.text('忽略此项'));
    await tester.pumpAndSettle();
    expect(find.textContaining('保存失败测试'), findsOneWidget);
    expect(find.text('待处理（2）'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('cancelled resolution does not save or modify task',
      (tester) async {
    var saves = 0;
    final before = jsonEncode(fixture());
    await open(tester, save: (_) async {
      saves++;
    });
    await tester.tap(find.text('处理／关联'));
    await tester.pumpAndSettle();
    expect(saves, 0);
    expect(jsonEncode(fixture()), before);
    expect(tester.takeException(), isNull);
  });
}
