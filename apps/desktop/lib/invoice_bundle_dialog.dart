import 'package:flutter/material.dart';
import 'package:travel_core/travel_core.dart';
import 'invoice_bundle.dart';

class InvoiceBundleDialog extends StatefulWidget {
  final BundleRecord task;
  final int groupIndex;
  const InvoiceBundleDialog(
      {super.key, required this.task, required this.groupIndex});
  @override
  State<InvoiceBundleDialog> createState() => _InvoiceBundleDialogState();
}

class _InvoiceBundleDialogState extends State<InvoiceBundleDialog> {
  late final selected = <int>{widget.groupIndex};
  String? error;
  List<BundleRecord> get groups =>
      (widget.task['groups'] as List).cast<BundleRecord>();
  void submit(bool split) {
    try {
      final updated = split
          ? splitInvoiceGroup(widget.task, widget.groupIndex)
          : combineInvoiceGroups(widget.task, selected,
              primary: widget.groupIndex);
      Navigator.pop(context, updated);
    } catch (e) {
      setState(() => error = '$e');
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('多张发票共用一笔支付'),
        content: SizedBox(
            width: 650,
            height: MediaQuery.sizeOf(context).height * .55,
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('选择同一笔实际扣款对应的城际交通发票，合并后按发票合计选择支付截图。'),
              const Text('合并会清除所选发票的复核标记；不同支付不可自动合并。'),
              const SizedBox(height: 8),
              Expanded(
                  child: ListView(children: [
                for (var i = 0; i < groups.length; i++)
                  if (groups[i]['category'] == 'intercity')
                    CheckboxListTile(
                      value: selected.contains(i),
                      onChanged: i == widget.groupIndex
                          ? null
                          : (value) => setState(() {
                                value == true
                                    ? selected.add(i)
                                    : selected.remove(i);
                                error = null;
                              }),
                      title: Text(
                          '${invoiceNumber(i + 1)} · ${groups[i]['name']}'),
                      subtitle: Text(
                          '${invoiceMembers(groups[i]).length} 张 · ¥${formatMoney(groups[i]['invoiceCents'])}'),
                    )
              ])),
              Text(
                  '发票合计：¥${formatMoney(selected.fold<int>(0, (sum, i) => sum + (groups[i]['invoiceCents'] as int)))}'),
              if (error != null)
                Text(error!,
                    style:
                        TextStyle(color: Theme.of(context).colorScheme.error)),
            ])),
        actions: [
          if (isInvoiceBundle(groups[widget.groupIndex]))
            TextButton(
                onPressed: () => submit(true), child: const Text('拆分为独立发票')),
          TextButton(
              onPressed: () => Navigator.pop(context), child: const Text('取消')),
          FilledButton(
              onPressed: selected.length < 2 ? null : () => submit(false),
              child: const Text('合并并选择支付')),
        ],
      );
}
