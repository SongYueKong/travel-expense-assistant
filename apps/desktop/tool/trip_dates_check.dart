import 'dart:io';
import 'dart:convert';
import 'package:travel_assistant/services.dart';
import 'package:travel_assistant/trip_dates.dart';
import 'package:travel_assistant/meal_allowance.dart';
import 'package:travel_assistant/export_service.dart';

void check(bool condition, String reason) {
  if (!condition) throw StateError(reason);
}

Future<void> main(List<String> args) async {
  final directory = await Directory('${args.single}/.local')
          .createTemp('trip-dates-check-'),
      file = File('${directory.path}/tasks.sqlite');
  var store = TaskStore(file);
  try {
    await store.createTask('旧入口');
    final period = TripPeriod(DateTime(2026, 12, 31), DateTime(2027, 1, 2));
    final created = await store.createTask('北京出差', period: period);
    check(created['name'] == '北京出差（2026-12-31 至 2027-01-02）', '名称必须包含起止日期');
    await store.createTask('北京出差',
        period: TripPeriod(DateTime(2027, 1, 5), DateTime(2027, 1, 6)));
    var rejected = false;
    try {
      await store.createTask('北京出差', period: period);
    } on FormatException {
      rejected = true;
    }
    check(rejected, '同名同日期的重复任务应明确提示');
    final editedPeriod =
        TripPeriod(DateTime(2027, 2, 28), DateTime(2027, 3, 2));
    final edited = await store.updateTripSettings(
        created['id'], TripSettingsChange('北京出差', editedPeriod, 8050, true));
    check(
        MealAllowance.fromTask(edited).amountCents == 24150, '修改日期和标准后补助须即时重算');
    rejected = false;
    try {
      await store.updateTripSettings(
          created['id'],
          TripSettingsChange(
              '北京出差',
              TripPeriod(DateTime(2027, 1, 5), DateTime(2027, 1, 6)),
              10000,
              true));
    } on FormatException {
      rejected = true;
    }
    check(rejected, '设置修改与现有名称冲突应回滚');
    await store.close();
    store = TaskStore(file);
    final loaded =
        (await store.load()).singleWhere((t) => t['id'] == created['id']);
    check(TripPeriod.fromTask(loaded)!.label == editedPeriod.label,
        '修改的日期应在关闭重开后保留');
    check(MealAllowance.fromTask(loaded).amountCents == 24150,
        '补助标准在重开和冲突回滚后应保留');
    check(tripDate(TripPeriod.fromTask(loaded)!.mailEnd) == '2027-03-03',
        '恢复后邮箱结束日仍应加一天');
    final copy = await store.copyTask(created['id'], '日期副本');
    check(TripPeriod.fromTask(copy)!.label == editedPeriod.label,
        '复制任务应保留出差起止日期');
    check(MealAllowance.fromTask(copy).amountCents == 24150, '复制应保留补助标准');
    final snapshot =
        File('${args.single}/.local/duplicate-audit/task-after-repair.json');
    if (snapshot.existsSync()) {
      final qa = Directory('${args.single}/.local/meal-qa')
        ..createSync(recursive: true);
      final sample = applyTripSettings(
          jsonDecode(snapshot.readAsStringSync()) as Map<String, dynamic>,
          baseName: '北京出差核算样本',
          period: TripPeriod(DateTime(2026, 10, 27), DateTime(2026, 10, 29)),
          dailyRateCents: 10000,
          mealEnabled: true);
      File('${qa.path}/receipt-meal.json')
          .writeAsStringSync(jsonEncode(buildTaskExportManifest(sample)));
      final only = {...sample, 'groups': <dynamic>[]};
      File('${qa.path}/meal-only.json')
          .writeAsStringSync(jsonEncode(buildTaskExportManifest(only)));
      check(
          buildTaskExportManifest(sample)['grandTotals']
                  ['reimbursementCents'] ==
              buildExportManifest(
                      (sample['groups'] as List).cast<Map<String, dynamic>>(),
                      100)['grandTotals']['reimbursementCents'] +
                  30000,
          '真实材料快照中每组取较小值后再加300元补助');
      stdout.writeln(
          'PASS: real material snapshot plus meal and meal-only export manifests: ${qa.path}');
    }
    check(
        TripPeriod.fromTask(
                (await store.load()).singleWhere((t) => t['name'] == '旧入口')) ==
            null,
        '兼容旧版没有日期的任务');
    stdout.writeln(
        'PASS: dated names, same base with different dates, duplicate validation, SQLite reopen and copy');
    stdout.writeln(
        'PASS: persisted trip dates seed mail range through end + 1 calendar day');
    stdout.writeln('Only independent database edited: ${file.path}');
  } finally {
    await store.close();
  }
}
