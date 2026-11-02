import 'package:flutter/material.dart';
import 'trip_dates.dart';

Future<DateTimeRange?> showTripDatePicker(BuildContext context,
        {required TripPeriod initial, String title = '选择出差起止日期'}) =>
    showDialog<DateTimeRange>(
        context: context,
        builder: (_) => TripDatePicker(
            initialDateRange:
                DateTimeRange(start: initial.start, end: initial.end),
            title: title));

/// 近期差旅优先显示前一个月与当前月，选择时不改变已保存的日期。
class TripDatePicker extends StatefulWidget {
  final DateTimeRange initialDateRange;
  final String title;
  final DateTime? today;
  const TripDatePicker(
      {super.key,
      required this.initialDateRange,
      this.title = '选择出差起止日期',
      this.today});
  @override
  State<TripDatePicker> createState() => _TripDatePickerState();
}

class _TripDatePickerState extends State<TripDatePicker> {
  final startInput = TextEditingController(),
      endInput = TextEditingController();
  bool inputMode = false;
  String? error;
  late DateTime start, today, rightMonth;
  DateTime? end;
  final firstMonth = DateTime.utc(2000, 2), lastMonth = DateTime.utc(2100, 12);
  DateTime dateOnly(DateTime value) =>
      DateTime.utc(value.year, value.month, value.day);
  DateTime clampMonth(DateTime value) => value.isBefore(firstMonth)
      ? firstMonth
      : value.isAfter(lastMonth)
          ? lastMonth
          : value;
  @override
  void initState() {
    super.initState();
    today = dateOnly(widget.today ?? TripPeriod.today().end);
    start = dateOnly(widget.initialDateRange.start);
    end = dateOnly(widget.initialDateRange.end);
    rightMonth = clampMonth(DateTime.utc(end!.year, end!.month));
  }

  @override
  void dispose() {
    startInput.dispose();
    endInput.dispose();
    super.dispose();
  }

  void toggleInput() => setState(() {
        if (!inputMode) {
          startInput.text = tripDate(start);
          endInput.text = end == null ? '' : tripDate(end!);
        }
        inputMode = !inputMode;
        error = null;
      });
  void confirm() {
    if (inputMode) {
      final period = TripPeriod.fromTask({
        'tripStartDate': startInput.text.trim(),
        'tripEndDate': endInput.text.trim()
      });
      if (period == null) {
        setState(() => error = '请输入有效的起止日期（YYYY-MM-DD），结束日期不能早于开始日期。');
        return;
      }
      Navigator.pop(
          context, DateTimeRange(start: period.start, end: period.end));
    } else if (end != null) {
      Navigator.pop(context, DateTimeRange(start: start, end: end!));
    }
  }

  void select(DateTime value) => setState(() {
        if (end != null || value.isBefore(start)) {
          start = value;
          end = null;
        } else {
          end = value;
        }
      });
  Widget month(DateTime first) {
    final theme = Theme.of(context), colors = Theme.of(context).colorScheme;
    final count = DateTime.utc(first.year, first.month + 1, 0).day;
    final offset = first.weekday - 1;
    return Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
            border: Border.all(color: colors.outlineVariant),
            borderRadius: BorderRadius.circular(12)),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 10),
              decoration: BoxDecoration(
                  color: colors.primaryContainer,
                  borderRadius: BorderRadius.circular(8)),
              child: Text('${first.year}年${first.month}月',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: colors.onPrimaryContainer))),
          const SizedBox(height: 10),
          Row(children: [
            for (final weekday in ['一', '二', '三', '四', '五', '六', '日'])
              Expanded(
                  child: Center(
                      child: Text(weekday,
                          style: TextStyle(
                              color: colors.onSurfaceVariant,
                              fontWeight: FontWeight.w600))))
          ]),
          const SizedBox(height: 6),
          for (var row = 0; row < 6; row++)
            Row(children: [
              for (var col = 0; col < 7; col++)
                Expanded(child: Builder(builder: (_) {
                  final day = row * 7 + col - offset + 1;
                  if (day < 1 || day > count) return const SizedBox(height: 38);
                  final value = DateTime.utc(first.year, first.month, day);
                  final boundary = value == start || value == end;
                  final selected = end != null &&
                      !value.isBefore(start) &&
                      !value.isAfter(end!);
                  return Container(
                      height: 38,
                      color: selected ? colors.secondaryContainer : null,
                      child: Semantics(
                          label: '${value.year}年${value.month}月${value.day}日',
                          selected: selected || boundary,
                          child: TextButton(
                              key: ValueKey('trip-day-${tripDate(value)}'),
                              onPressed: () => select(value),
                              style: TextButton.styleFrom(
                                  padding: EdgeInsets.zero,
                                  minimumSize: const Size(32, 36),
                                  foregroundColor: boundary
                                      ? colors.onPrimary
                                      : colors.onSurface,
                                  backgroundColor:
                                      boundary ? colors.primary : null,
                                  shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(6),
                                      side: value == today
                                          ? BorderSide(
                                              color: colors.primary, width: 1.5)
                                          : BorderSide.none)),
                              child: Text('$day',
                                  style: TextStyle(
                                      fontWeight: boundary || value == today
                                          ? FontWeight.w700
                                          : FontWeight.normal)))));
                }))
            ]),
        ]));
  }

  @override
  Widget build(BuildContext context) {
    final leftMonth = DateTime.utc(rightMonth.year, rightMonth.month - 1);
    return AlertDialog(
        title: Text(widget.title),
        content: SizedBox(
            width: 760,
            child: SingleChildScrollView(
                child: Column(mainAxisSize: MainAxisSize.min, children: [
              const Align(
                  alignment: Alignment.centerLeft,
                  child: Text('先点开始日期，再点结束日期，可跨月选择。')),
              const SizedBox(height: 8),
              if (inputMode) ...[
                TextField(
                    controller: startInput,
                    decoration: InputDecoration(
                        labelText: MaterialLocalizations.of(context)
                            .dateRangeStartLabel,
                        hintText: 'YYYY-MM-DD')),
                const SizedBox(height: 12),
                TextField(
                    controller: endInput,
                    decoration: InputDecoration(
                        labelText:
                            MaterialLocalizations.of(context).dateRangeEndLabel,
                        hintText: 'YYYY-MM-DD')),
                if (error != null)
                  Text(error!,
                      style: TextStyle(
                          color: Theme.of(context).colorScheme.error)),
                TextButton(onPressed: toggleInput, child: const Text('返回日历选择')),
              ] else ...[
                Row(children: [
                  IconButton(
                      key: const ValueKey('trip-month-previous'),
                      tooltip: '前一个月',
                      onPressed: rightMonth == firstMonth
                          ? null
                          : () => setState(() => rightMonth = DateTime.utc(
                              rightMonth.year, rightMonth.month - 1)),
                      icon: const Icon(Icons.chevron_left)),
                  const Spacer(),
                  TextButton(
                      onPressed: () => setState(() => rightMonth =
                          clampMonth(DateTime.utc(today.year, today.month))),
                      child: const Text('回到本月')),
                  IconButton(
                      tooltip: MaterialLocalizations.of(context)
                          .inputDateModeButtonLabel,
                      onPressed: toggleInput,
                      icon: const Icon(Icons.edit_calendar_outlined)),
                  const Spacer(),
                  IconButton(
                      tooltip: '后一个月',
                      onPressed: rightMonth == lastMonth
                          ? null
                          : () => setState(() => rightMonth = DateTime.utc(
                              rightMonth.year, rightMonth.month + 1)),
                      icon: const Icon(Icons.chevron_right)),
                ]),
                LayoutBuilder(
                    builder: (_, constraints) => constraints.maxWidth >= 620
                        ? Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                                Expanded(child: month(leftMonth)),
                                const SizedBox(width: 12),
                                Expanded(child: month(rightMonth))
                              ])
                        : Column(children: [
                            month(leftMonth),
                            const SizedBox(height: 12),
                            month(rightMonth)
                          ])),
                const SizedBox(height: 14),
                Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                        '开始：${tripDate(start)}　结束：${end == null ? '待选择' : tripDate(end!)}${end == null ? '' : '　共 ${end!.difference(start).inDays + 1} 天'}',
                        style: Theme.of(context).textTheme.titleSmall)),
              ],
            ]))),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context), child: const Text('取消')),
          FilledButton(
              onPressed: !inputMode && end == null ? null : confirm,
              child: const Text('确定'))
        ]);
  }
}
