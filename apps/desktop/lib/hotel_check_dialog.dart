import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:file_selector/file_selector.dart';
import 'hotel_check.dart';
import 'services.dart';
import 'invoice_panel.dart';

class HotelCheckDialog extends StatefulWidget {
  final Map<String, dynamic> group;
  final ProcessingClient engine;
  final String materialDirectory;
  final DocumentPreviewLoader? loadPreview;
  final Future<void> Function(Map<String, dynamic>) commit;
  final Future<XFile?> Function()? pickStatement;
  const HotelCheckDialog(
      {super.key,
      required this.group,
      required this.engine,
      required this.materialDirectory,
      required this.commit,
      this.pickStatement,
      this.loadPreview});
  @override
  State<HotelCheckDialog> createState() => _HotelCheckDialogState();
}

class _HotelCheckDialogState extends State<HotelCheckDialog> {
  late final group =
      jsonDecode(jsonEncode(widget.group)) as Map<String, dynamic>;
  late final check = HotelCheck(group);
  late final seller = TextEditingController(text: check.seller);
  late final payees = [
    for (final p in check.payments) TextEditingController(text: check.payee(p))
  ];
  Map<String, dynamic>? proof;
  String? error;
  bool loading = true, busy = false;
  @override
  void initState() {
    super.initState();
    proof = check.resolved ? check.proof : null;
    load();
  }

  @override
  void dispose() {
    seller.dispose();
    for (final p in payees) {
      p.dispose();
    }
    super.dispose();
  }

  Future<Map<String, dynamic>> inspect(String path,
          {bool statement = false}) async =>
      Map<String, dynamic>.from(await widget.engine.call('inspect', {
        'path': path,
        'material_dir': widget.materialDirectory,
        if (statement) 'purpose': 'statement'
      }));
  Future<void> load() async {
    try {
      if (seller.text.isEmpty) {
        final m = await inspect(group['path']);
        if (mounted) seller.text = m['document']?['sellerName'] ?? '';
      }
      for (var i = 0; i < payees.length; i++) {
        if (payees[i].text.isEmpty) {
          final m = await inspect(check.payments[i]['path']);
          if (mounted) payees[i].text = m['ocr']?['payeeName'] ?? '';
        }
      }
    } catch (e) {
      if (mounted) error = '自动读取未完成，请对照原件手工填写：$e';
    }
    if (mounted) setState(() => loading = false);
  }

  Map<String, dynamic> draft() => {
        ...group,
        'hotelVerification': {
          'sellerName': seller.text.trim(),
          'payees': {
            for (var i = 0; i < payees.length; i++)
              hotelPaymentKey(check.payments[i]): payees[i].text.trim()
          },
          if (proof != null) 'proof': proof
        }
      };
  void changed(String _) => setState(() => proof = null);
  void paper(bool? value) {
    setState(() => proof = value == true
        ? {'kind': 'paper', 'basis': HotelCheck(draft()).basis}
        : null);
  }

  Future<void> attachment() async {
    final file = await (widget.pickStatement?.call() ??
        openFile(acceptedTypeGroups: [
          const XTypeGroup(
              label: '情况说明（PDF／图片）',
              extensions: ['pdf', ...hotelStatementImages])
        ]));
    if (file == null || !mounted) return;
    setState(() => busy = true);
    try {
      final kind = hotelStatementKind(file.path);
      if (kind.isEmpty) throw StateError('请选择PDF、JPG、PNG、BMP或WEBP情况说明');
      final material = await inspect(file.path, statement: true);
      if (material['hash'] == group['hash'] ||
          material['path'] == group['path'] ||
          check.payments.any((p) =>
              p['hash'] == material['hash'] || p['path'] == material['path'])) {
        throw StateError('情况说明不能使用该发票本身或对应支付截图');
      }
      material['name'] = file.name;
      if (mounted) {
        setState(() => proof = {
              'kind': kind,
              'material': material,
              'basis': HotelCheck(draft()).basis
            });
      }
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> save() async {
    final updated = draft(), state = HotelCheck(draft());
    if (!state.resolved) {
      setState(() => error = state.status);
      return;
    }
    if (!state.same &&
        state.hasFileProof &&
        !await File(state.proof!['material']['path']).exists()) {
      if (mounted) setState(() => error = '情况说明文件已不存在，请重新添加');
      return;
    }
    if (!mounted) return;
    setState(() => busy = true);
    try {
      await widget.commit(updated);
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        setState(() {
          error = '保存失败：$e';
          busy = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = HotelCheck(draft());
    return PopScope(
        canPop: !busy,
        child: AlertDialog(
            scrollable: true,
            title: const Text('酒店收款单位核对与情况说明'),
            content: SizedBox(
                width: 1000,
                child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (loading) const LinearProgressIndicator(),
                      const Text(
                          '比较发票销售方与收款方全称，仅忽略空格及中英文括号。请对照原件纠正识别结果，品牌名称不能替代单位全称。'),
                      ExpansionTile(
                          title: const Text('查看发票原件与识别信息'),
                          children: [
                            InvoicePanel(
                                invoice: group, loadPreview: widget.loadPreview)
                          ]),
                      TextField(
                          key: const ValueKey('hotel-seller'),
                          controller: seller,
                          enabled: !loading && !busy,
                          onChanged: changed,
                          decoration:
                              const InputDecoration(labelText: '发票销售方单位全称')),
                      for (var i = 0; i < payees.length; i++)
                        Row(children: [
                          InkWell(
                              onTap: () => showDialog<void>(
                                  context: context,
                                  builder: (_) => Dialog(
                                      child: InteractiveViewer(
                                          minScale: .2,
                                          maxScale: 5,
                                          child: Image.file(File(
                                              check.payments[i]['path']))))),
                              child: Image.file(File(check.payments[i]['path']),
                                  height: 150,
                                  width: 90,
                                  errorBuilder: (_, error, stack) =>
                                      const Text('截图无法读取'))),
                          Expanded(
                              child: TextField(
                                  key: ValueKey('hotel-payee-$i'),
                                  controller: payees[i],
                                  enabled: !loading && !busy,
                                  onChanged: changed,
                                  decoration: InputDecoration(
                                      labelText: '支付 ${i + 1} 收款方全称')))
                        ]),
                      Text(state.status,
                          style: TextStyle(
                              color: state.resolved
                                  ? Colors.teal
                                  : Colors.deepOrange)),
                      if (state.known && !state.same) ...[
                        OutlinedButton(
                            onPressed: busy || loading ? null : attachment,
                            child: const Text('添加／替换情况说明（PDF／图片）')),
                        if (['pdf', 'image'].contains(proof?['kind']))
                          Text('已添加：${proof!['material']['name']}（导出时紧跟该发票）'),
                        if (proof?['kind'] == 'image')
                          InkWell(
                              onTap: () => showDialog<void>(
                                  context: context,
                                  builder: (context) => Dialog(
                                      child: SizedBox(
                                          width: 900,
                                          height: 700,
                                          child: Column(children: [
                                            Align(
                                                alignment:
                                                    Alignment.centerRight,
                                                child: IconButton(
                                                    tooltip: '关闭预览',
                                                    onPressed: () =>
                                                        Navigator.pop(context),
                                                    icon: const Icon(
                                                        Icons.close))),
                                            Expanded(
                                                child: InteractiveViewer(
                                                    minScale: .5,
                                                    maxScale: 5,
                                                    child: Image.file(
                                                        File(proof!['material']
                                                            ['path']),
                                                        fit: BoxFit.contain,
                                                        errorBuilder: (_, __,
                                                                ___) =>
                                                            const Text(
                                                                '图片已无法读取，请重新添加')))),
                                          ])))),
                              child: Column(children: [
                                Image.file(File(proof!['material']['path']),
                                    height: 180,
                                    fit: BoxFit.contain,
                                    errorBuilder: (_, __, ___) =>
                                        const Text('图片预览不可用，请重新选择说明图片')),
                                const Text('点击放大查看情况说明')
                              ])),
                        CheckboxListTile(
                            contentPadding: EdgeInsets.zero,
                            value: proof?['kind'] == 'paper',
                            onChanged: busy || loading ? null : paper,
                            title: const Text('已有酒店出具的纸质情况说明'),
                            subtitle: const Text('电子汇总标记已备纸质证明，报销时请随材料提交。')),
                        if (proof != null)
                          TextButton(
                              onPressed: busy
                                  ? null
                                  : () => setState(() => proof = null),
                              child: const Text('移除证明标记')),
                      ],
                      if (error != null)
                        Text(error!, style: const TextStyle(color: Colors.red)),
                    ])),
            actions: [
              TextButton(
                  onPressed: busy ? null : () => Navigator.pop(context),
                  child: const Text('取消')),
              FilledButton(
                  onPressed: busy || loading ? null : save,
                  child: const Text('保存核对结果'))
            ]));
  }
}
