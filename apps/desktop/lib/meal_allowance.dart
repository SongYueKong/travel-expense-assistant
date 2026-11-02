import 'dart:convert';
import 'package:travel_core/travel_core.dart';
import 'trip_dates.dart';
import 'task_rules.dart';

const defaultMealDailyRateCents = 10000;

class MealAllowance {
  final TripPeriod? period;
  final int? dailyRateCents;
  final bool enabled;
  final String? error;
  MealAllowance._(this.period, this.dailyRateCents, this.enabled, this.error);
  factory MealAllowance.fromTask(TripTask task) {
    final period = TripPeriod.fromTask(task),
        raw = task['mealDailyRateCents'] ?? defaultMealDailyRateCents;
    final enabled = task['mealAllowanceEnabled'] is bool
        ? task['mealAllowanceEnabled'] as bool
        : period != null;
    final rate = raw is int && raw >= 0 ? raw : null;
    final error = task['mealAllowanceEnabled'] != null &&
            task['mealAllowanceEnabled'] is! bool
        ? '伙食补助启用状态无效'
        : enabled && period == null
            ? '请设置有效的出差起止日期'
            : enabled && rate == null
                ? '伙食补助每日标准无效'
                : null;
    return MealAllowance._(period, rate, enabled, error);
  }
  bool get included => enabled && error == null && period != null;
  int get amountCents => included ? period!.days * dailyRateCents! : 0;
  String get formula => period == null || dailyRateCents == null
      ? '请设置出差日期和补助标准'
      : '${period!.days} 天 × ${formatMoney(dailyRateCents!)} 元／天 = ${formatMoney(amountCents)} 元';
  Map<String, dynamic> summaryRow() => {
        'number': 'allowance-meal',
        'kind': 'allowance',
        'category': 'meal',
        'description':
            '伙食补助费（${period!.days}天 × ${formatMoney(dailyRateCents!)}元／天）',
        'invoiceCents': 0,
        'paymentCents': 0,
        'reimbursementCents': amountCents,
        'paymentNumbers': <String>[],
        'days': period!.days,
        'dailyRateCents': dailyRateCents,
        ...period!.toJson(),
      };
}

String tripBaseName(TripTask task) {
  final name = validateTaskName(task['name'] as String),
      period = TripPeriod.fromTask(task);
  if (period == null) return name;
  final suffix = '（${period.label}）', index = name.lastIndexOf(suffix);
  if (index < 0) return name;
  final base = name.replaceRange(index, index + suffix.length, '').trim();
  return base.isEmpty ? '差旅报账' : base;
}

TripTask applyTripSettings(TripTask source,
    {required String baseName,
    required TripPeriod period,
    required int dailyRateCents,
    required bool mealEnabled}) {
  if (dailyRateCents < 0) throw const FormatException('伙食补助标准不能为负数');
  final task = jsonDecode(jsonEncode(source)) as TripTask;
  return {
    ...task,
    ...period.toJson(),
    'name': period.taskName(baseName),
    'mealDailyRateCents': dailyRateCents,
    'mealAllowanceEnabled': mealEnabled
  };
}

class TripSettingsChange {
  final String baseName;
  final TripPeriod period;
  final int dailyRateCents;
  final bool mealEnabled;
  const TripSettingsChange(
      this.baseName, this.period, this.dailyRateCents, this.mealEnabled);
}
