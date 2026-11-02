import 'dart:io';
import 'package:flutter/material.dart';
import 'package:travel_core/travel_core.dart';
import 'pending_service.dart';
import 'payment_identity.dart';
import 'pdf_preview_panel.dart';
import 'matching_helpers.dart';

class PendingIssuesDialog extends StatefulWidget {
  final MaterialData task;
  final DocumentPreviewLoader? loadPreview;
  final Future<void> Function(MaterialData) onSave;
  final Future<MaterialData?> Function(MaterialData, PendingItem) onResolve;
  final Future<MaterialData> Function(MaterialData) onRetry;
  const PendingIssuesDialog(
      {super.key,
      required this.task,
      required this.onSave,
      required this.onResolve,
      required this.onRetry,
      this.loadPreview});
  @override
  State<PendingIssuesDialog> createState() => _PendingIssuesDialogState();
}

class _PendingIssuesDialogState extends State<PendingIssuesDialog> {
  late MaterialData task;
  String filter = 'pending';
  String? selectedId, error;
  bool busy = false;
  List<PendingItem> get all => pendingItems(task, includeHandled: true);
  List<PendingItem> get visible => all
      .where((i) =>
          filter == 'pending' ? i.state == 'pending' : i.state != 'pending')
      .toList();
  PendingItem? get selected {
    final matches = visible.where((i) => i.id == selectedId);
    return matches.isEmpty ? visible.firstOrNull : matches.first;
  }

  @override
  void initState() {
    super.initState();
    task = copyTask(widget.task);
  }

  Future<void> apply(Future<MaterialData?> Function() action) async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final updated = await action();
      if (updated != null) {
        final cleaned = cleanPending(updated);
        await widget.onSave(cleaned);
        if (mounted) setState(() => task = cleaned);
      }
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Widget detail(PendingItem item) {
    final m = item.material, o = m?['ocr'];
    final amount = m?['manualPaymentCents'] ??
        m?['cents'] ??
        o?['paymentCandidate']?['cents'] ??
        m?['document']?['totalCents'];
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Expanded(
          child: SingleChildScrollView(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
            Text(item.title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            SelectableText(item.reason),
            if (item.state != 'pending')
              Text(item.state == 'ignored' ? '状态：已忽略' : '状态：已解决',
                  style: const TextStyle(color: Colors.teal)),
            if (m != null) ...[
              const SizedBox(height: 10),
              SelectableText('文件：${m['name'] ?? ''}\n路径：${m['path'] ?? ''}'),
              if (amount is int) Text('识别／修正金额：¥${formatMoney(amount)}'),
              Text('类别：${const {
                    'local': '市内交通',
                    'hotel': '酒店住宿',
                    'intercity': '城际交通'
                  }[o?['category'] ?? m['document']?['category']] ?? '未识别'}'),
              if (paymentTime(m, 'rideDateTime') != null)
                Text(
                    '乘车时间：${formatBeijingTimestamp(paymentTime(m, 'rideDateTime'))}'),
              if (paymentTime(m, 'paymentDateTime') != null)
                Text(
                    '支付时间：${formatBeijingTimestamp(paymentTime(m, 'paymentDateTime'))}'),
              if (m['timeOverrides'] != null)
                const Text('时间已对照原图纠正（保留 OCR 原文）'),
              if (o?['paymentTransactionId'] != null)
                SelectableText('交易单号：${o['paymentTransactionId']}'),
              const SizedBox(height: 12),
              if (isScreenshot(m))
                SizedBox(
                    height: 300,
                    width: double.infinity,
                    child: InteractiveViewer(
                        minScale: .5,
                        maxScale: 8,
                        child: Image.file(File(m['path']),
                            fit: BoxFit.contain,
                            errorBuilder: (_, __, ___) => const Center(
                                child: Text('图片无法读取，请检查文件或重新导入'))))),
              if ((m['path'] as String? ?? '').toLowerCase().endsWith('.pdf'))
                PdfPreviewPanel(
                    key: ValueKey('pending-preview-${item.id}'),
                    material: m,
                    title: '材料原件',
                    loadPreview: widget.loadPreview),
              if ((m['text'] ?? o?['text'] ?? '').toString().isNotEmpty)
                ExpansionTile(
                    key: ValueKey('text-${item.id}'),
                    title: const Text('识别原文'),
                    children: [
                      Padding(
                          padding: const EdgeInsets.all(12),
                          child: SelectableText(m['text'] ?? o?['text'] ?? ''))
                    ]),
            ],
          ]))),
      const Divider(),
      Wrap(spacing: 8, runSpacing: 6, children: [
        if (item.state == 'pending') ...[
          FilledButton(
              onPressed: busy
                  ? null
                  : () => apply(() => item.isMaterial
                      ? widget.onResolve(task, item)
                      : Future.value(decidePending(task, item, 'resolved'))),
              child: Text(item.isMaterial ? '处理／关联' : '标记已解决')),
          OutlinedButton(
              onPressed: busy
                  ? null
                  : () =>
                      apply(() async => decidePending(task, item, 'ignored')),
              child: const Text('忽略此项')),
        ] else
          OutlinedButton(
              onPressed: busy
                  ? null
                  : () =>
                      apply(() async => decidePending(task, item, 'restore')),
              child: const Text('恢复待处理')),
      ]),
    ]);
  }

  @override
  Widget build(BuildContext context) => PopScope(
      canPop: !busy,
      child: AlertDialog(
        title: const Text('导入待处理事项'),
        content: SizedBox(
            width: 1100,
            height: MediaQuery.sizeOf(context).height * .72,
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('点击事项查看原件。忽略后不参与匹配，可恢复；忽略不会补齐费用组的缺失证据。操作成功即保存。'),
              const SizedBox(height: 10),
              Wrap(
                  spacing: 12,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    SegmentedButton<String>(
                        segments: [
                          ButtonSegment(
                              value: 'pending',
                              label: Text(
                                  '待处理（${all.where((i) => i.state == 'pending').length}）')),
                          ButtonSegment(
                              value: 'handled',
                              label: Text(
                                  '已忽略／已解决（${all.where((i) => i.state != 'pending').length}）')),
                        ],
                        selected: {
                          filter
                        },
                        onSelectionChanged: busy
                            ? null
                            : (value) => setState(() {
                                  filter = value.single;
                                  selectedId = null;
                                })),
                    OutlinedButton.icon(
                        onPressed: busy
                            ? null
                            : () => apply(() => widget.onRetry(task)),
                        icon: const Icon(Icons.refresh),
                        label: const Text('重新识别／匹配')),
                  ]),
              if ((task['duplicatePayments'] as List? ?? []).isNotEmpty)
                Text(
                    '本次导入已自动移除 ${task['duplicatePayments'].length} 项重复支付截图，原始文件保留。',
                    style: const TextStyle(color: Colors.teal)),
              if (error != null)
                Text(error!, style: const TextStyle(color: Colors.red)),
              if (busy) const LinearProgressIndicator(),
              const SizedBox(height: 12),
              Expanded(child: LayoutBuilder(builder: (context, size) {
                final list = ListView(children: [
                  for (final item in visible)
                    ListTile(
                        key: ValueKey('pending-${item.id}'),
                        selected: selected?.id == item.id,
                        leading: Icon(item.isMaterial
                            ? (isScreenshot(item.material!)
                                ? Icons.image_outlined
                                : Icons.picture_as_pdf_outlined)
                            : Icons.info_outline),
                        title: Text(item.title,
                            maxLines: 2, overflow: TextOverflow.ellipsis),
                        subtitle: Text(item.state == 'pending'
                            ? '点击查看详情'
                            : (item.state == 'ignored'
                                ? '已忽略，可恢复'
                                : '已解决，可恢复')),
                        onTap: busy
                            ? null
                            : () => setState(() => selectedId = item.id))
                ]);
                final body = selected == null
                    ? const Center(child: Text('当前列表没有事项'))
                    : detail(selected!);
                if (size.maxWidth < 760) {
                  return Column(children: [
                    SizedBox(height: 135, child: list),
                    const Divider(),
                    Expanded(child: body)
                  ]);
                }
                return Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      SizedBox(width: 300, child: list),
                      const VerticalDivider(),
                      Expanded(child: body)
                    ]);
              })),
            ])),
        actions: [
          TextButton(
              onPressed: busy ? null : () => Navigator.pop(context),
              child: const Text('关闭'))
        ],
      ));
}
