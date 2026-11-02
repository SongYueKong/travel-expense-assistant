import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:travel_assistant/task_management.dart';
import 'package:travel_assistant/task_rules.dart';
import 'task_rules_test.dart' show sampleTask;

Future<void> openName(WidgetTester tester,
    Future<TripTask> Function(String) commit, void Function(dynamic) received,
    {bool copy = false}) async {
  await tester.pumpWidget(MaterialApp(
      home: Builder(
          builder: (context) => Scaffold(
              body: TextButton(
                  onPressed: () async => received(await showDialog<TripTask>(
                      context: context,
                      builder: (_) => TaskNameDialog(
                          title: copy ? '复制差旅报账' : '重命名差旅',
                          initialName: copy ? '北京出差（副本）' : '北京出差',
                          description: copy ? '复制后的所有项目都需重新核对和确认。' : null,
                          actionLabel: copy ? '复制' : '保存名称',
                          commit: commit))),
                  child: const Text('管理'))))));
  await tester.tap(find.text('管理'));
  await tester.pumpAndSettle();
}

Future<void> openDelete(WidgetTester tester, Future<void> Function() commit,
    void Function(dynamic) received) async {
  await tester.pumpWidget(MaterialApp(
      home: Builder(
          builder: (context) => Scaffold(
              body: TextButton(
                  onPressed: () async => received(await showDialog<bool>(
                      context: context,
                      builder: (_) => DeleteTaskDialog(
                          task: sampleTask(), commit: commit))),
                  child: const Text('管理'))))));
  await tester.tap(find.text('管理'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
      'task menu offers rename copy delete and targets the intended task',
      (tester) async {
    TaskAction? action;
    var selected = false;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SizedBox(
                width: 240,
                child: TaskListTile(
                    task: sampleTask(),
                    selected: true,
                    busy: false,
                    onSelect: () => selected = true,
                    onAction: (value) => action = value)))));
    await tester.tap(find.byKey(const ValueKey('task-menu-original')));
    await tester.pumpAndSettle();
    expect(find.text('重命名'), findsOneWidget);
    expect(find.text('复制差旅'), findsOneWidget);
    expect(find.text('删除差旅'), findsOneWidget);
    await tester.tap(find.text('重命名'));
    await tester.pumpAndSettle();
    expect(action, TaskAction.rename);
    expect(selected, isFalse);
  });
  testWidgets('busy workspace disables task selection and management',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SizedBox(
                width: 240,
                child: TaskListTile(
                    task: sampleTask(),
                    selected: true,
                    busy: true,
                    onSelect: () {},
                    onAction: (_) {})))));
    expect(
        tester
            .widget<PopupMenuButton<TaskAction>>(
                find.byType(PopupMenuButton<TaskAction>))
            .enabled,
        isFalse);
    expect(tester.widget<ListTile>(find.byType(ListTile)).onTap, isNull);
  });
  testWidgets('rename cancel and blank name do not commit changes',
      (tester) async {
    var commits = 0;
    dynamic result;
    await openName(tester, (value) async {
      commits++;
      return sampleTask();
    }, (value) => result = value);
    await tester.enterText(
        find.byKey(const ValueKey('task-name-input')), '   ');
    await tester.tap(find.text('保存名称'));
    await tester.pumpAndSettle();
    expect(find.text('任务名称不能为空'), findsOneWidget);
    expect(commits, 0);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(result, isNull);
    expect(commits, 0);
  });
  testWidgets(
      'rename returns only after persistence and prevents duplicate submission',
      (tester) async {
    final pending = Completer<TripTask>();
    var commits = 0;
    dynamic result;
    String? submitted;
    await openName(tester, (value) {
      commits++;
      submitted = value;
      return pending.future;
    }, (value) => result = value);
    await tester.enterText(
        find.byKey(const ValueKey('task-name-input')), ' 上海出差 ');
    await tester.tap(find.text('保存名称'));
    await tester.pump();
    expect(result, isNull);
    expect(commits, 1);
    expect(submitted, '上海出差');
    expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull);
    pending.complete({...sampleTask(), 'name': submitted});
    await tester.pumpAndSettle();
    expect(result['name'], '上海出差');
    expect(commits, 1);
  });
  testWidgets('rename failure leaves dialog open and supports correction',
      (tester) async {
    dynamic result;
    var fail = true;
    await openName(tester, (value) async {
      if (fail) throw const FormatException('已有同名差旅，请使用其他名称');
      return {...sampleTask(), 'name': value};
    }, (value) => result = value);
    await tester.tap(find.text('保存名称'));
    await tester.pumpAndSettle();
    expect(result, isNull);
    expect(find.text('已有同名差旅，请使用其他名称'), findsOneWidget);
    fail = false;
    await tester.enterText(
        find.byKey(const ValueKey('task-name-input')), '广州出差');
    await tester.tap(find.text('保存名称'));
    await tester.pumpAndSettle();
    expect(result['name'], '广州出差');
    expect(tester.takeException(), isNull);
  });
  testWidgets('copy explains and resets confirmation while preserving source',
      (tester) async {
    final source = sampleTask();
    dynamic result;
    await openName(tester, (name) async => duplicateTask(source, name),
        (value) => result = value,
        copy: true);
    expect(find.text('复制后的所有项目都需重新核对和确认。'), findsOneWidget);
    await tester.tap(find.text('复制'));
    await tester.pumpAndSettle();
    expect(result['groups'][0]['confirmed'], isFalse);
    expect(source['groups'][0]['confirmed'], isTrue);
    expect(result['id'], isNot(source['id']));
  });
  testWidgets('delete cancellation does not call storage', (tester) async {
    var calls = 0;
    dynamic result;
    await openDelete(tester, () async {
      calls++;
    }, (value) => result = value);
    expect(find.text('北京出差'), findsOneWidget);
    expect(find.text('1 张发票 · 1 笔已关联支付'), findsOneWidget);
    expect(find.textContaining('原件、已导出文件和邮箱授权码会保留'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(result, isFalse);
    expect(calls, 0);
  });
  testWidgets('confirmed deletion returns success after storage completes',
      (tester) async {
    final pending = Completer<void>();
    var calls = 0;
    dynamic result;
    await openDelete(tester, () {
      calls++;
      return pending.future;
    }, (value) => result = value);
    await tester.tap(find.text('删除任务'));
    await tester.pump();
    expect(calls, 1);
    expect(result, isNull);
    expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull);
    pending.complete();
    await tester.pumpAndSettle();
    expect(result, isTrue);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
      'delete failure keeps task confirmation visible for retry or cancellation',
      (tester) async {
    dynamic result;
    await openDelete(tester, () async => throw StateError('数据库暂不可写'),
        (value) => result = value);
    await tester.tap(find.text('删除任务'));
    await tester.pumpAndSettle();
    expect(result, isNull);
    expect(find.textContaining('删除失败'), findsOneWidget);
    expect(find.text('北京出差'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(result, isFalse);
  });
}
