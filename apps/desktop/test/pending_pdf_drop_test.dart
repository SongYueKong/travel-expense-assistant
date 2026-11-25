import 'dart:async';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:travel_assistant/pending_pdf_drop_area.dart';
import 'package:travel_assistant/pending_dialog.dart';
import 'package:travel_assistant/pending_service.dart';
import 'supplement_pdf_importer_test.dart' show fixture;

void drop(WidgetTester tester, [String path = 'C:/synthetic/invoice.pdf']) {
  tester.widget<DropTarget>(find.byType(DropTarget)).onDragDone!(
      DropDoneDetails(
          files: [DropItemFile(path)],
          localPosition: Offset.zero,
          globalPosition: Offset.zero));
}

Future<void> dialog(
  WidgetTester tester, {
  required Future<Map<String, dynamic>> Function(
          Map<String, dynamic>, PendingItem, List<String>)
      import,
  required Future<void> Function(Map<String, dynamic>) save,
}) async {
  tester.view.physicalSize = const Size(900, 700);
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
                          task: fixture(payments: 0),
                          onSave: save,
                          onResolve: (_, __) async => null,
                          onRetry: (t) async => t,
                          onImportPdfs: import)),
                  child: const Text('open'))))));
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
      'drop and file picker use same callback; hover and compact layout work',
      (tester) async {
    final received = <List<String>>[];
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SizedBox(
                width: 350,
                height: 220,
                child: PendingPdfDropArea(
                    onFiles: (p) async => received.add(p),
                    pickFile: () async => 'C:/synthetic/chosen.pdf')))));
    final target = tester.widget<DropTarget>(find.byType(DropTarget));
    target.onDragEntered!(DropEventDetails(
        localPosition: Offset.zero, globalPosition: Offset.zero));
    await tester.pumpAndSettle();
    expect(find.text('松开鼠标导入 PDF'), findsOneWidget);
    drop(tester);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('选择 PDF 文件'));
    await tester.tap(find.text('选择 PDF 文件'));
    await tester.pumpAndSettle();
    expect(received, [
      ['C:/synthetic/invoice.pdf'],
      ['C:/synthetic/chosen.pdf']
    ]);
    expect(tester.takeException(), isNull);
  });
  testWidgets('busy drop is locked immediately and failures allow retry',
      (tester) async {
    final completion = Completer<void>();
    var calls = 0;
    await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: PendingPdfDropArea(onFiles: (p) async {
      calls++;
      await completion.future;
      throw StateError('识别失败');
    }))));
    drop(tester);
    drop(tester);
    expect(calls, 1);
    await tester.pump();
    expect(tester.widget<DropTarget>(find.byType(DropTarget)).enable, false);
    completion.complete();
    await tester.pumpAndSettle();
    expect(find.textContaining('识别失败'), findsOneWidget);
    expect(tester.widget<DropTarget>(find.byType(DropTarget)).enable, true);
    expect(tester.takeException(), isNull);
  });
  testWidgets('disabled drop does not import', (tester) async {
    var calls = 0;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: PendingPdfDropArea(
                enabled: false,
                onFiles: (p) async {
                  calls++;
                }))));
    drop(tester);
    await tester.pumpAndSettle();
    expect(calls, 0);
  });
  testWidgets('mail drop saves and closes only selected pending item',
      (tester) async {
    Map<String, dynamic>? saved;
    await dialog(tester, import: (task, item, paths) async {
      expect(item.mailSource!['uid'], '0');
      expect(paths, ['C:/synthetic/invoice.pdf']);
      return decidePending(task, item, 'resolved');
    }, save: (task) async {
      saved = task;
    });
    drop(tester);
    await tester.pumpAndSettle();
    expect(pendingItems(saved!).length, 1);
    expect(find.text('待处理（1）'), findsOneWidget);
    expect(find.textContaining('PDF 已导入'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
      'import or save failure leaves selected mail pending and can retry',
      (tester) async {
    var failImport = true, failSave = true;
    await dialog(tester, import: (task, item, paths) async {
      if (failImport) throw StateError('发票号码不一致');
      return decidePending(task, item, 'resolved');
    }, save: (task) async {
      if (failSave) throw StateError('磁盘保存失败');
    });
    drop(tester);
    await tester.pumpAndSettle();
    expect(find.textContaining('发票号码不一致'), findsOneWidget);
    expect(find.text('待处理（2）'), findsOneWidget);
    failImport = false;
    drop(tester);
    await tester.pumpAndSettle();
    expect(find.textContaining('磁盘保存失败'), findsOneWidget);
    expect(find.text('待处理（2）'), findsOneWidget);
    failSave = false;
    drop(tester);
    await tester.pumpAndSettle();
    expect(find.text('待处理（1）'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
