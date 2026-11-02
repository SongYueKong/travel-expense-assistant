import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:travel_assistant/invoice_panel.dart';
import 'association_service_test.dart' show invoice;

void main() {
  testWidgets(
      'invoice context and raw parties text remain visible without changing financial values',
      (tester) async {
    final g = invoice('one');
    g['document']['number'] = '99990000000000000004';
    g['document']['issueDate'] = '2026-10-29';
    g['text'] = '购买方名称：测试单位\n销售方名称：测试酒店\n项目：住宿费';
    final original = jsonEncode(g);
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SingleChildScrollView(child: InvoicePanel(invoice: g)))));
    expect(find.text('发票号码：99990000000000000004'), findsOneWidget);
    expect(find.text('核对发票金额：¥100.00'), findsOneWidget);
    expect(find.text('开票日期：2026-10-29'), findsOneWidget);
    await tester.tap(find.text('发票原文（购销方、项目等）'));
    await tester.pumpAndSettle();
    expect(find.textContaining('销售方名称：测试酒店'), findsOneWidget);
    expect(jsonEncode(g), original);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'read-only preview paginates and enlarges; original financial amount is retained',
      (tester) async {
    final g = invoice('one');
    final original = jsonEncode(g);
    final calls = <int>[];
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SingleChildScrollView(
                child: InvoicePanel(
                    invoice: g,
                    loadPreview: (path, page) async {
                      calls.add(page);
                      return {
                        'path': 'C:/test/preview-$page.png',
                        'pages': 2,
                        'text': '票面文字',
                        'document': {
                          'number': '12345678901234567890',
                          'totalCents': 10050
                        }
                      };
                    })))));
    await tester.pumpAndSettle();
    expect(calls, [0]);
    expect(find.text('核对发票金额：¥100.00'), findsOneWidget);
    expect(find.textContaining('票面识别金额：¥100.50'), findsOneWidget);
    await tester.tap(find.byTooltip('发票下一页'));
    await tester.pumpAndSettle();
    expect(calls, [0, 1]);
    expect(find.text('第 2 / 2 页'), findsOneWidget);
    expect(
        tester
            .widget<IconButton>(find.byWidgetPredicate(
                (w) => w is IconButton && w.tooltip == '发票下一页'))
            .onPressed,
        isNull);
    await tester.tap(find.text('放大发票'));
    await tester.pumpAndSettle();
    expect(find.text('发票原件 · 第 2 / 2 页'), findsOneWidget);
    expect(find.byType(InteractiveViewer), findsOneWidget);
    await tester.tap(find.byTooltip('关闭发票预览'));
    await tester.pumpAndSettle();
    expect(find.byType(InteractiveViewer), findsNothing);
    expect(jsonEncode(g), original);
    expect(tester.takeException(), isNull);
  });

  testWidgets('missing fields are explicit and failed previews can retry',
      (tester) async {
    final g = invoice('one');
    g['document'] = <String, dynamic>{};
    var attempts = 0;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SingleChildScrollView(
                child: InvoicePanel(
                    invoice: g,
                    loadPreview: (_, page) async {
                      if (attempts++ == 0) throw StateError('文件暂不可读');
                      return {
                        'path': 'C:/test/preview.png',
                        'pages': 1,
                        'text': '',
                        'document': <String, dynamic>{}
                      };
                    })))));
    await tester.pumpAndSettle();
    expect(find.text('开票日期：未识别'), findsOneWidget);
    expect(find.textContaining('发票预览未能读取'), findsOneWidget);
    await tester.tap(find.text('重新读取发票'));
    await tester.pumpAndSettle();
    expect(attempts, 2);
    expect(find.textContaining('发票预览未能读取'), findsNothing);
    expect(find.text('第 1 / 1 页'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
