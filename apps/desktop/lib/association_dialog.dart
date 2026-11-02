import 'dart:io';
import 'package:flutter/material.dart';
import 'package:travel_core/travel_core.dart';
import 'association_service.dart';
import 'invoice_panel.dart';
import 'pdf_preview_panel.dart';
import 'pdf_library_dialog.dart';
import 'matching_helpers.dart';
import 'payment_identity.dart';
import 'payment_time_dialog.dart';

class AssociationDialog extends StatefulWidget {
  final MaterialRecord task;
  final int groupIndex;
  final DocumentPreviewLoader? loadDocumentPreview;
  final MaterialRecord? focusMaterial;
  const AssociationDialog(
      {super.key,
      required this.task,
      required this.groupIndex,
      this.loadDocumentPreview,
      this.focusMaterial});
  @override
  State<AssociationDialog> createState() => _AssociationDialogState();
}

class _AssociationDialogState extends State<AssociationDialog> {
  late final AssociationEditor editor;
  final List<TextEditingController> amounts = [];
  int active = 0;
  bool showAll = false;
  String documentTab = 'invoice';
  bool refreshingItinerary = false;
  String? itineraryMessage;
  String? error;

  @override
  void initState() {
    super.initState();
    editor = AssociationEditor(widget.task, widget.groupIndex);
    final focus = widget.focusMaterial;
    if (focus != null) {
      showAll = isScreenshot(focus);
      final key = identityPath(focus['path']);
      if (editor.group['category'] == 'local' &&
          editor.itineraries.containsKey(key) &&
          !editor.itineraryOwners.containsKey(key)) {
        editor.selectItinerary(key);
        documentTab = 'itinerary';
      }
    }
    resetAmounts();
  }

  void resetAmounts() {
    for (final c in amounts) {
      c.dispose();
    }
    amounts.clear();
    for (final cents in editor.amounts) {
      amounts.add(
          TextEditingController(text: cents == null ? '' : formatMoney(cents)));
    }
    active = 0;
  }

  @override
  void dispose() {
    for (final c in amounts) {
      c.dispose();
    }
    super.dispose();
  }

  void choose(String? key) {
    try {
      editor.choose(active, key);
      amounts[active].text = editor.amounts[active] == null
          ? ''
          : formatMoney(editor.amounts[active]!);
      setState(() => error = null);
    } catch (e) {
      setState(() => error = '$e');
    }
  }

  void save() {
    try {
      for (var i = 0; i < amounts.length; i++) {
        if (editor.selected[i] != null) {
          editor.amounts[i] = parseMoney(amounts[i].text);
        }
      }
      Navigator.pop(context, editor.build());
    } catch (e) {
      setState(() => error = '$e');
    }
  }

  Future<void> refreshItinerary() async {
    final key = editor.itinerary;
    if (key == null || widget.loadDocumentPreview == null) return;
    try {
      for (var i = 0; i < amounts.length; i++) {
        if (editor.selected[i] != null) {
          editor.amounts[i] = parseMoney(amounts[i].text);
        }
      }
      setState(() {
        refreshingItinerary = true;
        error = null;
        itineraryMessage = null;
      });
      final result = await widget.loadDocumentPreview!(
          editor.itineraries[key]!['path'], 0);
      if (!mounted || key != editor.itinerary) return;
      editor.refreshItinerary(MaterialRecord.from(result['document']),
          text: result['text']);
      setState(() {
        resetAmounts();
        documentTab = 'itinerary';
        itineraryMessage =
            '已重新识别 ${editor.trips.length} 笔，保留 ${editor.selected.where((p) => p != null).length} 笔已选支付；保存选择后生效';
      });
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      if (mounted) setState(() => refreshingItinerary = false);
    }
  }

  Widget amountSummary() {
    var total = 0;
    var valid = true;
    for (var i = 0; i < amounts.length; i++) {
      if (editor.selected[i] == null) continue;
      try {
        final cents = parseMoney(amounts[i].text);
        if (cents <= 0) valid = false;
        total += cents;
      } on FormatException {
        valid = false;
      }
    }
    final invoice = editor.group['invoiceCents'] as int;
    final difference = invoice - total;
    final ready = valid && editor.selectionComplete;
    return Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Text(
            valid
                ? '已选 ${editor.selected.where((k) => k != null).length} 笔 · 支付合计 ¥${formatMoney(total)} · '
                    '${ready ? '核算预估 ¥${formatMoney(invoice < total ? invoice : total)}（复核可选）' : '选择尚未完整，暂不能导出'}'
                    '${difference.abs() > editor.tolerance ? ' · 与发票差额超过容差，请核实' : ''}'
                : '支付金额必须大于零，最多保留两位小数',
            style: TextStyle(
                color: ready && difference.abs() <= editor.tolerance
                    ? Colors.teal
                    : Colors.deepOrange)));
  }

  Widget picture(String path, {double height = 120, double width = 75}) =>
      Image.file(File(path),
          cacheWidth: (width * MediaQuery.devicePixelRatioOf(context)).ceil(),
          height: height,
          width: width,
          fit: BoxFit.contain,
          errorBuilder: (_, __, ___) => SizedBox(
              height: height,
              width: width,
              child: const Center(child: Text('图片无法读取'))));

  Future<void> preview(MaterialRecord m) => showDialog<void>(
      context: context,
      builder: (context) => Dialog(
          child: SizedBox(
              width: 800,
              height: MediaQuery.sizeOf(context).height * .85,
              child: Column(children: [
                ListTile(
                    title: Text(m['name'] ?? '支付截图'),
                    trailing: IconButton(
                        tooltip: '关闭预览',
                        onPressed: () => Navigator.pop(context),
                        icon: const Icon(Icons.close))),
                const Text('可滚轮缩放、拖动查看'),
                Expanded(
                    child: InteractiveViewer(
                        minScale: .5,
                        maxScale: 8,
                        child: Center(
                            child: Image.file(File(m['path']),
                                fit: BoxFit.contain,
                                errorBuilder: (_, __, ___) =>
                                    const Text('图片无法读取，请检查本地文件'))))),
              ]))));

  Widget itineraryPicker() {
    final keys = editor.itineraries.keys.toList();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      DropdownButtonFormField<String>(
          key: ValueKey('itinerary-${editor.itinerary}'),
          initialValue: editor.itinerary,
          isExpanded: true,
          decoration: const InputDecoration(labelText: '配套行程单'),
          items: [
            const DropdownMenuItem(value: '', child: Text('未选择行程单')),
            for (final key in keys)
              DropdownMenuItem(
                  value: key,
                  enabled: !editor.itineraryOwners.containsKey(key),
                  child: Text(
                      '${editor.itineraries[key]!['name']} · '
                      '${editor.itineraryOwners[key] == null ? (editor.itineraryRecommended(key) ? '平台和总额符合' : '请核对平台、总额和行程完整性') : '已被 ${editor.itineraryOwners[key]} 使用'}',
                      overflow: TextOverflow.ellipsis)),
          ],
          onChanged: (key) {
            final next = key == '' ? null : key;
            if (next == editor.itinerary) return;
            setState(() {
              editor.selectItinerary(next);
              resetAmounts();
              documentTab = 'itinerary';
              itineraryMessage = null;
              error = null;
            });
          }),
      const SizedBox(height: 8),
      if (!editor.byTrip && editor.group['paperTaxi'] != true)
        const Text('尚未取得逐条行程，请选择完整行程单；无法识别的材料需手工核对。',
            style: TextStyle(color: Colors.deepOrange)),
      if (editor.itinerary != null &&
          !editor.itineraryRecommended(editor.itinerary!))
        const Text('该行程单与发票的识别信息不完全一致，请核对平台与金额。',
            style: TextStyle(color: Colors.deepOrange)),
      const SizedBox(height: 12),
    ]);
  }

  Widget documentContext() =>
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (editor.group['category'] == 'local' &&
            editor.group['paperTaxi'] != true) ...[
          SegmentedButton<String>(
              segments: const [
                ButtonSegment(
                    value: 'invoice',
                    label: Text('发票'),
                    icon: Icon(Icons.receipt_long)),
                ButtonSegment(
                    value: 'itinerary',
                    label: Text('行程单'),
                    icon: Icon(Icons.route)),
              ],
              selected: {
                documentTab
              },
              onSelectionChanged: (value) =>
                  setState(() => documentTab = value.single)),
          const SizedBox(height: 10),
          if (editor.itinerary != null) ...[
            if (editor.itineraries[editor.itinerary]?['document']
                    ?['expectedCount'] is int &&
                editor.itineraries[editor.itinerary]!['document']
                        ['expectedCount'] !=
                    editor.trips.length)
              Text(
                  '行程单标注 ${editor.itineraries[editor.itinerary]!['document']['expectedCount']} 笔，当前保存 ${editor.trips.length} 笔，请重新识别。',
                  style: const TextStyle(color: Colors.deepOrange)),
            if (widget.loadDocumentPreview != null)
              OutlinedButton.icon(
                  onPressed: refreshingItinerary ? null : refreshItinerary,
                  icon: const Icon(Icons.refresh),
                  label: Text(refreshingItinerary ? '正在重新识别…' : '重新识别行程单')),
            if (itineraryMessage != null)
              Text(itineraryMessage!,
                  style: const TextStyle(color: Colors.teal)),
            const SizedBox(height: 8),
          ],
        ],
        if (documentTab == 'invoice')
          InvoicePanel(
              invoice: editor.group, loadPreview: widget.loadDocumentPreview)
        else if (editor.itinerary == null ||
            editor.itineraries[editor.itinerary] == null)
          const Card(
              child: Padding(
                  padding: EdgeInsets.all(16),
                  child: Text('尚未选择配套行程单。请在上方选择，或打开“全部 PDF 材料”核对未关联文件。')))
        else
          PdfPreviewPanel(
              key: ValueKey('itinerary-preview-${editor.itinerary}'),
              material: editor.itineraries[editor.itinerary]!,
              title: '行程单',
              textTitle: '行程单原文（全部行程）',
              loadPreview: widget.loadDocumentPreview,
              information: (d) => Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(d['totalCents'] is int
                            ? '行程合计：¥${formatMoney(d['totalCents'])}'
                            : '行程合计：未识别'),
                        Text('已识别 ${(d['trips'] as List? ?? []).length} 笔行程'),
                        if (editor.byTrip)
                          Text('当前核对：行程 ${editor.trips[active]['index']} · '
                              '${editor.trips[active]['date']} ${editor.trips[active]['time'] ?? ''} · ¥${formatMoney(editor.trips[active]['cents'])}'),
                      ])),
      ]);

  Widget slotList() =>
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('1. 选择费用或行程'),
        const SizedBox(height: 8),
        DropdownButtonFormField<int>(
            key: ValueKey('slot-$active-${editor.selected.length}'),
            initialValue: active,
            isExpanded: true,
            decoration: const InputDecoration(labelText: '当前核对项目'),
            items: [
              for (var i = 0; i < editor.selected.length; i++)
                DropdownMenuItem(
                    value: i,
                    child: Text(
                        '${editor.byTrip ? '行程 ${editor.trips[i]['index']} · ${editor.trips[i]['date']} ${editor.trips[i]['time'] ?? ''}' : '支付凭证 ${i + 1}'}'
                        ' · ${editor.selected[i] == null ? '未选择支付' : '已选支付'}',
                        overflow: TextOverflow.ellipsis))
            ],
            onChanged: (value) {
              if (value != null) setState(() => active = value);
            }),
        if (!editor.byTrip)
          TextButton.icon(
              onPressed: () => setState(() {
                    editor.addSlot();
                    amounts.add(TextEditingController());
                    active = editor.selected.length - 1;
                  }),
              icon: const Icon(Icons.add),
              label: const Text('增加一笔支付')),
        if (!editor.byTrip && editor.selected.length > 1)
          TextButton(
              onPressed: () => setState(() {
                    editor.selected.removeAt(active);
                    editor.amounts.removeAt(active);
                    amounts.removeAt(active).dispose();
                    active = 0;
                  }),
              child: const Text('移除当前支付项')),
      ]);

  Widget candidates() {
    final keys = editor.sortedCandidates(
        active,
        editor.payments.keys.where((key) =>
            showAll ||
            key == editor.selected[active] ||
            editor.recommended(key, active)));
    final current = editor.selected[active];
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(
          '2. 为${editor.byTrip ? '行程 ${editor.trips[active]['index']}' : '支付项 ${active + 1}'}选择截图',
          style: Theme.of(context).textTheme.titleMedium),
      if (editor.byTrip && editor.trips[active]['source'] != null)
        ExpansionTile(title: const Text('查看该条行程原文（时间、起终点）'), children: [
          Padding(
              padding: const EdgeInsets.all(8),
              child: SelectableText(editor.trips[active]['source']))
        ]),
      Text(
          '参考金额 ¥${formatMoney(editor.charge(active).cents)} · 容差 ¥${formatMoney(editor.tolerance)}'),
      const Text('排序：金额差绝对值优先，其次时间差；未知差值靠后。'),
      const Text('默认列出类别、平台、金额和具体时间符合的候选。时间未识别时可显示全部截图并人工指定。'),
      CheckboxListTile(
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
          value: showAll,
          title: const Text('显示全部截图（含条件不符、未识别和已占用）'),
          onChanged: (v) => setState(() => showAll = v == true)),
      if (current != null) ...[
        Text('当前选择：${editor.payments[current]!['name']}'),
        Row(children: [
          Expanded(
              child: TextField(
                  key: ValueKey('amount-$active'),
                  controller: amounts[active],
                  onChanged: (_) => setState(() {}),
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  decoration:
                      const InputDecoration(labelText: '实际支付净额（元，可纠正识别结果）'))),
          TextButton(
              onPressed: () => choose(null), child: const Text('解除当前关联')),
        ]),
        if (!editor.recommended(current, active))
          const Text('该截图的识别信息不满足自动匹配条件，请核对后决定是否保留。',
              style: TextStyle(color: Colors.deepOrange)),
        const SizedBox(height: 12),
      ],
      if (keys.isEmpty)
        const Padding(
            padding: EdgeInsets.all(16),
            child: Text('没有符合条件的候选。可勾选“显示全部截图”，或返回主界面补充支付截图。')),
      for (final key in keys) candidateCard(key),
    ]);
  }

  Widget candidateCard(String key) {
    final m = editor.payments[key]!, owner = editor.occupied(key, active);
    final selected = key == editor.selected[active];
    final cents = editor.recognizedAmount(key);
    final difference =
        cents == null ? null : cents - editor.charge(active).cents;
    final fits = editor.recommended(key, active);
    final evidence =
        cents == null ? null : paymentEvidence({...m, 'cents': cents});
    final timing = evidence == null || editor.group['category'] != 'local'
        ? null
        : assessPaymentTiming(editor.charge(active), evidence,
            settings: timeSettingsOf(editor.task));
    return Card(
        child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              InkWell(onTap: () => preview(m), child: picture(m['path'])),
              const SizedBox(width: 12),
              Expanded(
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                    Text(m['name'] ?? key,
                        style: Theme.of(context).textTheme.titleSmall),
                    Text(cents == null
                        ? '金额未识别'
                        : '支付 ¥${formatMoney(cents)} · 差额 ${difference! >= 0 ? '+' : ''}${formatMoney(difference)} 元'),
                    if (paymentDiscountCents(m) > 0)
                      Text(
                          '截图优惠 −${formatMoney(paymentDiscountCents(m))} 元${evidence != null && discountExplains(editor.charge(active), evidence) ? ' · 差额恰好等于优惠' : ''}'),
                    Text(
                        '日期：${m['ocr']?['paymentDate'] ?? '未识别'} · 平台：${m['ocr']?['platform'] ?? '未识别'}'),
                    if (editor.group['category'] == 'local' ||
                        evidence?.rideAt != null)
                      Text('乘车时间：${formatBeijingTimestamp(evidence?.rideAt)}'),
                    if (editor.group['category'] == 'local' ||
                        evidence?.paidAt != null)
                      Text('支付时间：${formatBeijingTimestamp(evidence?.paidAt)}'),
                    if (timing != null)
                      Text(timing.reason,
                          style: TextStyle(
                              color: timing.eligible
                                  ? Colors.teal
                                  : Colors.deepOrange)),
                    if (m['timeOverrides'] != null)
                      const Text('时间已对照原图纠正（保留 OCR 原文）',
                          style: TextStyle(color: Colors.teal)),
                    Text(
                        owner ??
                            (selected
                                ? '已选择，保存后生效'
                                : (fits
                                    ? '符合自动匹配条件 · 可选择'
                                    : '信息不全或条件不符 · 可人工指定')),
                        style: TextStyle(
                            color: owner != null
                                ? Colors.deepOrange
                                : Colors.teal)),
                    Wrap(spacing: 8, children: [
                      OutlinedButton(
                          onPressed: () => preview(m),
                          child: const Text('放大查看')),
                      if (editor.group['category'] == 'local')
                        OutlinedButton(
                            key: ValueKey('correct-time-$key'),
                            onPressed: owner != null
                                ? null
                                : () async {
                                    final change =
                                        await showDialog<PaymentTimeChange>(
                                            context: context,
                                            builder: (_) =>
                                                PaymentTimeDialog(material: m));
                                    if (change != null && mounted) {
                                      setState(() => editor.correctPaymentTimes(
                                          key, change.values));
                                    }
                                  },
                            child: const Text('纠正时间')),
                      FilledButton.tonal(
                          key: ValueKey('choose-$key'),
                          onPressed: owner != null || selected
                              ? null
                              : () => choose(key),
                          child: Text(selected
                              ? '已选择'
                              : (owner != null ? '已占用' : '选择此截图'))),
                    ]),
                  ])),
            ])));
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
          title: Text('选择／调整关联 · ${invoiceNumber(widget.groupIndex + 1)}'),
          content: SizedBox(
              width: 1050,
              height: MediaQuery.sizeOf(context).height * .7,
              child: AbsorbPointer(
                  absorbing: refreshingItinerary,
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                            '${editor.group['name']} · 发票 ¥${formatMoney(editor.group['invoiceCents'])}'),
                        const Text('保存后清除本组复核标记，匹配完整可直接导出；其他组的占用须先在原组解除。'),
                        if (widget.focusMaterial != null)
                          Text(
                              '正在处理：${widget.focusMaterial!['name']}；请核对目标行程和截图后保存。',
                              style: const TextStyle(color: Colors.teal)),
                        if (editor.group['category'] == 'local')
                          itineraryPicker(),
                        const SizedBox(height: 12),
                        Expanded(child: LayoutBuilder(builder: (context, size) {
                          if (size.maxWidth < 700) {
                            return SingleChildScrollView(
                                child: Column(children: [
                              documentContext(),
                              slotList(),
                              const Divider(),
                              candidates()
                            ]));
                          }
                          return Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                SizedBox(
                                    width: 350,
                                    child: SingleChildScrollView(
                                        child: documentContext())),
                                const VerticalDivider(width: 24),
                                Expanded(
                                    child: SingleChildScrollView(
                                        key: ValueKey(active),
                                        child: Column(children: [
                                          slotList(),
                                          const SizedBox(height: 16),
                                          candidates()
                                        ]))),
                              ]);
                        })),
                        amountSummary(),
                        if (error != null)
                          Text(error!,
                              style: const TextStyle(color: Colors.red)),
                      ]))),
          actions: [
            OutlinedButton.icon(
                onPressed: refreshingItinerary
                    ? null
                    : () => showDialog<void>(
                        context: context,
                        builder: (_) => PdfLibraryDialog(
                            task: editor.task,
                            loadPreview: widget.loadDocumentPreview)),
                icon: const Icon(Icons.folder_copy_outlined),
                label: const Text('全部 PDF 材料')),
            TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('取消')),
            FilledButton(
                onPressed: refreshingItinerary ? null : save,
                child: const Text('保存选择')),
          ]);
}
