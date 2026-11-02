import 'package:flutter/material.dart';
import 'task_rules.dart';
import 'trip_dates.dart';
import 'trip_date_picker.dart';

class CreateTripDialog extends StatefulWidget {
  final Future<TripTask> Function(String, TripPeriod) commit;
  final TripPeriod? initialPeriod;
  const CreateTripDialog({super.key, required this.commit, this.initialPeriod});
  @override
  State<CreateTripDialog> createState() => _CreateTripDialogState();
}

class _CreateTripDialogState extends State<CreateTripDialog> {
  final name = TextEditingController(text: '差旅报账');
  late TripPeriod period;
  bool busy = false;
  String? error;
  String get previewName {
    try {
      return period.taskName(name.text);
    } on FormatException {
      return '请填写有效差旅名称';
    }
  }

  @override
  void initState() {
    super.initState();
    period = widget.initialPeriod ?? TripPeriod.today();
  }

  @override
  void dispose() {
    name.dispose();
    super.dispose();
  }

  Future<void> chooseDates() async {
    final selected = await showTripDatePicker(context, initial: period);
    if (selected != null && mounted) {
      setState(() {
        period = TripPeriod(selected.start, selected.end);
        error = null;
      });
    }
  }

  Future<void> save() async {
    if (busy) return;
    try {
      final base = validateTaskName(name.text);
      setState(() {
        busy = true;
        error = null;
      });
      final task = await widget.commit(base, period);
      if (mounted) Navigator.pop(context, task);
    } catch (e) {
      if (mounted) {
        setState(() {
          busy = false;
          error = e is FormatException ? e.message : '创建失败：$e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
      canPop: !busy,
      child: AlertDialog(
          scrollable: true,
          title: const Text('新建差旅报账'),
          content: SizedBox(
              width: 540,
              child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                        '创建后打开邮箱导入，自动带入本机默认邮箱。邮箱初始接收范围为出差开始日至结束日后一天，可手动调整。'),
                    const SizedBox(height: 12),
                    TextField(
                        key: const ValueKey('task-name-input'),
                        controller: name,
                        enabled: !busy,
                        autofocus: true,
                        decoration: InputDecoration(
                            labelText: '差旅名称（日期自动附加）',
                            hintText: '例如 北京出差',
                            errorText: error,
                            errorMaxLines: 3),
                        onChanged: (_) => setState(() => error = null),
                        textInputAction: TextInputAction.next,
                        onSubmitted: (_) => FocusScope.of(context).nextFocus()),
                    const SizedBox(height: 16),
                    OutlinedButton.icon(
                        key: const ValueKey('trip-date-range'),
                        onPressed: busy ? null : chooseDates,
                        icon: const Icon(Icons.date_range),
                        label: Text('出差起止日期：${period.label}')),
                    const SizedBox(height: 12),
                    Text('任务名称预览：$previewName'),
                    const Text('可关闭邮箱窗口，随后手工添加材料。',
                        style: TextStyle(color: Colors.blueGrey)),
                    if (busy) const LinearProgressIndicator(),
                  ])),
          actions: [
            TextButton(
                onPressed: busy ? null : () => Navigator.pop(context),
                child: const Text('取消')),
            FilledButton(
                onPressed: busy ? null : save, child: const Text('创建并从邮箱导入'))
          ]));
}
