import 'dart:convert';
import 'package:travel_core/travel_core.dart';
import 'import_service.dart';
import 'pdf_catalog.dart';
import 'matching_helpers.dart';
import 'payment_identity.dart';
import 'pending_service.dart' show cleanPending;

typedef MaterialRecord = Map<String, dynamic>;

String evidenceKey(MaterialRecord m) =>
    m['hash'] as String? ?? materialPathKey(m['path'] as String);

List<MaterialRecord> records(dynamic values) =>
    (values as List? ?? []).cast<MaterialRecord>();

bool isPayment(MaterialRecord m) =>
    RegExp(r'\.(png|jpe?g)$', caseSensitive: false)
        .hasMatch(m['path'] as String? ?? '');

/// 编辑草稿与任务隔离；占用检查同时用于界面和保存，避免重复计入。
class AssociationEditor {
  final MaterialRecord task;
  final int groupIndex;
  final Map<String, MaterialRecord> payments = {};
  final Map<String, MaterialRecord> itineraries = {};
  final Map<String, String> owners = {};
  final Map<String, String> itineraryOwners = {};
  final List<String?> selected = [];
  final List<int?> amounts = [];
  String? itinerary;

  AssociationEditor(MaterialRecord source, this.groupIndex)
      : task = jsonDecode(jsonEncode(source)) as MaterialRecord {
    task['pdfMaterials'] = pdfCatalogMaterials(task);
    final ignored = MaterialIdentityIndex(records(task['ignoredMaterials']));
    for (final m in [
      ...records(task['pdfMaterials']),
      ...records(task['unmatchedMaterials']),
      ...records(task['unmatchedPayments']),
      for (final g in groups) ...records(g['payments']),
      for (final g in groups) ...records(g['itineraryMaterials']),
    ]) {
      if (ignored.find(m) != null) continue;
      if (isPayment(m)) payments[evidenceKey(m)] = m;
      if (m['document']?['type'] == 'itinerary') {
        itineraries[materialPathKey(m['path'])] = m;
      }
    }
    for (var i = 0; i < groups.length; i++) {
      final g = groups[i];
      final owner = '${invoiceNumber(i + 1)} ${g['name']}';
      for (final p in records(g['payments'])) {
        if (i != groupIndex) owners[evidenceKey(p)] = owner;
      }
      for (final path in (g['itineraries'] as List? ?? [])) {
        final key = materialPathKey(path);
        itineraries.putIfAbsent(
            key,
            () => {
                  'path': path,
                  'name':
                      '${g['name']} · 配套行程单（${records(g['trips']).length} 笔行程）',
                  'document': {
                    'type': 'itinerary',
                    'platform': g['document']?['platform'],
                    'totalCents': g['invoiceCents'],
                    'complete': records(g['trips']).isNotEmpty,
                    'trips': g['trips'] ?? [],
                  }
                });
        if (i != groupIndex) itineraryOwners[key] = owner;
      }
    }
    final paths = group['itineraries'] as List? ?? [];
    itinerary = paths.isEmpty ? null : materialPathKey(paths.first);
    _resetSlots(preserve: true);
  }

  List<MaterialRecord> get groups => records(task['groups']);
  MaterialRecord get group => groups[groupIndex];
  List<MaterialRecord> get trips => records(group['trips']);
  bool get byTrip => group['category'] == 'local' && trips.isNotEmpty;
  int get tolerance => task['toleranceCents'] as int;

  void _resetSlots({bool preserve = false}) {
    selected.clear();
    amounts.clear();
    final current = preserve ? records(group['payments']) : <MaterialRecord>[];
    final count =
        byTrip ? trips.length : (current.isEmpty ? 1 : current.length);
    for (var i = 0; i < count; i++) {
      final matches = byTrip
          ? current.where((p) => p['tripIndex'] == trips[i]['index']).toList()
          : (i < current.length ? [current[i]] : <MaterialRecord>[]);
      final p = matches.length == 1 ? matches.single : null;
      selected.add(p == null ? null : evidenceKey(p));
      amounts.add(p?['cents'] as int?);
    }
  }

  void selectItinerary(String? key) {
    if (key != null && itineraryOwners.containsKey(key)) {
      throw StateError('行程单已被 ${itineraryOwners[key]} 使用，请先解除原关联');
    }
    if (key == itinerary) return;
    itinerary = key;
    final m = key == null ? null : itineraries[key];
    group['itineraries'] = m == null ? <String>[] : [m['path']];
    group['itineraryMaterials'] = m == null ? <MaterialRecord>[] : [m];
    group['trips'] = m?['document']?['trips'] ?? <dynamic>[];
    _resetSlots();
  }

  bool itineraryRecommended(String key) {
    final d = itineraries[key]!['document'];
    return d['complete'] == true &&
        d['platform'] == group['document']?['platform'] &&
        d['totalCents'] == group['invoiceCents'];
  }

  /// 重新识别仅更新编辑草稿；按原行程签名保留选择，不能把旧支付挪给新增行程。
  void refreshItinerary(MaterialRecord document, {String? text}) {
    final key = itinerary;
    if (key == null || !itineraries.containsKey(key)) {
      throw StateError('请先选择行程单');
    }
    final fresh = jsonDecode(jsonEncode(document)) as MaterialRecord;
    final rows = records(fresh['trips']);
    final expected = fresh['expectedCount'];
    final valid = fresh['type'] == 'itinerary' &&
        fresh['complete'] == true &&
        expected is int &&
        expected > 0 &&
        rows.length == expected &&
        List.generate(expected, (i) => i + 1)
            .every((index) => rows[index - 1]['index'] == index) &&
        rows.every((t) =>
            t['cents'] is int &&
            t['cents'] >= 0 &&
            t['date'] != null &&
            t['time'] != null) &&
        rows.fold<int>(0, (sum, t) => sum + (t['cents'] as int)) ==
            fresh['totalCents'];
    if (!valid) {
      throw StateError(
          '原件标注 ${expected ?? '未知'} 笔，本次识别 ${rows.length} 笔，条数或合计尚未校验通过，保留原有选择');
    }
    final previous = <MaterialRecord>[];
    if (byTrip) {
      for (var i = 0; i < trips.length; i++) {
        if (selected[i] != null) {
          previous.add(
              {'trip': trips[i], 'payment': selected[i], 'amount': amounts[i]});
        }
      }
    }
    final updated = <String, dynamic>{
      ...itineraries[key]!,
      'document': fresh,
      if (text != null) 'text': text
    };
    itineraries[key] = updated;
    group['trips'] = rows;
    group['itineraryMaterials'] = [
      ...records(group['itineraryMaterials'])
          .where((m) => materialPathKey(m['path']) != key),
      updated,
    ];
    selected.clear();
    amounts.clear();
    final retained = <String>{};
    for (final row in rows) {
      final matches = previous
          .where((old) => ['index', 'date', 'time', 'cents']
              .every((field) => old['trip'][field] == row[field]))
          .toList();
      final old = matches.length == 1 ? matches.single : null;
      final payment = old?['payment'] as String?;
      final keep = payment != null &&
          payments.containsKey(payment) &&
          retained.add(payment);
      selected.add(keep ? payment : null);
      amounts.add(keep ? old!['amount'] as int? : null);
    }
    task['pdfMaterials'] = [
      for (final m in records(task['pdfMaterials']))
        if (materialPathKey(m['path']) == key)
          {...m, 'document': fresh, if (text != null) 'text': text}
        else
          m
    ];
  }

  ChargeToMatch charge(int slot) {
    final d = group['document'];
    final trip = byTrip ? trips[slot] : null;
    return ChargeToMatch(
        paperTaxi: group['paperTaxi'] == true,
        id: '$groupIndex/$slot',
        category: group['category'],
        platform: d?['platform'],
        cents: trip?['cents'] ?? group['invoiceCents'],
        date: DateTime.tryParse(
            trip?['date'] ?? d?['expenseDate'] ?? d?['issueDate'] ?? ''),
        startedAt: trip == null
            ? null
            : beijingTimestamp('${trip['date']}T${trip['time']}'),
        requireSameDate: byTrip);
  }

  int? recognizedAmount(String key) =>
      payments[key]!['manualPaymentCents'] as int? ??
      payments[key]!['cents'] as int? ??
      payments[key]!['ocr']?['paymentCandidate']?['cents'] as int?;

  int? candidateTimeDifferenceSeconds(String key, int slot) {
    final c = charge(slot), m = payments[key]!;
    if (c.category == 'local' && !c.paperTaxi) {
      final time =
          paymentTime(m, 'rideDateTime') ?? paymentTime(m, 'paymentDateTime');
      return c.startedAt == null || time == null
          ? null
          : time.difference(c.startedAt!).inSeconds.abs();
    }
    // 城际交通、住宿只有日期依据时比较自然日，不把缺失的时分当成午夜精确时间。
    final paid = paymentTime(m, 'paymentDateTime')
        ?.toUtc()
        .add(const Duration(hours: 8));
    final date = paid ?? DateTime.tryParse(m['ocr']?['paymentDate'] ?? '');
    if (c.date == null || date == null) return null;
    return DateTime.utc(date.year, date.month, date.day)
        .difference(DateTime.utc(c.date!.year, c.date!.month, c.date!.day))
        .inSeconds
        .abs();
  }

  /// 金额差绝对值优先，时间差绝对值其次；未知值靠后，完全相同时以文件名和标识稳定排序。
  List<String> sortedCandidates(int slot, Iterable<String> candidates) {
    final keys = candidates.toList(), c = charge(slot);
    final differences = {
      for (final key in keys)
        key: (
          recognizedAmount(key) == null
              ? null
              : paymentAmountGap(
                  c,
                  paymentEvidence(
                      {...payments[key]!, 'cents': recognizedAmount(key)!})),
          candidateTimeDifferenceSeconds(key, slot)
        )
    };
    int compare(int? a, int? b) =>
        a == null ? (b == null ? 0 : 1) : (b == null ? -1 : a.compareTo(b));
    keys.sort((a, b) {
      final amounts = compare(differences[a]!.$1, differences[b]!.$1);
      if (amounts != 0) return amounts;
      final times = compare(differences[a]!.$2, differences[b]!.$2);
      if (times != 0) return times;
      final names = (payments[a]!['name'] ?? a)
          .toString()
          .compareTo((payments[b]!['name'] ?? b).toString());
      return names != 0 ? names : a.compareTo(b);
    });
    return keys;
  }

  void correctPaymentTimes(String key, Map<String, dynamic>? values) {
    if (!payments.containsKey(key)) throw StateError('支付凭证不存在');
    payments[key] = withPaymentTimes(payments[key]!, values);
  }

  bool recommended(String key, int slot) {
    final m = payments[key]!, c = charge(slot);
    final cents = recognizedAmount(key);
    if (cents == null) return false;
    final evidence = paymentEvidence({...m, 'cents': cents});
    return suggestPayments([c], [evidence],
                toleranceCents: tolerance,
                timeSettings: timeSettingsOf(task))[c.id]!
            .selected !=
        null;
  }

  String? occupied(String key, int slot) {
    if (owners.containsKey(key)) return '已被 ${owners[key]} 使用';
    final identity = MaterialIdentityIndex([payments[key]!]);
    for (var i = 0; i < groups.length; i++) {
      if (i == groupIndex) continue;
      if (records(groups[i]['payments']).any((p) => identity.find(p) != null)) {
        return '已被 ${invoiceNumber(i + 1)} ${groups[i]['name']} 使用';
      }
    }
    for (var i = 0; i < selected.length; i++) {
      if (i != slot &&
          selected[i] != null &&
          identity.find(payments[selected[i]]!) != null) {
        return '已用于本组第 ${i + 1} 项';
      }
    }
    return null;
  }

  void choose(int slot, String? key) {
    if (key != null) {
      if (!payments.containsKey(key)) throw StateError('支付凭证不存在');
      final owner = occupied(key, slot);
      if (owner != null) throw StateError('$owner，请先解除原关联');
    }
    selected[slot] = key;
    amounts[slot] = key == null ? null : recognizedAmount(key);
  }

  void addSlot() {
    if (group['paperTaxi'] == true) throw StateError('每张出租车票对应一笔支付');
    if (byTrip) throw StateError('市内交通按行程单逐条选择');
    selected.add(null);
    amounts.add(null);
  }

  bool get selectionComplete =>
      selected.isNotEmpty &&
      selected.every((key) => key != null) &&
      (group['paperTaxi'] == true ||
          group['category'] != 'local' ||
          ((group['itineraries'] as List? ?? []).isNotEmpty &&
              ((byTrip &&
                      itineraries[itinerary]?['document']?['complete'] ==
                          true) ||
                  (!byTrip && group['manuallyEntered'] == true))));

  MaterialRecord build() {
    final assigned = <MaterialRecord>[];
    final seen = <String>{};
    for (var i = 0; i < selected.length; i++) {
      final key = selected[i];
      if (key == null) continue;
      if (!seen.add(key) || occupied(key, i) != null) {
        throw StateError('同一支付凭证不能重复分配，请先解除原关联');
      }
      if (amounts[i] == null || amounts[i]! <= 0) {
        throw StateError('请填写第 ${i + 1} 项的实际支付净额，金额必须大于零');
      }
      assigned.add({
        ...payments[key]!,
        'cents': amounts[i],
        'manualPaymentCents': amounts[i],
        'tripIndex': byTrip ? trips[i]['index'] : null,
        'matchingReason': '人工指定关联',
      });
    }
    group['payments'] = assigned;
    group['manuallyAssociated'] = true;
    group['confirmed'] = false;
    group['complete'] = false;
    group['suggestionComplete'] = selectionComplete;
    group['matchingReasons'] = [
      selectionComplete ? '人工关联已保存，匹配完整后可直接导出，复核可选' : '人工调整已暂存，尚有材料未选择',
    ];
    _refreshUnmatched(task, payments.values, itineraries.values);
    return cleanPending(task);
  }
}

void _refreshUnmatched(MaterialRecord task, Iterable<MaterialRecord> pool,
    Iterable<MaterialRecord> itineraryPool) {
  final groups = records(task['groups']);
  final used = {
    for (final g in groups)
      for (final p in records(g['payments'])) evidenceKey(p)
  };
  final usedPaths = {
    for (final g in groups)
      for (final path in (g['itineraries'] as List? ?? []))
        materialPathKey(path)
  };
  task['unmatchedPayments'] =
      pool.where((p) => !used.contains(evidenceKey(p))).toList();
  final other = records(task['unmatchedMaterials'])
      .where((m) => !isPayment(m) && m['document']?['type'] != 'itinerary');
  task['unmatchedMaterials'] = [
    ...other,
    ...itineraryPool
        .where((m) => !usedPaths.contains(materialPathKey(m['path']))),
  ];
}

/// 移除费用组时释放凭证，供其他组重新选择；原始文件保持不变。
MaterialRecord removeAssociationGroup(MaterialRecord source, int index) {
  final editor = AssociationEditor(source, index);
  (editor.task['groups'] as List).removeAt(index);
  _refreshUnmatched(
      editor.task, editor.payments.values, editor.itineraries.values);
  return editor.task;
}
