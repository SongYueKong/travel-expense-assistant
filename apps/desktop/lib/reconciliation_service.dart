import 'package:travel_core/travel_core.dart';
import 'import_service.dart';
import 'payment_identity.dart';
import 'matching_helpers.dart';
import 'hotel_check.dart';

bool groupDiscountExplains(Map<String, dynamic> group) {
  final payments =
      (group['payments'] as List? ?? []).cast<Map<String, dynamic>>();
  final discount = payments.fold<int>(0, (s, p) => s + paymentDiscountCents(p));
  return discount > 0 &&
      group['invoiceCents'] is int &&
      group['invoiceCents'] -
              payments.fold<int>(0,
                  (s, p) => s + (p['cents'] is int ? p['cents'] as int : 0)) ==
          discount;
}

class GroupStatus {
  final Map<String, dynamic> group;
  final List<String> problems = [];
  final int tolerance;
  GroupStatus(this.group, this.tolerance);
  bool get ready => problems.isEmpty;
  Reconciliation get reconciliation => Reconciliation(
      invoiceCents: group['invoiceCents'] is int ? group['invoiceCents'] : 0,
      allocatedNetPaymentCents: (group['payments'] as List? ?? []).fold<int>(
          0, (sum, p) => sum + (p['cents'] is int ? p['cents'] as int : 0)),
      toleranceCents: tolerance,
      confirmed: group['confirmed'] == true,
      evidenceComplete: ready);
}

List<GroupStatus> assessGroups(
    List<Map<String, dynamic>> groups, int tolerance) {
  final result = [for (final g in groups) GroupStatus(g, tolerance)];
  final owners = <String, Set<int>>{}, itineraryOwners = <String, Set<int>>{};
  final paymentIdentities = MaterialIdentityIndex(),
      paymentGroups = <Map<String, dynamic>, int>{};
  for (var i = 0; i < groups.length; i++) {
    final g = groups[i], status = result[i];
    final payments = g['payments'] as List? ?? [];
    final invoicePath = g['path'] as String?;
    if ((invoicePath == null || invoicePath.isEmpty) &&
        g['paperTaxi'] != true) {
      status.problems.add('缺少发票文件');
    }
    if (g['invoiceCents'] is! int || g['invoiceCents'] < 0) {
      status.problems.add('发票金额无效');
    }
    if (tolerance < 0) status.problems.add('金额容差无效');
    if (!['intercity', 'hotel', 'local'].contains(g['category'])) {
      status.problems.add('费用类别未选择');
    }
    if (payments.isEmpty) status.problems.add('尚未匹配支付截图');
    if (g['category'] == 'hotel' && payments.isNotEmpty) {
      final hotel = HotelCheck(g);
      if (!hotel.resolved) status.problems.add(hotel.status);
    }
    if (g['suggestionComplete'] == false) status.problems.add('仍有费用或行程未匹配');
    final local = <String>{};
    for (final p in payments) {
      final path = p['path'] as String?;
      if (path == null ||
          path.isEmpty ||
          p['cents'] is! int ||
          p['cents'] < 0) {
        status.problems.add('支付文件或净额无效');
        continue;
      }
      final keys = materialIdentities(Map<String, dynamic>.from(p));
      final record = Map<String, dynamic>.from(p),
          prior = paymentIdentities.find(Map<String, dynamic>.from(p));
      if (prior != null) {
        final other = paymentGroups[prior]!;
        final message = other == i ? '同一支付在本组重复使用' : '支付截图被其他发票重复使用';
        if (!status.problems.contains(message)) status.problems.add(message);
        if (!result[other].problems.contains(message)) {
          result[other].problems.add(message);
        }
      } else {
        paymentIdentities.add(record);
        paymentGroups[record] = i;
      }
      if (keys.any(local.contains)) status.problems.add('同一支付在本组重复使用');
      local.addAll(keys);
      for (final key in keys) {
        owners.putIfAbsent(key, () => <int>{}).add(i);
      }
    }
    if (g['paperTaxi'] == true) {
      if (payments.length != 1) status.problems.add('每张出租车票需要且只能对应一笔支付');
      continue;
    }
    if (g['category'] != 'local') continue;
    final paths = (g['itineraries'] as List? ?? []).cast<String>();
    if (paths.isEmpty) {
      status.problems.add('缺少市内交通行程单');
      continue;
    }
    for (final path in paths) {
      itineraryOwners.putIfAbsent(materialPathKey(path), () => <int>{}).add(i);
    }
    final trips = g['trips'] as List? ?? [];
    if (trips.isEmpty) {
      // 旧版本已人工完整核对的手工记录仍可使用；新记录应先识别逐条行程。
      if (!(g['manuallyEntered'] == true &&
          g['confirmed'] == true &&
          g['complete'] == true)) {
        status.problems.add('缺少逐条行程，请选择或重新识别行程单');
      }
      continue;
    }
    final indices = trips.map((t) => t['index']).toSet();
    if (indices.length != trips.length ||
        indices.any((n) => n is! int || n < 1) ||
        trips.any((t) => t['cents'] is! int || t['cents'] < 0)) {
      status.problems.add('行程序号或金额无效');
      continue;
    }
    final metadata = (g['itineraryMaterials'] as List? ?? [])
        .where(
            (m) => materialPathKey(m['path']) == materialPathKey(paths.first))
        .toList();
    if (metadata.isNotEmpty) {
      final d = metadata.first['document'];
      final rows = d?['trips'] as List? ?? [];
      final sum = trips.fold<int>(0, (s, t) => s + (t['cents'] as int));
      if (d?['complete'] != true ||
          rows.length != trips.length ||
          sum != d?['totalCents'] ||
          (d?['expectedCount'] is int && d['expectedCount'] != trips.length) ||
          trips.any((t) => !rows.any((r) => ['index', 'date', 'time', 'cents']
              .every((key) => t[key] == r[key])))) {
        status.problems.add('行程单条数、合计或缓存明细不完整，请重新识别');
      }
    } else if (g['suggestionComplete'] != true ||
        trips.fold<int>(0, (s, t) => s + (t['cents'] as int)) !=
            g['invoiceCents']) {
      status.problems.add('缺少完整行程识别依据，请重新识别行程单');
    }
    if (payments.length != trips.length ||
        indices.any((index) =>
            payments.where((p) => p['tripIndex'] == index).length != 1) ||
        payments.any((p) => !indices.contains(p['tripIndex']))) {
      status.problems.add('每条行程需要且只能对应一笔支付');
    }
    if (g['manuallyAssociated'] != true &&
        g['manuallyEntered'] != true &&
        g['confirmed'] != true) {
      final policy = g['matchingPolicy'];
      if (policy is! Map || ![2, 4].contains(policy['version'])) {
        status.problems.add('自动关联需按恢复后的日期时间规则重新匹配，请使用“时间匹配／重算”');
      } else {
        final settings = TimeMatchSettings.fromJson(
            (policy['timeMatching'] as Map?)?.cast<String, dynamic>());
        for (final trip in trips) {
          final assigned =
              payments.where((p) => p['tripIndex'] == trip['index']);
          if (assigned.length == 1 &&
              assigned.single['cents'] is int &&
              !assessPaymentTiming(
                      tripCharge(Map<String, dynamic>.from(trip),
                          '${trip['index']}', g['document']?['platform']),
                      paymentEvidence(
                          Map<String, dynamic>.from(assigned.single)),
                      settings: settings)
                  .eligible) {
            status.problems.add('行程 ${trip['index']} 的支付日期时间不符合匹配范围，请核对或人工指定');
          }
        }
      }
    }
  }
  for (final indices in owners.values.where((s) => s.length > 1)) {
    for (final index in indices) {
      if (!result[index].problems.contains('支付截图被其他发票重复使用')) {
        result[index].problems.add('支付截图被其他发票重复使用');
      }
    }
  }
  for (final indices in itineraryOwners.values.where((s) => s.length > 1)) {
    for (final index in indices) {
      result[index].problems.add('行程单被其他发票重复使用');
    }
  }
  return result;
}
