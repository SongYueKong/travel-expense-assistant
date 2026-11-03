import 'package:flutter/material.dart';
import 'payment_layout.dart';

class PaymentLayoutDialog extends StatefulWidget {
  final PaymentLayout initial;
  final Future<void> Function(PaymentLayout) commit;
  const PaymentLayoutDialog(
      {super.key, required this.initial, required this.commit});
  @override
  State<PaymentLayoutDialog> createState() => _PaymentLayoutDialogState();
}

class _PaymentLayoutDialogState extends State<PaymentLayoutDialog> {
  late PaymentLayout layout = widget.initial;
  bool saving = false;
  String? error;

  void update(
          {String? orientation, int? rows, int? columns, bool? uniformPages}) =>
      setState(() {
        layout = PaymentLayout(
            orientation: orientation ?? layout.orientation,
            rows: rows ?? layout.rows,
            columns: columns ?? layout.columns,
            uniformPages: uniformPages ?? layout.uniformPages);
        error = null;
      });

  Future<void> save() async {
    setState(() {
      saving = true;
      error = null;
    });
    try {
      await widget.commit(layout);
      if (mounted) Navigator.pop(context, layout);
    } catch (e) {
      if (mounted) {
        setState(() {
          saving = false;
          error = '保存失败：$e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
        canPop: !saving,
        child: AlertDialog(
          title: const Text('支付截图排版'),
          content: SizedBox(
              width: 440,
              child: SingleChildScrollView(
                  child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('本机通用设置，所有差旅后续导出自动沿用。'),
                  const SizedBox(height: 16),
                  SegmentedButton<String>(
                    segments: const [
                      ButtonSegment(
                          value: 'landscape',
                          label: Text('A4 横向'),
                          icon: Icon(Icons.crop_landscape)),
                      ButtonSegment(
                          value: 'portrait',
                          label: Text('A4 纵向'),
                          icon: Icon(Icons.crop_portrait)),
                    ],
                    selected: {layout.orientation},
                    onSelectionChanged: saving
                        ? null
                        : (values) => update(orientation: values.single),
                  ),
                  const SizedBox(height: 16),
                  Row(children: [
                    Expanded(
                        child: DropdownButtonFormField<int>(
                      key: ValueKey('rows-${layout.rows}'),
                      initialValue: layout.rows,
                      decoration: const InputDecoration(labelText: '每页行数'),
                      items: [
                        for (var n = 1; n <= 8; n++)
                          DropdownMenuItem(value: n, child: Text('$n 行'))
                      ],
                      onChanged: saving ? null : (n) => update(rows: n),
                    )),
                    const SizedBox(width: 16),
                    Expanded(
                        child: DropdownButtonFormField<int>(
                      key: ValueKey('columns-${layout.columns}'),
                      initialValue: layout.columns,
                      decoration: const InputDecoration(labelText: '每页列数'),
                      items: [
                        for (var n = 1; n <= 8; n++)
                          DropdownMenuItem(value: n, child: Text('$n 列'))
                      ],
                      onChanged: saving ? null : (n) => update(columns: n),
                    )),
                  ]),
                  const SizedBox(height: 16),
                  Center(
                      child: SizedBox(
                          height: 190,
                          child: AspectRatio(
                            aspectRatio:
                                layout.landscape ? 297 / 210 : 210 / 297,
                            child: Container(
                              key: const ValueKey('payment-layout-preview'),
                              padding: const EdgeInsets.all(6),
                              decoration: BoxDecoration(
                                  color: Colors.white,
                                  border: Border.all(color: Colors.grey)),
                              child: Column(children: [
                                for (var row = 0; row < layout.rows; row++)
                                  Expanded(
                                      child: Row(children: [
                                    for (var column = 0;
                                        column < layout.columns;
                                        column++)
                                      Expanded(
                                          child: Container(
                                        margin: const EdgeInsets.all(1),
                                        decoration: BoxDecoration(
                                            color: const Color(0xffe5f1ef),
                                            border: Border.all(
                                                color:
                                                    const Color(0xff9bbab4))),
                                        child: Center(
                                            child: FittedBox(
                                                child: Text(
                                                    '${row * layout.columns + column + 1}',
                                                    style: const TextStyle(
                                                        fontSize: 11)))),
                                      )),
                                  ])),
                              ]),
                            ),
                          ))),
                  const SizedBox(height: 12),
                  Text(
                      '每页 ${layout.rows} 行 × ${layout.columns} 列，共 ${layout.perPage} 张。'),
                  const Text('截图等比例缩放，尾页保持相同格子尺寸。'),
                  const SizedBox(height: 12),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('统一所有页面为 A4'),
                    subtitle:
                        const Text('全部页面使用上方所选方向，原件等比例缩放居中，不裁剪。关闭时保留各类材料页面尺寸。'),
                    value: layout.uniformPages,
                    onChanged:
                        saving ? null : (value) => update(uniformPages: value),
                  ),
                  if (error != null)
                    Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(error!,
                            style: TextStyle(
                                color: Theme.of(context).colorScheme.error))),
                ],
              ))),
          actions: [
            TextButton(
                onPressed: saving
                    ? null
                    : () => setState(() {
                          layout = const PaymentLayout.defaults();
                          error = null;
                        }),
                child: const Text('恢复默认')),
            TextButton(
                onPressed: saving ? null : () => Navigator.pop(context),
                child: const Text('取消')),
            FilledButton(
                onPressed: saving ? null : save,
                child: Text(saving ? '保存中…' : '保存')),
          ],
        ),
      );
}
