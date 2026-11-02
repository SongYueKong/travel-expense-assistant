import 'package:flutter/material.dart';
import 'package:travel_core/travel_core.dart';

class TimeRematchRequest {
  final TimeMatchSettings settings;
  final bool includeManual;
  const TimeRematchRequest(this.settings, this.includeManual);
}

class TimeMatchingDialog extends StatefulWidget {
  final TimeMatchSettings settings;
  const TimeMatchingDialog({super.key, required this.settings});
  @override
  State<TimeMatchingDialog> createState() => _TimeMatchingDialogState();
}

class _TimeMatchingDialogState extends State<TimeMatchingDialog> {
  late final TextEditingController ride =
      TextEditingController(text: '${widget.settings.rideToleranceMinutes}');
  late final TextEditingController payment =
      TextEditingController(text: '${widget.settings.paymentDelayMinutes}');
  String? error;
  bool includeManual = false;
  @override
  void dispose() {
    ride.dispose();
    payment.dispose();
    super.dispose();
  }

  void save() {
    try {
      final r = int.tryParse(ride.text.trim()),
          p = int.tryParse(payment.text.trim());
      if (r == null || p == null) throw const FormatException('请填写非负整数分钟');
      final settings = TimeMatchSettings.fromJson(
          {'rideToleranceMinutes': r, 'paymentDelayMinutes': p});
      Navigator.pop(context, TimeRematchRequest(settings, includeManual));
    } catch (e) {
      setState(() => error = e is FormatException
          ? e.message
          : (e as ArgumentError).message.toString());
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
          scrollable: true,
          title: const Text('日期时间匹配设置'),
          content: SizedBox(
              width: 520,
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                const Text(
                    '先筛选日期时间范围，再核对类别、平台、金额或明确优惠。市内交通优先使用乘车时间；没有乘车时间时比较支付时间，两种时间均采用前后对称窗口。住宿和城际交通默认日期相差不超过14天。时间缺失或超范围需人工核对。'),
                TextField(
                    controller: ride,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                        labelText: '乘车时间允许前后相差（分钟）',
                        helperText: '默认前后150，范围0–1440')),
                TextField(
                    controller: payment,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                        labelText: '支付时间允许前后相差（分钟）',
                        helperText: '默认前后150（2小时30分钟），范围0–10080')),
                CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    value: includeManual,
                    onChanged: (v) => setState(() => includeManual = v == true),
                    title: const Text('重算未复核的人工关联'),
                    subtitle: const Text('保留人工修正的支付净额。已标记复核及手工录入的项目保持原样。')),
                const Text('仍无法区分的多笔候选或同一支付被多项争用时，保留人工选择。'),
                if (error != null)
                  Text(error!, style: const TextStyle(color: Colors.red)),
              ])),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('取消')),
            FilledButton(onPressed: save, child: const Text('重新匹配'))
          ]);
}
