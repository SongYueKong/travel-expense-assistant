import 'package:flutter/material.dart';
import 'package:travel_core/travel_core.dart';
import 'matching_helpers.dart';

class PaymentTimeChange {
  final Map<String, dynamic>? values;
  const PaymentTimeChange(this.values);
}

class PaymentTimeDialog extends StatefulWidget {
  final Map<String, dynamic> material;
  const PaymentTimeDialog({super.key, required this.material});
  @override
  State<PaymentTimeDialog> createState() => _PaymentTimeDialogState();
}

class _PaymentTimeDialogState extends State<PaymentTimeDialog> {
  late final TextEditingController ride, paid;
  String? error;
  String display(DateTime? time) =>
      time == null ? '' : formatBeijingTimestamp(time);
  @override
  void initState() {
    super.initState();
    ride = TextEditingController(
        text: display(paymentTime(widget.material, 'rideDateTime')));
    paid = TextEditingController(
        text: display(paymentTime(widget.material, 'paymentDateTime')));
  }

  @override
  void dispose() {
    ride.dispose();
    paid.dispose();
    super.dispose();
  }

  void save() {
    try {
      final values = {
        'rideDateTime': ride.text.trim().isEmpty ? null : ride.text.trim(),
        'paymentDateTime': paid.text.trim().isEmpty ? null : paid.text.trim()
      };
      withPaymentTimes(widget.material, values);
      Navigator.pop(context, PaymentTimeChange(values));
    } catch (e) {
      setState(() => error = e is FormatException ? e.message : '$e');
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
          scrollable: true,
          title: const Text('对照原图纠正时间'),
          content: SizedBox(
              width: 570,
              child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(widget.material['name'] ?? '支付截图'),
                    const Text(
                        '请先放大查看截图原件，再填写北京时间。格式：YYYY-MM-DD HH:mm:ss；无法确定可留空。只修正时间，不改变金额或关联。'),
                    const SizedBox(height: 12),
                    SelectableText(
                        'OCR 原始乘车时间：${widget.material['ocr']?['rideDateTime'] ?? '未识别'}\nOCR 原始支付时间：${widget.material['ocr']?['paymentDateTime'] ?? '未识别'}'),
                    TextField(
                        key: const ValueKey('correct-ride-time'),
                        controller: ride,
                        decoration: const InputDecoration(labelText: '乘车时间')),
                    TextField(
                        key: const ValueKey('correct-paid-time'),
                        controller: paid,
                        decoration: const InputDecoration(labelText: '支付时间')),
                    if (error != null)
                      Text(error!, style: const TextStyle(color: Colors.red)),
                  ])),
          actions: [
            if (widget.material['timeOverrides'] != null)
              TextButton(
                  onPressed: () =>
                      Navigator.pop(context, const PaymentTimeChange(null)),
                  child: const Text('恢复 OCR 结果')),
            TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('取消')),
            FilledButton(onPressed: save, child: const Text('应用到核对草稿')),
          ]);
}
