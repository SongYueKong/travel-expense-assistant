import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:travel_assistant/pdf_library_dialog.dart';
import 'package:travel_assistant/pdf_preview_panel.dart';

Map<String, dynamic> libraryTask() => {
      'groups': <dynamic>[],
      'pdfMaterials': [
        {
          'path': 'C:/test/a.pdf',
          'hash': 'a',
          'name': 'A发票.pdf',
          'document': {'type': 'invoice', 'number': '123', 'totalCents': 10000},
          'pdfSources': [
            {
              'account': 'test@qq.com',
              'folder': 'INBOX',
              'uid': '1',
              'subject': '酒店发票邮件',
              'sender': '测试酒店',
              'filename': 'A发票.pdf'
            }
          ]
        },
        {
          'path': 'C:/test/b.pdf',
          'hash': 'b',
          'name': 'B行程单.pdf',
          'document': {'type': 'itinerary', 'totalCents': 10000, 'trips': []}
        },
        {
          'path': 'C:/test/c.pdf',
          'hash': 'c',
          'name': 'C未识别.pdf',
          'document': {'type': 'unknown'}
        },
      ]
    };

Future<Map<String, dynamic>> preview(String path, int page) async => {
      'path': 'C:/test/render.png',
      'pages': 2,
      'text': '票据内容',
      'document': <String, dynamic>{},
    };

Future<void> openLibrary(WidgetTester tester, Map<String, dynamic> task,
    {Size size = const Size(1280, 900), DocumentPreviewLoader? load}) async {
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
                      builder: (_) => PdfLibraryDialog(
                          task: task, loadPreview: load ?? preview)),
                  child: const Text('材料清单'))))));
  await tester.tap(find.text('材料清单'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('ZIP origin is visible next to the original email source',
      (tester) async {
    final task = libraryTask();
    task['pdfMaterials'][0]['pdfSources'][0].addAll(
        {'archiveFilename': 'rail.zip', 'archiveMember': 'folder/rail.pdf'});
    await openLibrary(tester, task);
    await tester.tap(find.byKey(const ValueKey('pdf-file-a')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('邮件来源（1 处）'));
    await tester.pumpAndSettle();
    expect(find.textContaining('压缩包：rail.zip'), findsOneWidget);
    expect(find.textContaining('包内文件：folder/rail.pdf'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'all PDFs include unassociated files and preserve source data while browsing',
      (tester) async {
    final task = libraryTask(), original = jsonEncode(libraryTask());
    final calls = <String>[];
    await openLibrary(tester, task, load: (path, page) async {
      calls.add(path);
      return preview(path, page);
    });
    expect(find.textContaining('共 3 份 PDF'), findsOneWidget);
    expect(find.byKey(const ValueKey('pdf-file-c')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('pdf-file-b')));
    await tester.pumpAndSettle();
    expect(calls.last, 'C:/test/b.pdf');
    expect(find.text('放大行程单'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('pdf-file-a')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('邮件来源（1 处）'));
    await tester.pumpAndSettle();
    expect(find.text('酒店发票邮件'), findsOneWidget);
    expect(find.textContaining('邮箱：test@qq.com'), findsOneWidget);
    expect(jsonEncode(task), original);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'search, file type and mail-only filters work at smaller window size',
      (tester) async {
    await openLibrary(tester, libraryTask(), size: const Size(800, 600));
    await tester.enterText(find.byKey(const ValueKey('pdf-search')), '酒店发票邮件');
    await tester.pumpAndSettle();
    expect(find.textContaining('显示 1 / 共 3'), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('pdf-search')), '');
    await tester.pumpAndSettle();
    await tester.tap(find.text('仅看邮件导入'));
    await tester.pumpAndSettle();
    expect(find.textContaining('显示 1 / 共 3'), findsOneWidget);
    await tester.tap(find.text('仅看邮件导入'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('行程单').last);
    await tester.pumpAndSettle();
    expect(find.textContaining('显示 1 / 共 3'), findsOneWidget);
    expect(find.byKey(const ValueKey('pdf-file-b')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('bad PDF stays in list and an empty task has a clear state',
      (tester) async {
    await openLibrary(tester, libraryTask(),
        load: (_, __) async => throw StateError('文件暂不可读'));
    expect(find.textContaining('预览未能读取'), findsOneWidget);
    expect(find.byKey(const ValueKey('pdf-file-a')), findsOneWidget);
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
    await openLibrary(tester, {'groups': <dynamic>[]});
    expect(find.text('当前任务尚无 PDF 材料，请先从邮箱或本地导入。'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('late result from previous PDF cannot replace current preview',
      (tester) async {
    final old = Completer<Map<String, dynamic>>();
    Future<Map<String, dynamic>> load(String path, int page) async =>
        path == 'C:/test/old.pdf'
            ? old.future
            : {
                'path': 'C:/test/new.png',
                'pages': 1,
                'text': '新文件',
                'document': {'number': 'NEW'}
              };
    Widget view(String path) => MaterialApp(
        home: Scaffold(
            body: SingleChildScrollView(
                child: PdfPreviewPanel(
                    material: {'path': path, 'name': path},
                    title: 'PDF',
                    loadPreview: load,
                    information: (d) => Text('票号 ${d['number']}')))));
    await tester.pumpWidget(view('C:/test/old.pdf'));
    await tester.pump();
    await tester.pumpWidget(view('C:/test/new.pdf'));
    await tester.pumpAndSettle();
    expect(find.text('票号 NEW'), findsOneWidget);
    old.complete({
      'path': 'C:/test/old.png',
      'pages': 1,
      'text': '旧文件',
      'document': {'number': 'OLD'}
    });
    await tester.pumpAndSettle();
    expect(find.text('票号 NEW'), findsOneWidget);
    expect(find.text('票号 OLD'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
