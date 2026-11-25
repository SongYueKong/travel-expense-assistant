import 'dart:io';
import 'package:travel_core/travel_core.dart';
import 'pending_service.dart';
import 'payment_identity.dart';
import 'material_merge_service.dart';
import 'services.dart';
import 'invoice_bundle.dart';
import 'pdf_catalog.dart';

/// 补充入口共用正常导入/关联流程；校验失败不改变任务，也不关闭待办。
class SupplementPdfImporter {
  final ProcessingClient engine;
  final String materialDirectory;
  SupplementPdfImporter(this.engine, this.materialDirectory);

  Future<MaterialData> importFiles(MaterialData task, List<String> paths,
      {PendingItem? mail}) async {
    if (paths.isEmpty || (mail != null && paths.length != 1)) {
      throw StateError('请一次拖入当前邮件对应的一份本地 PDF');
    }
    if (mail != null && (mail.kind != 'mail' || mail.state != 'pending')) {
      throw StateError('请选择待处理的邮件后再补充 PDF');
    }
    final additions = <MaterialData>[];
    for (final path in paths.toSet()) {
      final file = File(path);
      if (!path.toLowerCase().endsWith('.pdf') || !await file.exists()) {
        throw StateError('只支持本地 PDF 文件，请先完成下载；不要拖入文件夹或网页链接');
      }
      if (await file.length() > 25 * 1024 * 1024) {
        throw StateError('单份 PDF 不能超过 25 MB');
      }
      final inspected = MaterialData.from(await engine.call('inspect', {
        'path': path,
        'material_dir': materialDirectory,
        'purpose': 'invoice'
      }));
      final doc = inspected['document'] as Map? ?? {};
      if (mail != null) {
        if (doc['type'] != 'invoice' || doc['totalCents'] is! int) {
          throw StateError('PDF 未识别为有效发票，请核对原件或使用人工录入');
        }
        final expected = RegExp(r'发票号码\s*[:：]\s*(\d{8,20})(?!\d)')
            .firstMatch(mail.title)?[1];
        if (expected != null && doc['number'] != expected) {
          throw StateError('PDF 发票号码与当前邮件不一致，请选择对应邮件或重新下载');
        }
        final amount =
            RegExp(r'价税合计金额为\s*(\d+\.\d{2})').firstMatch(mail.title)?[1];
        if (amount != null && doc['totalCents'] != parseMoney(amount)) {
          throw StateError('PDF 金额与当前邮件不一致，请核对后再导入');
        }
      }
      for (final group in materialRecords(task['groups'])) {
        for (final member in invoiceMembers(group)) {
          if (doc['number'] != null &&
              member['document']?['number'] == doc['number'] &&
              member['document']?['totalCents'] != null &&
              member['document']['totalCents'] != doc['totalCents']) {
            throw StateError('已有相同发票号码但票面金额不同的材料，请先核对');
          }
        }
      }
      additions.add({
        ...?mail?.mailSource,
        'path': inspected['path'],
        'filename': file.uri.pathSegments.last,
        'purpose': 'invoice',
        if (mail != null)
          'partIndex': 'browser-pdf:${doc['number'] ?? inspected['hash']}'
      });
    }
    final changed = await MaterialMerger(engine, materialDirectory)
        .merge(task, mailFiles: additions);
    // 导入器将异常保留为待处理材料，不能因为回调结束就认为导入成功。
    final failed = materialRecords(changed['unmatchedMaterials'])
        .where((m) => m['failedInspection'] == true);
    if (failed.any((m) => additions.any((a) => a['path'] == m['path']))) {
      throw StateError('PDF 导入失败，待办仍保留，请重试');
    }
    if (mail == null) return changed;
    final number =
        RegExp(r'发票号码\s*[:：]\s*(\d{8,20})(?!\d)').firstMatch(mail.title)?[1];
    final present = buildPdfCatalog(changed).any((entry) =>
        entry.kind == 'invoice' &&
        (number != null
            ? (entry.material['document']?['number']) == number
            : additions.any((a) => a['path'] == entry.material['path'])));
    if (!present) throw StateError('尚未确认对应发票已导入，待办仍保留');
    return decidePending(changed, mail, 'resolved');
  }
}
