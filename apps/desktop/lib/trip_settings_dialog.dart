import 'package:flutter/material.dart';
import 'package:travel_core/travel_core.dart';
import 'meal_allowance.dart';
import 'trip_dates.dart';
import 'task_rules.dart';
import 'trip_date_picker.dart';

class TripSettingsDialog extends StatefulWidget {
  final TripTask task;
  final Future<TripTask> Function(TripSettingsChange) commit;
  const TripSettingsDialog(
      {super.key, required this.task, required this.commit});
  @override
  State<TripSettingsDialog> createState() => _TripSettingsDialogState();
}

class _TripSettingsDialogState extends State<TripSettingsDialog> {
  late final TextEditingController name, rate;
  TripPeriod? period;
  late bool enabled;
  bool busy = false;
  String? error;
  @override
  void initState() {
    super.initState();
    final meal = MealAllowance.fromTask(widget.task);
    period = meal.period;
    enabled = meal.enabled;
    name = TextEditingController(text: tripBaseName(widget.task));
    rate = TextEditingController(
        text: formatMoney(meal.dailyRateCents ?? defaultMealDailyRateCents));
  }

  @override
  void dispose() {
    name.dispose();
    rate.dispose();
    super.dispose();
  }

  String get preview {
    if (period == null) return '请选择出差起止日期';
    try {
      return '${period!.days} 天（含首尾日） × ${formatMoney(parseMoney(rate.text))} 元／天 = ${formatMoney(period!.days * parseMoney(rate.text))} 元';
    } on FormatException {
      return '请填写有效的每日补助标准';
    }
  }

  String get namePreview {
    try {
      return period == null
          ? validateTaskName(name.text)
          : period!.taskName(name.text);
    } on FormatException {
      return '请填写有效差旅名称';
    }
  }

  Future<void> dates() async {
    final initial = period ?? TripPeriod.today();
    final selected =
        await showTripDatePicker(context, initial: initial, title: '调整出差起止日期');
    if (selected != null && mounted) {
      setState(() {
        if (period == null && widget.task['mealAllowanceEnabled'] == null) {
          enabled = true;
        }
        period = TripPeriod(selected.start, selected.end);
        error = null;
      });
    }
  }

  Future<void> save() async {
    if (busy) return;
    try {
      if (period == null) throw const FormatException('请选择出差起止日期');
      final change = TripSettingsChange(
          validateTaskName(name.text), period!, parseMoney(rate.text), enabled);
      setState(() {
        busy = true;
        error = null;
      });
      final updated = await widget.commit(change);
      if (mounted) Navigator.pop(context, updated);
    } catch (e) {
      if (mounted) {
        setState(() {
          busy = false;
          error = e is FormatException ? e.message : '保存失败：$e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
      canPop: !busy,
      child: AlertDialog(
          scrollable: true,
          title: const Text('出差日期与伙食补助'),
          content: SizedBox(
              width: 580,
              child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    TextField(
                        key: const ValueKey('trip-settings-name'),
                        controller: name,
                        enabled: !busy,
                        decoration:
                            const InputDecoration(labelText: '差旅名称（日期自动附加）'),
                        onChanged: (_) => setState(() => error = null)),
                    const SizedBox(height: 12),
                    OutlinedButton.icon(
                        key: const ValueKey('trip-settings-dates'),
                        onPressed: busy ? null : dates,
                        icon: const Icon(Icons.date_range),
                        label: Text(period == null
                            ? '选择出差起止日期'
                            : '出差起止日期：${period!.label}')),
                    const SizedBox(height: 8),
                    Text('名称预览：$namePreview'),
                    const Text('日期保存后，邮箱初始接收范围使用开始日至结束日后一天。'),
                    const SizedBox(height: 12),
                    CheckboxListTile(
                        contentPadding: EdgeInsets.zero,
                        value: enabled,
                        onChanged: busy
                            ? null
                            : (v) => setState(() => enabled = v == true),
                        title: const Text('计入伙食补助费'),
                        controlAffinity: ListTileControlAffinity.leading),
                    TextField(
                        key: const ValueKey('meal-daily-rate'),
                        controller: rate,
                        enabled: !busy,
                        keyboardType: const TextInputType.numberWithOptions(
                            decimal: true),
                        decoration: const InputDecoration(
                            labelText: '伙食补助标准（元／天）',
                            helperText: '用于当前差旅，新建默认 100.00 元／天'),
                        onChanged: (_) => setState(() => error = null)),
                    const SizedBox(height: 12),
                    Text(enabled ? preview : '伙食补助不计入费用合计'),
                    if (error != null)
                      Text(error!, style: const TextStyle(color: Colors.red)),
                    if (busy) const LinearProgressIndicator(),
                  ])),
          actions: [
            TextButton(
                onPressed: busy ? null : () => Navigator.pop(context),
                child: const Text('取消')),
            FilledButton(
                onPressed: busy ? null : save, child: const Text('保存设置'))
          ]));
}

class MealAllowanceCard extends StatelessWidget {
  final MealAllowance meal;
  final VoidCallback? onSettings;
  const MealAllowanceCard({super.key, required this.meal, this.onSettings});
  @override
  Widget build(BuildContext context) => Card(
      child: Padding(
          padding: const EdgeInsets.all(16),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('伙食补助费', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            if (meal.period != null)
              Text('出差日期：${meal.period!.label} · ${meal.period!.days} 天（含首尾日）'),
            Text(
                meal.error ??
                    (meal.period == null
                        ? '请设置出差起止日期后计算补助'
                        : meal.enabled
                            ? meal.formula
                            : '已关闭，不计入费用合计'),
                style: TextStyle(
                    color: meal.error == null ? null : Colors.deepOrange)),
            const SizedBox(height: 12),
            Wrap(
                spacing: 12,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  OutlinedButton.icon(
                      onPressed: onSettings,
                      icon: const Icon(Icons.settings_outlined),
                      label: const Text('调整日期／补助标准')),
                  if (meal.included)
                    Text('计入 ¥${formatMoney(meal.amountCents)}'),
                ]),
          ])));
}
