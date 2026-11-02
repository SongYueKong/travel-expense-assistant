import 'package:flutter/material.dart';
import 'package:travel_core/travel_core.dart';

enum TripMoreAction {
  tripSettings,
  tolerance,
  timeMatching,
  paymentLayout,
  mailImport,
  localImport
}

class TripActionsBar extends StatelessWidget {
  final bool busy, localImportAvailable;
  final int pdfCount, toleranceCents;
  final TimeMatchSettings timeSettings;
  final VoidCallback onPdf, onAddInvoice, onAddPayments, onExport;
  final VoidCallback? onAddTaxi;
  final ValueChanged<TripMoreAction> onMore;
  const TripActionsBar(
      {super.key,
      required this.busy,
      required this.localImportAvailable,
      required this.pdfCount,
      required this.toleranceCents,
      required this.timeSettings,
      required this.onPdf,
      required this.onAddInvoice,
      this.onAddTaxi,
      required this.onAddPayments,
      required this.onExport,
      required this.onMore});
  PopupMenuItem<TripMoreAction> item(
          TripMoreAction action, IconData icon, String title, String subtitle,
          {bool enabled = true}) =>
      PopupMenuItem(
          value: action,
          enabled: enabled,
          height: 72,
          child: ListTile(
              enabled: enabled,
              contentPadding: EdgeInsets.zero,
              dense: true,
              leading: Icon(icon),
              title: Text(title),
              subtitle: Text(subtitle)));
  @override
  Widget build(BuildContext context) => Wrap(
          spacing: 12,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            OutlinedButton.icon(
                onPressed: busy ? null : onPdf,
                icon: const Icon(Icons.folder_copy_outlined),
                label: Text('全部 PDF 材料（$pdfCount）')),
            FilledButton.icon(
                onPressed: busy ? null : onAddInvoice,
                icon: const Icon(Icons.note_add_outlined),
                label: const Text('添加发票与支付')),
            if (onAddTaxi != null)
              OutlinedButton.icon(
                  onPressed: busy ? null : onAddTaxi,
                  icon: const Icon(Icons.local_taxi_outlined),
                  label: const Text('添加出租车票')),
            OutlinedButton.icon(
                onPressed: busy ? null : onAddPayments,
                icon: const Icon(Icons.add_photo_alternate_outlined),
                label: const Text('添加支付截图')),
            OutlinedButton.icon(
                onPressed: busy ? null : onExport,
                icon: const Icon(Icons.picture_as_pdf),
                label: const Text('导出 PDF')),
            PopupMenuButton<TripMoreAction>(
                tooltip: '设置／更多',
                enabled: !busy,
                icon: const Icon(Icons.settings_outlined),
                constraints: const BoxConstraints(minWidth: 310, maxWidth: 390),
                onSelected: onMore,
                itemBuilder: (_) => [
                      item(TripMoreAction.tripSettings, Icons.date_range,
                          '出差日期／伙食补助', '调整起止日期、每日标准及是否计入补助'),
                      item(
                          TripMoreAction.tolerance,
                          Icons.tune,
                          '金额容差：${formatMoney(toleranceCents)} 元',
                          '调整当前差旅的金额匹配范围'),
                      item(
                          TripMoreAction.timeMatching,
                          Icons.schedule,
                          '时间匹配／重算',
                          '乘车前后 ${timeSettings.rideToleranceMinutes} 分钟；支付前后 ${timeSettings.paymentDelayMinutes} 分钟'),
                      const PopupMenuDivider(),
                      item(TripMoreAction.paymentLayout, Icons.grid_view,
                          '支付截图排版', '设置 A4 方向及行列数，本机保存并自动沿用'),
                      const PopupMenuDivider(),
                      item(
                          TripMoreAction.mailImport,
                          Icons.mark_email_unread_outlined,
                          '从邮箱补充发票',
                          '自动带入本机保存的邮箱账号'),
                      item(
                          TripMoreAction.localImport,
                          Icons.drive_folder_upload_outlined,
                          '从本地文件夹导入材料',
                          '导入文件夹中的 PDF 和支付截图，仅限空差旅',
                          enabled: localImportAvailable),
                    ]),
          ]);
}
