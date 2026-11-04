import 'invoice_bundle.dart';
import 'dart:convert';
import 'payment_identity.dart';

List<MaterialData> materialRecords(dynamic value) =>
    (value as List? ?? []).cast<MaterialData>();
MaterialData copyTask(MaterialData task) => jsonDecode(jsonEncode(task));

class PendingItem {
  final String id, kind, title, reason;
  final MaterialData? material;
  final String state;
  const PendingItem(
      {required this.id,
      required this.kind,
      required this.title,
      required this.reason,
      this.material,
      this.state = 'pending'});
  bool get isMaterial => material != null;
  MaterialData toJson() => {
        'id': id,
        'kind': kind,
        'title': title,
        'reason': reason,
        if (material != null) 'material': material
      };
  factory PendingItem.fromJson(MaterialData value,
          {String state = 'pending'}) =>
      PendingItem(
          id: value['id'],
          kind: value['kind'],
          title: value['title'],
          reason: value['reason'],
          material: value['material'],
          state: state);
}

Iterable<MaterialData> assignedMaterials(MaterialData task) sync* {
  for (final g in materialRecords(task['groups'])) {
    yield g;
    if (isInvoiceBundle(g)) yield* invoiceMembers(g);
    yield* materialRecords(g['payments']);
    for (final member in invoiceMembers(g)) {
      yield* materialRecords(member['itineraryMaterials']);
      for (final path in member['itineraries'] as List? ?? []) {
        yield {'path': path};
      }
    }
  }
}

String materialPendingId(MaterialData m) =>
    'material:${m['hash'] ?? identityPath(m['path'])}';

String? _mailMessageKey(MaterialData source, {String? account}) {
  final parts = [
    source['account'] ?? account,
    source['folder'],
    source['uidValidity'],
    source['uid']
  ];
  if (parts.any((value) => value == null || value.toString().isEmpty)) {
    return null;
  }
  return jsonEncode([
    parts[0].toString().trim().toLowerCase(),
    ...parts.skip(1).map((v) => v.toString())
  ]);
}

Iterable<MaterialData> _mailOrigins(MaterialData material) sync* {
  yield material;
  if (material['mailSource'] is Map) {
    yield* _mailOrigins(MaterialData.from(material['mailSource']));
  }
  for (final source in [
    ...materialRecords(material['pdfSources']),
    ...materialRecords(material['additionalSources'])
  ]) {
    yield* _mailOrigins(source);
  }
}

Set<String> _pdfMessageKeys(MaterialData task) {
  final result = <String>{};
  final materials = [
    ...materialRecords(task['mailSources']),
    ...materialRecords(task['pdfMaterials']),
    ...materialRecords(task['unmatchedMaterials']),
    ...assignedMaterials(task)
  ];
  final failedPaths = {
    for (final material in materials)
      if (material['failedInspection'] == true && material['path'] is String)
        identityPath(material['path'])
  };
  for (final material in materials) {
    final path = material['path'];
    if (path is! String ||
        !path.toLowerCase().endsWith('.pdf') ||
        failedPaths.contains(identityPath(path))) {
      continue;
    }
    for (final source in _mailOrigins(material)) {
      final key = _mailMessageKey(source);
      if (key != null) result.add(key);
    }
  }
  return result;
}

bool _archiveWithoutPdf(MaterialData item) =>
    item['code'] == 'archive_no_pdf' ||
    // 兼容旧版已保存的待办，避免为清除此提示而再次连接邮箱。
    (item['code'] == null &&
        RegExp(r'ZIP\s*内未找到\s*PDF').hasMatch(item['reason']?.toString() ?? ''));

List<PendingItem> pendingItems(MaterialData task,
    {bool includeHandled = false}) {
  final result = <PendingItem>[], seen = <String>{};
  final decisions = {
    for (final d in materialRecords(task['issueDecisions'])) d['id']: d
  };
  void add(PendingItem item) {
    if (!seen.add(item.id)) return;
    if (!decisions.containsKey(item.id)) result.add(item);
  }

  final history = materialRecords(task['mailHistory']);
  final pdfMessages = _pdfMessageKeys(task);
  if (history.isNotEmpty) {
    for (final kind in ['pending', 'failures']) {
      for (final m in materialRecords(history.last[kind])) {
        final messageKey = _mailMessageKey(m, account: history.last['account']);
        if (kind == 'pending' &&
            _archiveWithoutPdf(m) &&
            messageKey != null &&
            pdfMessages.contains(messageKey)) {
          continue;
        }
        add(PendingItem(
            id: 'mail:$kind:${jsonEncode([
                  history.last['account'],
                  m['folder'],
                  m['uidValidity'],
                  m['uid'],
                  m['partIndex'],
                  m['subject'],
                  m['reason']
                ])}',
            kind: 'mail',
            title:
                '${kind == 'pending' ? '邮件待处理' : '邮件获取失败'}：${m['subject'] ?? m['folder'] ?? ''}',
            reason: '${m['reason'] ?? ''}\n请重新获取邮件，或手工下载后导入材料；标记解决仅关闭这条提示。'));
      }
    }
  }
  for (final issue in task['importIssues'] as List? ?? []) {
    if ([
      ...materialRecords(task['unmatchedMaterials']),
      ...materialRecords(task['ignoredMaterials'])
    ].any((m) =>
        m['failedInspection'] == true &&
        issue.toString().startsWith('${m['path']}:'))) {
      continue;
    }
    add(PendingItem(
        id: 'import:$issue',
        kind: 'import',
        title: '导入异常',
        reason: issue.toString()));
  }
  final ignored =
      MaterialIdentityIndex(materialRecords(task['ignoredMaterials']));
  final used = MaterialIdentityIndex(assignedMaterials(task)),
      listed = MaterialIdentityIndex();
  for (final bucket in ['unmatchedPayments', 'unmatchedMaterials']) {
    for (final m in materialRecords(task[bucket])) {
      if (ignored.find(m) != null ||
          used.find(m) != null ||
          listed.find(m) != null) {
        continue;
      }
      listed.add(m);
      final payment = bucket == 'unmatchedPayments';
      add(PendingItem(
          id: materialPendingId(m),
          kind: payment ? 'payment' : 'material',
          title: '${payment ? '未匹配支付' : '待处理材料'}：${m['name'] ?? '未命名材料'}',
          material: m,
          reason: payment
              ? '尚未关联到发票或行程。请对照类别、金额和时间选择关联；存在多笔候选或时间超范围时需人工指定。'
              : (m['failedInspection'] == true
                  ? '文件识别失败：${m['inspectionError']}\n可重新识别，或检查原文件后再次导入。'
                  : m['document']?['type'] == 'itinerary'
                      ? '行程单尚未关联，或行程条数、合计未校验通过。可以重新识别或选择对应发票。'
                      : '材料尚未识别为完整费用，或内容未能自动识别。可查看原件，重新识别或手工录入。')));
    }
  }
  if (includeHandled) {
    for (final m in materialRecords(task['ignoredMaterials'])) {
      result.add(PendingItem(
          id: materialPendingId(m),
          kind: m['pendingKind'] ?? 'material',
          title: '已忽略：${m['name'] ?? '材料'}',
          reason: '用户已忽略，不参与自动匹配；可恢复待处理。',
          material: m,
          state: 'ignored'));
    }
    for (final d in decisions.values) {
      result.add(PendingItem.fromJson(MaterialData.from(d['item']),
          state: d['state']));
    }
  }
  return result;
}

/// 忽略只移动待处理材料，不修改费用组、不补齐证据，也不删除原文件。
MaterialData decidePending(
    MaterialData source, PendingItem item, String state) {
  final task = copyTask(source);
  if (item.isMaterial) {
    final material = item.material!,
        identity = MaterialIdentityIndex([material]);
    final used = MaterialIdentityIndex(assignedMaterials(task));
    if (state != 'restore' && used.find(material) != null) {
      throw StateError('材料已经用于费用，请在费用组中调整关联');
    }
    task['ignoredMaterials'] = [
      for (final m in materialRecords(task['ignoredMaterials']))
        if (identity.find(m) == null) m
    ];
    if (state == 'restore') {
      final restored = {...material}
        ..remove('ignoredAt')
        ..remove('pendingKind');
      final bucket =
          item.kind == 'payment' ? 'unmatchedPayments' : 'unmatchedMaterials';
      task[bucket] = [...materialRecords(task[bucket]), restored];
    } else {
      if (state != 'ignored') throw StateError('材料需要通过实际关联或重新识别解决');
      task['ignoredMaterials'].add({
        ...material,
        'pendingKind': item.kind,
        'ignoredAt': DateTime.now().toIso8601String()
      });
    }
    for (final bucket in ['unmatchedPayments', 'unmatchedMaterials']) {
      if (state == 'restore') continue;
      task[bucket] = [
        for (final m in materialRecords(task[bucket]))
          if (identity.find(m) == null) m
      ];
    }
  } else {
    task['issueDecisions'] = [
      for (final d in materialRecords(task['issueDecisions']))
        if (d['id'] != item.id) d
    ];
    if (state != 'restore') {
      task['issueDecisions'].add({
        'id': item.id,
        'state': state,
        'item': item.toJson(),
        'at': DateTime.now().toIso8601String()
      });
    }
  }
  return cleanPending(task);
}

MaterialData cleanPending(MaterialData source) {
  final task = copyTask(source),
      used = MaterialIdentityIndex(assignedMaterials(source)),
      ignored =
          MaterialIdentityIndex(materialRecords(source['ignoredMaterials'])),
      listed = MaterialIdentityIndex();
  for (final bucket in ['unmatchedPayments', 'unmatchedMaterials']) {
    task[bucket] = [
      for (final m in materialRecords(source[bucket]))
        if (used.find(m) == null &&
            ignored.find(m) == null &&
            listed.find(m) == null)
          (listed.add(m))
    ];
  }
  return task;
}
