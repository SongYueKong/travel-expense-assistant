import 'package:flutter/material.dart';
import 'task_rules.dart';

enum TaskAction { rename, duplicate, delete }

List<PopupMenuEntry<TaskAction>> taskMenuItems() => const [
      PopupMenuItem(
          value: TaskAction.rename,
          child: ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.edit_outlined),
              title: Text('重命名'))),
      PopupMenuItem(
          value: TaskAction.duplicate,
          child: ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.copy_outlined),
              title: Text('复制差旅'))),
      PopupMenuDivider(),
      PopupMenuItem(
          value: TaskAction.delete,
          child: ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.delete_outline),
              title: Text('删除差旅'))),
    ];

class TaskListTile extends StatelessWidget {
  final TripTask task;
  final bool selected, busy;
  final VoidCallback onSelect;
  final ValueChanged<TaskAction> onAction;
  const TaskListTile(
      {super.key,
      required this.task,
      required this.selected,
      required this.busy,
      required this.onSelect,
      required this.onAction});
  @override
  Widget build(BuildContext context) => ListTile(
      selected: selected,
      leading: const Icon(Icons.work_outline),
      title: Tooltip(
          message: task['name'],
          child:
              Text(task['name'], maxLines: 2, overflow: TextOverflow.ellipsis)),
      onTap: busy ? null : onSelect,
      trailing: PopupMenuButton<TaskAction>(
          key: ValueKey('task-menu-${task['id']}'),
          tooltip: '管理差旅：${task['name']}',
          enabled: !busy,
          onSelected: onAction,
          itemBuilder: (_) => taskMenuItems()));
}

class TaskNameDialog extends StatefulWidget {
  final String title, initialName, actionLabel;
  final String? description;
  final Future<TripTask> Function(String) commit;
  const TaskNameDialog(
      {super.key,
      required this.title,
      required this.initialName,
      required this.actionLabel,
      required this.commit,
      this.description});
  @override
  State<TaskNameDialog> createState() => _TaskNameDialogState();
}

class _TaskNameDialogState extends State<TaskNameDialog> {
  late final TextEditingController name;
  bool busy = false;
  String? error;
  @override
  void initState() {
    super.initState();
    name = TextEditingController(text: widget.initialName);
    name.selection =
        TextSelection(baseOffset: 0, extentOffset: name.text.length);
  }

  @override
  void dispose() {
    name.dispose();
    super.dispose();
  }

  Future<void> save() async {
    if (busy) return;
    try {
      final value = validateTaskName(name.text);
      setState(() {
        busy = true;
        error = null;
      });
      final result = await widget.commit(value);
      if (mounted) Navigator.pop(context, result);
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
          title: Text(widget.title),
          content: SizedBox(
              width: 440,
              child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (widget.description != null) ...[
                      Text(widget.description!),
                      const SizedBox(height: 12)
                    ],
                    TextField(
                        key: const ValueKey('task-name-input'),
                        controller: name,
                        enabled: !busy,
                        autofocus: true,
                        decoration: InputDecoration(
                            labelText: '任务名称',
                            hintText: '例如 北京出差 10月27日至29日',
                            errorText: error,
                            errorMaxLines: 3),
                        onChanged: (_) {
                          if (error != null) setState(() => error = null);
                        },
                        onSubmitted: (_) => save()),
                    if (busy) const LinearProgressIndicator(),
                  ])),
          actions: [
            TextButton(
                onPressed: busy ? null : () => Navigator.pop(context),
                child: const Text('取消')),
            FilledButton(
                onPressed: busy ? null : save, child: Text(widget.actionLabel)),
          ]));
}

class DeleteTaskDialog extends StatefulWidget {
  final TripTask task;
  final Future<void> Function() commit;
  const DeleteTaskDialog({super.key, required this.task, required this.commit});
  @override
  State<DeleteTaskDialog> createState() => _DeleteTaskDialogState();
}

class _DeleteTaskDialogState extends State<DeleteTaskDialog> {
  bool busy = false;
  String? error;
  Future<void> remove() async {
    if (busy) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await widget.commit();
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        setState(() {
          busy = false;
          error = '删除失败：$e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final groups = widget.task['groups'] as List? ?? [];
    final payments = groups.fold<int>(
        0, (sum, g) => sum + ((g['payments'] as List? ?? []).length));
    return PopScope(
        canPop: !busy,
        child: AlertDialog(
            scrollable: true,
            title: const Text('删除差旅报账？'),
            content: SizedBox(
                width: 440,
                child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SelectableText(widget.task['name'],
                          style: Theme.of(context).textTheme.titleMedium),
                      const SizedBox(height: 12),
                      Text('${groups.length} 张发票 · $payments 笔已关联支付'),
                      const SizedBox(height: 8),
                      Text(widget.task['taskDirectory'] != null
                          ? '该差旅文件夹将移入“差旅记录/.回收站”，并从任务列表移除。'
                          : '将删除该任务及其核对记录，无法从任务列表恢复。'),
                      const SizedBox(height: 8),
                      const Text('发票、行程单、截图原件、已导出文件和邮箱授权码会保留；其他差旅不受影响。'),
                      if (error != null)
                        Text(error!, style: const TextStyle(color: Colors.red)),
                      if (busy) const LinearProgressIndicator(),
                    ])),
            actions: [
              TextButton(
                  autofocus: true,
                  onPressed: busy ? null : () => Navigator.pop(context, false),
                  child: const Text('取消')),
              FilledButton(
                  style: FilledButton.styleFrom(
                      backgroundColor: Theme.of(context).colorScheme.error,
                      foregroundColor: Theme.of(context).colorScheme.onError),
                  onPressed: busy ? null : remove,
                  child: const Text('删除任务')),
            ]));
  }
}
