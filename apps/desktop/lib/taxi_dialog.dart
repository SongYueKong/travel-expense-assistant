import 'package:flutter/material.dart';
import 'package:travel_core/travel_core.dart';
import 'trip_dates.dart';
export 'taxi_record.dart';

class TaxiDialog extends StatefulWidget {
  final Future<String> Function(int, DateTime?) commit;
  const TaxiDialog({super.key, required this.commit});
  @override
  State<TaxiDialog> createState() => _TaxiDialogState();
}

class _TaxiDialogState extends State<TaxiDialog> {
  final amount = TextEditingController();
  DateTime? date;
  bool busy = false;
  String? error, result;
  int count = 0;
  @override
  void dispose() {
    amount.dispose();
    super.dispose();
  }

  Future<void> submit(bool finish) async {
    if (busy) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final cents = parseMoney(amount.text);
      if (cents <= 0) throw const FormatException('金额必须大于零');
      final message = await widget.commit(cents, date);
      if (!mounted) return;
      if (finish) {
        Navigator.pop(context);
        return;
      }
      setState(() {
        count++;
        result = '第 $count 张已保存：$message';
        amount.clear();
        date = null;
      });
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
        canPop: !busy,
        child: AlertDialog(
          title: const Text('添加出租车票'),
          content: SizedBox(
              width: 470,
              child: SingleChildScrollView(
                  child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                    const Text('登记纸质出租车发票，无需上传发票图片。可先登记，之后添加支付截图。'),
                    const SizedBox(height: 16),
                    TextField(
                        controller: amount,
                        enabled: !busy,
                        autofocus: true,
                        keyboardType: const TextInputType.numberWithOptions(
                            decimal: true),
                        decoration: const InputDecoration(
                            labelText: '金额（元）', hintText: '例如 35.00')),
                    const SizedBox(height: 12),
                    Row(children: [
                      OutlinedButton.icon(
                          onPressed: busy
                              ? null
                              : () async {
                                  final chosen = await showDatePicker(
                                      context: context,
                                      initialDate: date ?? DateTime.now(),
                                      firstDate: DateTime(2000),
                                      lastDate: DateTime(2100));
                                  if (chosen != null && mounted) {
                                    setState(() => date = chosen);
                                  }
                                },
                          icon: const Icon(Icons.calendar_month),
                          label:
                              Text(date == null ? '日期（可选）' : tripDate(date!))),
                      if (date != null)
                        TextButton(
                            onPressed:
                                busy ? null : () => setState(() => date = null),
                            child: const Text('清除日期')),
                    ]),
                    const Text('填写日期时按同一天匹配；不填日期时按金额匹配。同等候选或支付被占用时，保留待人工选择。'),
                    if (result != null)
                      Padding(
                          padding: const EdgeInsets.only(top: 12),
                          child: Text(result!,
                              style: const TextStyle(color: Colors.teal))),
                    if (error != null)
                      Text(error!, style: const TextStyle(color: Colors.red)),
                    if (busy) const LinearProgressIndicator(),
                  ]))),
          actions: [
            TextButton(
                onPressed: busy ? null : () => Navigator.pop(context),
                child: Text(count == 0 ? '取消' : '完成添加')),
            OutlinedButton(
                onPressed: busy ? null : () => submit(false),
                child: const Text('保存并继续添加')),
            FilledButton(
                onPressed: busy ? null : () => submit(true),
                child: const Text('保存并完成')),
          ],
        ),
      );
}
