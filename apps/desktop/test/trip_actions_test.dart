import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:travel_core/travel_core.dart';
import 'package:travel_assistant/trip_actions.dart';

void main() {
  testWidgets(
      'four primary actions are ordered and settings appear only in more menu',
      (tester) async {
    TripMoreAction? selected;
    var pdfs = 0;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: TripActionsBar(
                busy: false,
                localImportAvailable: true,
                pdfCount: 4,
                toleranceCents: 100,
                timeSettings: const TimeMatchSettings(),
                onPdf: () => pdfs++,
                onAddInvoice: () {},
                onAddPayments: () {},
                onExport: () {},
                onMore: (value) => selected = value))));
    final labels = ['全部 PDF 材料（4）', '添加发票与支付', '添加支付截图', '导出 PDF'];
    final buttons = find
        .byWidgetPredicate((w) => w is Text && labels.contains(w.data))
        .evaluate()
        .map((e) => (e.widget as Text).data)
        .toList();
    expect(buttons, labels);
    expect(find.textContaining('金额容差'), findsNothing);
    expect(find.text('从邮箱补充发票'), findsNothing);
    await tester.tap(find.text(labels.first));
    expect(pdfs, 1);
    await tester.tap(find.byTooltip('设置／更多'));
    await tester.pumpAndSettle();
    expect(find.text('金额容差：1.00 元'), findsOneWidget);
    expect(find.text('时间匹配／重算'), findsOneWidget);
    expect(find.text('支付截图排版'), findsOneWidget);
    expect(find.text('从邮箱补充发票'), findsOneWidget);
    expect(find.text('从本地文件夹导入材料'), findsOneWidget);
    await tester.tap(find.text('时间匹配／重算'));
    await tester.pumpAndSettle();
    expect(selected, TripMoreAction.timeMatching);
  });
  testWidgets(
      'busy toolbar blocks all actions and nonempty trip disables local folder import',
      (tester) async {
    var actions = 0;
    Widget bar(bool busy) => MaterialApp(
        home: Scaffold(
            body: TripActionsBar(
                busy: busy,
                localImportAvailable: false,
                pdfCount: 4,
                toleranceCents: 100,
                timeSettings: const TimeMatchSettings(),
                onPdf: () => actions++,
                onAddInvoice: () => actions++,
                onAddPayments: () => actions++,
                onExport: () => actions++,
                onMore: (_) => actions++)));
    await tester.pumpWidget(bar(true));
    await tester.tap(find.text('导出 PDF'));
    expect(actions, 0);
    expect(
        tester
            .widget<PopupMenuButton<TripMoreAction>>(
                find.byType(PopupMenuButton<TripMoreAction>))
            .enabled,
        isFalse);
    await tester.pumpWidget(bar(false));
    await tester.tap(find.byTooltip('设置／更多'));
    await tester.pumpAndSettle();
    final item = find.byWidgetPredicate((w) =>
        w is PopupMenuItem<TripMoreAction> &&
        w.value == TripMoreAction.localImport);
    expect(tester.widget<PopupMenuItem<TripMoreAction>>(item).enabled, isFalse);
  });
}
