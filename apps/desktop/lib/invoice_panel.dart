import 'package:flutter/material.dart';
import 'package:travel_core/travel_core.dart';
import 'association_service.dart';
import 'pdf_preview_panel.dart';
export 'pdf_preview_panel.dart' show DocumentPreviewLoader;

class InvoicePanel extends StatelessWidget {
  final MaterialRecord invoice;
  final DocumentPreviewLoader? loadPreview;
  const InvoicePanel({super.key, required this.invoice, this.loadPreview});
  Widget field(String label, Object? value) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: SelectableText(
          '$label：${value == null || value.toString().isEmpty ? '未识别' : value}'));
  @override
  Widget build(BuildContext context) => invoice['paperTaxi'] == true
      ? Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('出租车纸票', style: Theme.of(context).textTheme.titleMedium),
          field('票面金额', '¥${formatMoney(invoice['invoiceCents'])}'),
          field('日期', invoice['document']?['expenseDate'] ?? '未填写（按金额匹配）'),
          const Text('纸质发票另行粘贴；导出时生成对应序号的空白框。'),
        ])
      : PdfPreviewPanel(
          material: invoice,
          loadPreview: loadPreview,
          title: '发票',
          showName: false,
          textTitle: '发票原文（购销方、项目等）',
          information: (d) {
            final amount = d['totalCents'] as int?;
            return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('发票信息', style: Theme.of(context).textTheme.titleMedium),
                  field(
                      '费用类别',
                      const {
                        'intercity': '城际交通',
                        'hotel': '酒店住宿',
                        'local': '市内交通'
                      }[invoice['category']]),
                  field('发票号码', d['number']),
                  field('核对发票金额', '¥${formatMoney(invoice['invoiceCents'])}'),
                  if (amount != null && amount != invoice['invoiceCents'])
                    field('票面识别金额', '¥${formatMoney(amount)}（与当前核对金额不同，请核实）'),
                  field('开票日期', d['issueDate']),
                  field('出行／消费日期', d['expenseDate']),
                  if (d['platform'] != null)
                    field(
                        '开票平台',
                        const {
                              'rail': '铁路',
                              'didi': '滴滴',
                              'gaode': '高德打车'
                            }[d['platform']] ??
                            d['platform']),
                  const Text('日期等识别字段供核对，以原件为准。',
                      style: TextStyle(color: Colors.blueGrey)),
                ]);
          });
}
