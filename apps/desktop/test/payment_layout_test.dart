import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:travel_assistant/payment_layout.dart';
import 'package:travel_assistant/payment_layout_dialog.dart';

Future<void> open(
    WidgetTester tester, Future<void> Function(PaymentLayout) commit,
    {PaymentLayout initial = const PaymentLayout.defaults()}) async {
  await tester.pumpWidget(MaterialApp(
      home: Builder(
          builder: (context) => Scaffold(
                body: TextButton(
                    onPressed: () => showDialog<PaymentLayout>(
                        context: context,
                        builder: (_) => PaymentLayoutDialog(
                            initial: initial, commit: commit)),
                    child: const Text('排版设置')),
              ))));
  await tester.tap(find.text('排版设置'));
  await tester.pumpAndSettle();
}

Future<void> select(WidgetTester tester, int index, String text) async {
  await tester.tap(find.byType(DropdownButtonFormField<int>).at(index));
  await tester.pumpAndSettle();
  await tester.tap(find.text(text).last);
  await tester.pumpAndSettle();
}

void main() {
  test('layout validates both dimensions and orientation and roundtrips', () {
    final layout = PaymentLayout(orientation: 'portrait', rows: 3, columns: 2);
    expect(PaymentLayout.fromJson(layout.toJson()).perPage, 6);
    for (final invalid in [
      {'orientation': 'A3', 'rows': 2, 'columns': 4},
      {'orientation': 'portrait', 'rows': 0, 'columns': 2},
      {'orientation': 'portrait', 'rows': 2, 'columns': 9},
      {'orientation': 'portrait', 'rows': 2.0, 'columns': 2},
      {'orientation': 'portrait', 'rows': true, 'columns': 2},
      <String, dynamic>{},
    ]) {
      expect(() => PaymentLayout.fromJson(invalid), throwsFormatException);
    }
  });

  testWidgets('save portrait 3 by 2 with live preview and reopen saved values',
      (tester) async {
    PaymentLayout saved = const PaymentLayout.defaults();
    Future<void> commit(PaymentLayout value) async {
      saved = value;
    }

    await open(tester, commit);
    await tester.tap(find.text('A4 纵向'));
    await select(tester, 0, '3 行');
    await select(tester, 1, '2 列');
    expect(find.text('每页 3 行 × 2 列，共 6 张。'), findsOneWidget);
    final preview = find.byKey(const ValueKey('payment-layout-preview'));
    expect(tester.getSize(preview).width / tester.getSize(preview).height,
        closeTo(210 / 297, 0.001));
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(
        saved.toJson(), {'orientation': 'portrait', 'rows': 3, 'columns': 2});
    await open(tester, commit, initial: saved);
    expect(find.text('每页 3 行 × 2 列，共 6 张。'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('cancel leaves preferences intact; reset only persists on save',
      (tester) async {
    var writes = 0;
    final saved = PaymentLayout(orientation: 'portrait', rows: 8, columns: 8);
    await open(tester, (_) async {
      writes++;
    }, initial: saved);
    await tester.tap(find.text('恢复默认'));
    await tester.pumpAndSettle();
    expect(find.text('每页 2 行 × 4 列，共 8 张。'), findsOneWidget);
    expect(writes, 0);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(writes, 0);
    await tester.tap(find.text('排版设置'));
    await tester.pumpAndSettle();
    expect(find.text('每页 8 行 × 8 列，共 64 张。'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('failed save remains editable and successful retry closes dialog',
      (tester) async {
    var fail = true;
    await open(tester, (_) async {
      if (fail) throw StateError('test write failure');
    });
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(find.textContaining('保存失败'), findsOneWidget);
    fail = false;
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(find.byType(PaymentLayoutDialog), findsNothing);
  });

  testWidgets('pending save prevents repeated saves or dismissing the dialog',
      (tester) async {
    final pending = Completer<void>();
    var writes = 0;
    await open(tester, (_) {
      writes++;
      return pending.future;
    });
    await tester.tap(find.text('保存'));
    await tester.pump();
    expect(writes, 1);
    expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull);
    expect(tester.widget<PopScope>(find.byType(PopScope)).canPop, isFalse);
    pending.complete();
    await tester.pumpAndSettle();
    expect(find.byType(PaymentLayoutDialog), findsNothing);
  });
}
