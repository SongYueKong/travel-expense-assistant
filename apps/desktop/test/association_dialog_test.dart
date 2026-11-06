import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:travel_assistant/association_dialog.dart';
import 'package:travel_assistant/association_service.dart';
import 'package:travel_assistant/pdf_preview_panel.dart';
import 'association_service_test.dart'
    show
        fixture,
        payment,
        invoice,
        itinerary,
        incompleteTripTask,
        completeTripDocument;

Future<void> openEditor(
    WidgetTester tester, MaterialRecord task, void Function(dynamic) receive,
    {Size size = const Size(1280, 900),
    DocumentPreviewLoader? load,
    MaterialRecord? focus}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(() => tester.view.resetPhysicalSize());
  addTearDown(() => tester.view.resetDevicePixelRatio());
  await tester.pumpWidget(MaterialApp(
      home: Builder(
          builder: (context) => Scaffold(
              body: TextButton(
                  onPressed: () async => receive(await showDialog(
                      context: context,
                      builder: (_) => AssociationDialog(
                          task: task,
                          groupIndex: 0,
                          focusMaterial: focus,
                          loadDocumentPreview: load))),
                  child: const Text('调整'))))));
  await tester.tap(find.text('调整'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
      'uncertain amount candidate can fill a draft and is persisted only by save',
      (tester) async {
    final task = fixture();
    task['unmatchedPayments'] = <MaterialRecord>[];
    final m = payment('uncertain');
    m['ocr'].remove('paymentCandidate');
    m['ocr']['amountCandidates'] = [
      {
        'cents': 9999,
        'role': 'paid',
        'label': '实付金额',
        'source': {'text': '99.99'}
      }
    ];
    m['ocr']['amountDecision'] = {'status': 'needsReview', 'reason': '需要核对'};
    task['unmatchedMaterials'] = [m];
    final before = jsonEncode(task);
    dynamic received;
    await openEditor(tester, task, (v) => received = v);
    await tester.ensureVisible(find.text('显示全部截图（含条件不符、未识别和已占用）'));
    await tester.tap(find.text('显示全部截图（含条件不符、未识别和已占用）'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('填入实付'));
    await tester.tap(find.text('填入实付'));
    await tester.pumpAndSettle();
    expect(received, isNull);
    expect(jsonEncode(task), before);
    expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('amount-0')))
            .controller!
            .text,
        '99.99');
    await tester.tap(find.text('保存选择'));
    await tester.pumpAndSettle();
    expect(
        received['groups'][0]['payments'].single['manualPaymentCents'], 9999);
    expect(received['groups'][0]['payments'].single['ocr']['paymentCandidate'],
        isNull);
    expect(jsonEncode(task), before);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'refreshing old itinerary adds missing row while preserving edited net amount',
      (tester) async {
    final task = incompleteTripTask(),
        before = jsonEncode(incompleteTripTask());
    dynamic received;
    await openEditor(tester, task, (value) => received = value,
        load: (path, page) async => {
              'path': 'C:/test/preview.png',
              'pages': 1,
              'text': '两条行程',
              'document': path.endsWith('itinerary.pdf')
                  ? completeTripDocument()
                  : task['groups'][0]['document'],
            });
    expect(find.text('行程单标注 2 笔，当前保存 1 笔，请重新识别。'), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('amount-0')), '46.99');
    await tester.tap(find.text('重新识别行程单'));
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<DropdownButton<int>>(find.byType(DropdownButton<int>))
            .items!
            .length,
        2);
    expect(find.textContaining('已重新识别 2 笔，保留 1 笔已选支付'), findsOneWidget);
    await tester.tap(find.text('保存选择'));
    await tester.pumpAndSettle();
    expect(received['groups'][0]['trips'].length, 2);
    expect(received['groups'][0]['payments'].single['cents'], 4699);
    expect(received['groups'][0]['suggestionComplete'], isFalse);
    expect(received['groups'][0]['confirmed'], isFalse);
    expect(jsonEncode(task), before);
    expect(tester.takeException(), isNull);
  });

  testWidgets('incomplete refresh retains old selection and can be cancelled',
      (tester) async {
    final task = incompleteTripTask(),
        before = jsonEncode(incompleteTripTask());
    final partial = {...completeTripDocument(), 'complete': false};
    await openEditor(tester, task, (_) {},
        load: (_, __) async => {
              'path': 'C:/test/preview.png',
              'pages': 1,
              'text': '',
              'document': partial,
            });
    await tester.tap(find.text('重新识别行程单'));
    await tester.pumpAndSettle();
    expect(find.textContaining('条数或合计尚未校验通过，保留原有选择'), findsOneWidget);
    expect(
        tester
            .widget<DropdownButton<int>>(find.byType(DropdownButton<int>))
            .items!
            .length,
        1);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(jsonEncode(task), before);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
      'city transport can view and paginate the selected itinerary and open all PDFs',
      (tester) async {
    final task = fixture();
    final m = itinerary('current-itinerary');
    task['groups'][0] = invoice('local', category: 'local');
    task['groups'][0]['itineraries'] = [m['path']];
    task['groups'][0]['itineraryMaterials'] = [m];
    task['groups'][0]['trips'] = m['document']['trips'];
    final original = jsonEncode(task), calls = <String>[];
    await openEditor(tester, task, (_) {}, load: (path, page) async {
      calls.add('$path/$page');
      return {
        'path': 'C:/test/preview.png',
        'pages': 2,
        'text': '原件内容',
        'document':
            path == m['path'] ? m['document'] : task['groups'][0]['document']
      };
    });
    await tester.tap(find.text('行程单'));
    await tester.pumpAndSettle();
    expect(calls, contains('${m['path']}/0'));
    expect(find.text('行程合计：¥100.00'), findsOneWidget);
    await tester.ensureVisible(find.byTooltip('行程单下一页'));
    await tester.tap(find.byTooltip('行程单下一页'));
    await tester.pumpAndSettle();
    expect(calls.last, '${m['path']}/1');
    await tester.ensureVisible(find.text('放大行程单'));
    await tester.tap(find.text('放大行程单'));
    await tester.pumpAndSettle();
    expect(find.text('行程单原件 · 第 2 / 2 页'), findsOneWidget);
    await tester.tap(find.byTooltip('关闭行程单预览'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('全部 PDF 材料'));
    await tester.pumpAndSettle();
    expect(find.textContaining('共 3 份 PDF'), findsOneWidget);
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(jsonEncode(task), original);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
      'trip selector keeps invoice visible and assigns each chosen payment to its trip',
      (tester) async {
    final task = fixture();
    task['groups'][0] = invoice('local', category: 'local');
    task['groups'][0]['invoiceCents'] = 20050;
    final m = itinerary('trips');
    m['document']['totalCents'] = 20050;
    m['document']['trips'].add(
        {'index': 2, 'date': '2026-10-27', 'time': '11:00', 'cents': 10050});
    task['unmatchedMaterials'] = [m];
    task['unmatchedPayments'] = [
      payment('a', category: 'local'),
      payment('b', category: 'local', cents: 10050, rideTime: '11:00')
    ];
    dynamic received;
    await openEditor(tester, task, (value) => received = value);
    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('trips.pdf').last);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const ValueKey('choose-a')));
    await tester.tap(find.byKey(const ValueKey('choose-a')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byType(DropdownButtonFormField<int>));
    await tester.tap(find.byType(DropdownButtonFormField<int>));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('行程 2 ·').last);
    await tester.pumpAndSettle();
    expect(find.textContaining('当前核对：行程 2'), findsOneWidget);
    await tester.tap(find.text('发票'));
    await tester.pumpAndSettle();
    expect(find.text('发票信息'), findsOneWidget);
    await tester.ensureVisible(find.byKey(const ValueKey('choose-b')));
    await tester.tap(find.byKey(const ValueKey('choose-b')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存选择'));
    await tester.pumpAndSettle();
    expect(
        (received['groups'][0]['payments'] as List).map((p) => p['tripIndex']),
        [1, 2]);
    expect((received['groups'][0]['payments'] as List).map((p) => p['hash']),
        ['a', 'b']);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
      'choose an ambiguous candidate and save without auto confirmation',
      (tester) async {
    dynamic received;
    await openEditor(tester, fixture(), (value) => received = value);
    await tester.ensureVisible(find.byKey(const ValueKey('choose-b')));
    await tester.tap(find.byKey(const ValueKey('choose-b')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('amount-0')), '99.50');
    await tester.tap(find.text('保存选择'));
    await tester.pumpAndSettle();
    expect(received['groups'][0]['payments'].single['hash'], 'b');
    expect(received['groups'][0]['payments'].single['cents'], 9950);
    expect(received['groups'][0]['confirmed'], isFalse);
    expect(received['groups'][0]['complete'], isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('occupied candidate disabled and cancel leaves source untouched',
      (tester) async {
    dynamic received = 'waiting';
    final task = fixture();
    task['groups'][1]['payments'] = [
      {...payment('a'), 'cents': 10000}
    ];
    await openEditor(tester, task, (value) => received = value);
    expect(
        tester
            .widget<FilledButton>(find.byKey(const ValueKey('choose-a')))
            .onPressed,
        isNull);
    await tester.ensureVisible(find.byKey(const ValueKey('choose-b')));
    await tester.tap(find.byKey(const ValueKey('choose-b')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(received, isNull);
    expect(task['groups'][0]['payments'], isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('invalid amount cannot save and preview can be closed',
      (tester) async {
    dynamic received;
    await openEditor(tester, fixture(), (value) => received = value);
    await tester.tap(find.byKey(const ValueKey('choose-a')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('amount-0')), '12.345');
    await tester.tap(find.text('保存选择'));
    await tester.pumpAndSettle();
    expect(received, isNull);
    expect(find.textContaining('请输入非负金额'), findsOneWidget);
    await tester.ensureVisible(find.text('放大查看').first);
    await tester.tap(find.text('放大查看').first);
    await tester.pumpAndSettle();
    expect(find.byType(InteractiveViewer), findsOneWidget);
    await tester.tap(find.byTooltip('关闭预览'));
    await tester.pumpAndSettle();
    expect(find.byType(InteractiveViewer), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'unknown screenshots accessible through show all at smaller window size',
      (tester) async {
    final task = fixture();
    task['unmatchedMaterials'] = [
      {'hash': 'unknown', 'path': 'C:/test/unknown.png', 'name': 'unknown.png'}
    ];
    await openEditor(tester, task, (_) {}, size: const Size(800, 600));
    expect(find.byKey(const ValueKey('choose-unknown')), findsNothing);
    await tester.ensureVisible(find.text('显示全部截图（含条件不符、未识别和已占用）'));
    await tester.tap(find.text('显示全部截图（含条件不符、未识别和已占用）'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('choose-unknown')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'local itinerary choice builds trip slots and clears old selection when switched',
      (tester) async {
    final task = fixture();
    task['groups'][0] = invoice('local', category: 'local');
    task['unmatchedMaterials'] = [itinerary('first'), itinerary('second')];
    dynamic received;
    await openEditor(tester, task, (value) => received = value);
    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('first.pdf').last);
    await tester.pumpAndSettle();
    expect(find.textContaining('行程 1 ·'), findsNWidgets(2));
    await tester.ensureVisible(find.text('显示全部截图（含条件不符、未识别和已占用）'));
    await tester.tap(find.text('显示全部截图（含条件不符、未识别和已占用）'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const ValueKey('choose-a')));
    await tester.tap(find.byKey(const ValueKey('choose-a')));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('second.pdf').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存选择'));
    await tester.pumpAndSettle();
    expect(received['groups'][0]['payments'], isEmpty);
    expect(received['groups'][0]['suggestionComplete'], isFalse);
    expect(tester.takeException(), isNull);
  });
}
