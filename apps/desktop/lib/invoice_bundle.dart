import 'dart:convert';
import 'package:travel_core/travel_core.dart';
import 'payment_identity.dart';

typedef BundleRecord = Map<String, dynamic>;
bool isInvoiceBundle(BundleRecord group) =>
    group['combinedInvoices'] is List &&
    (group['combinedInvoices'] as List).isNotEmpty;
List<BundleRecord> invoiceMembers(BundleRecord group) => isInvoiceBundle(group)
    ? (group['combinedInvoices'] as List).cast<BundleRecord>()
    : [group];
List<String> bundleInvoiceNumbers(BundleRecord group, int index) => [
      for (var i = 0; i < invoiceMembers(group).length; i++)
        isInvoiceBundle(group)
            ? '${invoiceNumber(index + 1)}-${(i + 1).toString().padLeft(2, '0')}'
            : invoiceNumber(index + 1)
    ];

/// 支付净额按票面金额权重分配到汇总行，余分按最大余数分配；不会新增金额。
List<int> allocateBundleAmount(int total, List<int> weights) {
  if (total < 0 || weights.isEmpty || weights.any((n) => n < 0)) {
    throw StateError('分配金额无效');
  }
  final sum = weights.fold<int>(0, (a, b) => a + b);
  if (sum == 0) return [total, ...List.filled(weights.length - 1, 0)];
  // 使用BigInt避免乘法溢出；金额仍以整数分存储。
  final products = [
    for (final w in weights) BigInt.from(total) * BigInt.from(w)
  ];
  final divisor = BigInt.from(sum);
  final values = [for (final p in products) (p ~/ divisor).toInt()];
  final order = List.generate(weights.length, (i) => i)
    ..sort((a, b) {
      final n = (products[b] % divisor).compareTo(products[a] % divisor);
      return n == 0 ? a.compareTo(b) : n;
    });
  final left = total - values.fold<int>(0, (a, b) => a + b);
  for (var i = 0; i < left; i++) {
    values[order[i]]++;
  }
  return values;
}

BundleRecord combineInvoiceGroups(BundleRecord source, Set<int> indices,
    {required int primary}) {
  final task = jsonDecode(jsonEncode(source)) as BundleRecord;
  final groups = (task['groups'] as List).cast<BundleRecord>();
  if (indices.length < 2 ||
      !indices.contains(primary) ||
      indices.any((i) => i < 0 || i >= groups.length)) {
    throw StateError('请至少选择两组发票');
  }
  final chosen = [
    groups[primary],
    for (final i in indices.toList()..sort())
      if (i != primary) groups[i]
  ];
  final members = <BundleRecord>[];
  final seen = <String>{}, numbers = <String>{};
  final payments = <BundleRecord>[];
  final identities = MaterialIdentityIndex();
  for (final group in chosen) {
    for (final member in invoiceMembers(group)) {
      if (member['category'] != 'intercity' ||
          member['paperTaxi'] == true ||
          member['invoiceCents'] is! int ||
          member['invoiceCents'] < 0 ||
          member['path'] is! String) {
        throw StateError('仅支持已识别金额的城际交通电子发票');
      }
      final key = member['hash'] ??
          (member['path'] as String).replaceAll('\\', '/').toLowerCase();
      final number = member['document']?['number'];
      if (!seen.add(key) ||
          (number is String && number.isNotEmpty && !numbers.add(number))) {
        throw StateError('同一张发票不能重复合并');
      }
      final copy = Map<String, dynamic>.from(member)
        ..remove('combinedInvoices');
      copy.addAll({
        'payments': <BundleRecord>[],
        'manuallyAssociated': false,
        'confirmed': false,
        'complete': false,
        'suggestionComplete': false,
        'matchingReasons': ['待重新选择支付']
      });
      members.add(copy);
    }
    for (final raw in group['payments'] as List? ?? []) {
      final payment = Map<String, dynamic>.from(raw);
      if (identities.find(payment) == null) {
        identities.add(payment);
        payments.add(payment);
      }
    }
  }
  if (payments.length > 1) throw StateError('所选发票已关联不同支付，请先解除多余支付关联');
  final total =
      members.fold<int>(0, (sum, m) => sum + (m['invoiceCents'] as int));
  final bundle = <String, dynamic>{
    ...members.first,
    'combinedInvoices': members,
    'invoiceCents': total,
    'name': members.first['name'],
    'payments': payments,
    'trips': <BundleRecord>[],
    'itineraries': <String>[],
    'itineraryMaterials': <BundleRecord>[],
    'manuallyAssociated': true,
    'confirmed': false,
    'complete': false,
    'suggestionComplete': payments.length == 1,
    'matchingReasons': ['共同支付组：${members.length} 张发票按合计核对一笔实际支付']
  };
  final first = indices.reduce((a, b) => a < b ? a : b);
  task['groups'] = [
    for (var i = 0; i < groups.length; i++)
      if (i == first) bundle else if (!indices.contains(i)) groups[i]
  ];
  final used = MaterialIdentityIndex([
    for (final g in (task['groups'] as List))
      ...((g['payments'] as List).cast<BundleRecord>())
  ]);
  task['unmatchedPayments'] = [
    for (final p in (task['unmatchedPayments'] as List? ?? []))
      if (used.find(Map<String, dynamic>.from(p)) == null) p
  ];
  return task;
}

BundleRecord splitInvoiceGroup(BundleRecord source, int index) {
  final task = jsonDecode(jsonEncode(source)) as BundleRecord;
  final groups = (task['groups'] as List).cast<BundleRecord>();
  final group = groups[index];
  if (!isInvoiceBundle(group)) throw StateError('当前不是共同支付组');
  final pool = MaterialIdentityIndex();
  final unmatched = <BundleRecord>[];
  for (final p in [
    ...(task['unmatchedPayments'] as List? ?? []),
    ...(group['payments'] as List)
  ]) {
    final copy = Map<String, dynamic>.from(p);
    if (pool.find(copy) == null) {
      pool.add(copy);
      unmatched.add(copy);
    }
  }
  task['groups'] = [
    ...groups.take(index),
    ...invoiceMembers(group),
    ...groups.skip(index + 1)
  ];
  task['unmatchedPayments'] = unmatched;
  return task;
}
