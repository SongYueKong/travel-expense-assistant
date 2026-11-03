import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:travel_assistant/exported_pdf_dialog.dart';

void main() {
  test('export history uses archived paths and deduplicates recent file', () {
    final task = {
      'exports': [
        null,
        {'path': 'C:/trip/old.pdf'},
        {'path': r'C:\trip\new.pdf', 'name': '新版.pdf'},
        {'path': 'not-a-pdf.jpg'}
      ]
    };
    final files = exportedPdfFiles(task,
        recent: {'path': 'c:/trip/new.pdf', 'name': '最新.pdf'});
    expect(files.map((file) => file['name']), ['最新.pdf', 'old.pdf']);
    expect(exportedPdfFiles({}), isEmpty);
  });

  testWidgets(
      'selecting a historical export opens its file with the default app',
      (tester) async {
    final opened = <String>[];
    await showHistory(tester, (path) async {
      opened.add(path);
    });
    expect(find.byType(InteractiveViewer), findsNothing);
    await tester.tap(find.text('old.pdf'));
    await tester.pumpAndSettle();
    expect(opened, ['C:/old.pdf']);
    expect(find.byType(ExportedPdfDialog), findsNothing);
  });

  testWidgets('failed open stays in history and allows another selection',
      (tester) async {
    var fail = true;
    await showHistory(tester, (_) async {
      if (fail) throw StateError('请设置 PDF 默认应用');
    });
    await tester.tap(find.text('new.pdf'));
    await tester.pumpAndSettle();
    expect(find.textContaining('请设置 PDF 默认应用'), findsOneWidget);
    fail = false;
    await tester.tap(find.text('old.pdf'));
    await tester.pumpAndSettle();
    expect(find.byType(ExportedPdfDialog), findsNothing);
  });

  testWidgets('pending open prevents duplicate launches', (tester) async {
    final pending = Completer<void>();
    var calls = 0;
    await showHistory(tester, (_) {
      calls++;
      return pending.future;
    });
    await tester.tap(find.text('new.pdf'));
    await tester.pump();
    expect(
        tester.widget<ListTile>(find.byType(ListTile).last).enabled, isFalse);
    expect(calls, 1);
    pending.complete();
    await tester.pumpAndSettle();
    expect(find.byType(ExportedPdfDialog), findsNothing);
  });
}

Future<void> showHistory(
    WidgetTester tester, Future<void> Function(String) open) async {
  await tester.pumpWidget(MaterialApp(
      home: Builder(
          builder: (context) => Scaffold(
              body: TextButton(
                  onPressed: () => showDialog<void>(
                      context: context,
                      builder: (_) => ExportedPdfDialog(files: const [
                            {'path': 'C:/new.pdf', 'name': 'new.pdf'},
                            {'path': 'C:/old.pdf', 'name': 'old.pdf'}
                          ], openFile: open)),
                  child: const Text('历史导出'))))));
  await tester.tap(find.text('历史导出'));
  await tester.pumpAndSettle();
}
