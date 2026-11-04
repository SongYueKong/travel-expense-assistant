import 'package:flutter/material.dart';
import 'package:travel_core/travel_core.dart';
import 'pdf_catalog.dart';
import 'pdf_preview_panel.dart';

class PdfLibraryDialog extends StatefulWidget {
  final PdfMaterial task;
  final DocumentPreviewLoader? loadPreview;
  const PdfLibraryDialog({super.key, required this.task, this.loadPreview});
  @override
  State<PdfLibraryDialog> createState() => _PdfLibraryDialogState();
}

class _PdfLibraryDialogState extends State<PdfLibraryDialog> {
  late final List<PdfCatalogEntry> entries;
  String query = '', kind = 'all';
  bool mailOnly = false;
  String? selected;
  @override
  void initState() {
    super.initState();
    entries = buildPdfCatalog(widget.task);
    selected = entries.firstOrNull?.id;
  }

  List<PdfCatalogEntry> get visible => entries.where((e) {
        final text = [
          e.name,
          e.material['document']?['number'],
          e.kindLabel,
          e.status,
          for (final s in e.sources)
            '${s['subject']} ${s['sender']} ${s['filename']}'
        ].join(' ').toLowerCase();
        return (kind == 'all' || e.kind == kind) &&
            (!mailOnly || e.sources.isNotEmpty) &&
            text.contains(query.toLowerCase());
      }).toList();

  void filter(void Function() update) => setState(() {
        update();
        if (!visible.any((e) => e.id == selected)) {
          selected = visible.firstOrNull?.id;
        }
      });

  Widget files(List<PdfCatalogEntry> items) => ListView.builder(
      itemCount: items.length,
      itemBuilder: (context, index) {
        final e = items[index],
            cents = e.material['document']?['totalCents'] as int?;
        return Card(
            child: ListTile(
                key: ValueKey('pdf-file-${e.id}'),
                selected: e.id == selected,
                selectedTileColor:
                    Theme.of(context).colorScheme.secondaryContainer,
                leading: Icon(
                    e.kind == 'itinerary' ? Icons.route : Icons.picture_as_pdf),
                title:
                    Text(e.name, maxLines: 2, overflow: TextOverflow.ellipsis),
                subtitle: Text(
                    '${e.kindLabel}${cents == null ? '' : ' · ¥${formatMoney(cents)}'}\n'
                    '${e.status}\n${e.sources.isEmpty ? '本地材料' : '邮件来源 ${e.sources.length} 处'}'),
                onTap: () => setState(() => selected = e.id)));
      });

  Widget detail(PdfCatalogEntry e) => SingleChildScrollView(
      key: ValueKey('pdf-detail-${e.id}'),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('关联状态：${e.status}'),
        if (e.sources.isNotEmpty)
          ExpansionTile(title: Text('邮件来源（${e.sources.length} 处）'), children: [
            for (final s in e.sources)
              ListTile(
                  title: Text(s['subject'] ?? '主题未记录'),
                  subtitle: SelectableText('附件：${s['filename'] ?? e.name}\n'
                      '${s['archiveFilename'] == null ? '' : '压缩包：${s['archiveFilename']}\n包内文件：${s['archiveMember'] ?? s['filename']}\n'}'
                      '发件人：${s['sender'] ?? '未记录'}\n邮箱：${s['account'] ?? '未记录'}\n'
                      '接收时间：${s['receivedAt'] ?? '未记录'}\n文件夹：${s['folder'] ?? '未记录'} · 邮件编号：${s['uid'] ?? '未记录'}')),
          ]),
        PdfPreviewPanel(
            key: ValueKey('pdf-preview-${e.id}'),
            material: e.material,
            title: e.kindLabel,
            loadPreview: widget.loadPreview,
            information: (d) =>
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  if (d['number'] != null)
                    SelectableText('发票号码：${d['number']}'),
                  if (d['totalCents'] is int)
                    Text('票面识别金额：¥${formatMoney(d['totalCents'])}'),
                  if (d['issueDate'] != null) Text('开票日期：${d['issueDate']}'),
                  if (d['type'] == 'itinerary')
                    Text('已识别行程：${(d['trips'] as List? ?? []).length} 笔'),
                ])),
      ]));

  @override
  Widget build(BuildContext context) {
    final items = visible;
    final current = entries.where((e) => e.id == selected).firstOrNull;
    return AlertDialog(
        title: const Text('全部 PDF 材料'),
        content: SizedBox(
            width: 1200,
            height: MediaQuery.sizeOf(context).height * .75,
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Wrap(
                  spacing: 12,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    SizedBox(
                        width: 320,
                        child: TextField(
                            key: const ValueKey('pdf-search'),
                            decoration: const InputDecoration(
                                labelText: '搜索文件名、票号或邮件主题',
                                prefixIcon: Icon(Icons.search)),
                            onChanged: (v) => filter(() => query = v))),
                    SizedBox(
                        width: 150,
                        child: DropdownButtonFormField<String>(
                            initialValue: kind,
                            isExpanded: true,
                            decoration:
                                const InputDecoration(labelText: '文件类型'),
                            items: const [
                              DropdownMenuItem(
                                  value: 'all', child: Text('全部 PDF')),
                              DropdownMenuItem(
                                  value: 'invoice', child: Text('发票')),
                              DropdownMenuItem(
                                  value: 'itinerary', child: Text('行程单')),
                              DropdownMenuItem(
                                  value: 'other', child: Text('其他 PDF'))
                            ],
                            onChanged: (v) {
                              if (v != null) filter(() => kind = v);
                            })),
                    SizedBox(
                        width: 190,
                        child: CheckboxListTile(
                            contentPadding: EdgeInsets.zero,
                            controlAffinity: ListTileControlAffinity.leading,
                            title: const Text('仅看邮件导入'),
                            value: mailOnly,
                            onChanged: (v) =>
                                filter(() => mailOnly = v == true))),
                  ]),
              const SizedBox(height: 8),
              Text(
                  '显示 ${items.length} / 共 ${entries.length} 份 PDF（按内容去重，保留全部邮件来源）'),
              const Text('仅查看材料，不改变关联、确认状态或统计金额。'),
              const SizedBox(height: 8),
              Expanded(
                  child: items.isEmpty
                      ? Center(
                          child: Text(entries.isEmpty
                              ? '当前任务尚无 PDF 材料，请先从邮箱或本地导入。'
                              : '没有符合筛选条件的 PDF。'))
                      : LayoutBuilder(builder: (context, size) {
                          if (size.maxWidth < 850) {
                            return Column(children: [
                              SizedBox(
                                  height: size.maxHeight * .35,
                                  child: files(items)),
                              const Divider(),
                              Expanded(
                                  child: current == null
                                      ? const SizedBox()
                                      : detail(current))
                            ]);
                          }
                          return Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                SizedBox(width: 380, child: files(items)),
                                const VerticalDivider(width: 20),
                                Expanded(
                                    child: current == null
                                        ? const SizedBox()
                                        : detail(current)),
                              ]);
                        })),
            ])),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context), child: const Text('关闭'))
        ]);
  }
}
