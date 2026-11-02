import 'package:travel_core/travel_core.dart';

TimeMatchSettings timeSettingsOf(Map<String, dynamic> task) =>
    TimeMatchSettings.fromJson(task['timeMatching'] as Map<String, dynamic>?);

DateTime? paymentTime(Map<String, dynamic> material, String field) =>
    beijingTimestamp(
        (material['timeOverrides'] as Map?)?.containsKey(field) == true
            ? material['timeOverrides'][field]
            : material['ocr']?[field]);

/// 保留 OCR 原文，仅保存对照原图后的字段修正；金额及关联不在此处修改。
Map<String, dynamic> withPaymentTimes(
    Map<String, dynamic> material, Map<String, dynamic>? values) {
  final result = {...material};
  if (values == null) {
    result.remove('timeOverrides');
    result.remove('timeCorrectionSource');
    return result;
  }
  for (final field in ['rideDateTime', 'paymentDateTime']) {
    if (!values.containsKey(field) ||
        (values[field] != null && beijingTimestamp(values[field]) == null)) {
      throw FormatException('时间格式无效，请填写 YYYY-MM-DD HH:mm:ss');
    }
  }
  result['timeOverrides'] = {
    for (final field in ['rideDateTime', 'paymentDateTime'])
      field: values[field]
  };
  result['timeCorrectionSource'] = '对照原图纠正';
  return result;
}

PaymentEvidence paymentEvidence(Map<String, dynamic> m) => PaymentEvidence(
    id: m['hash'] ?? m['path'],
    category: m['ocr']?['category'] ?? 'unknown',
    platform: m['ocr']?['platform'],
    discountCents: paymentDiscountCents(m),
    cents: m['manualPaymentCents'] ??
        m['cents'] ??
        m['ocr']['paymentCandidate']['cents'],
    date: DateTime.tryParse(m['ocr']?['paymentDate'] ?? ''),
    rideAt: paymentTime(m, 'rideDateTime'),
    paidAt: paymentTime(m, 'paymentDateTime'));

int paymentDiscountCents(Map<String, dynamic> m) {
  final value = m['ocr']?['discountCandidate']?['cents'];
  return value is int && value > 0 ? value : 0;
}

ChargeToMatch tripCharge(
        Map<String, dynamic> trip, String id, String? platform) =>
    ChargeToMatch(
        id: id,
        category: 'local',
        platform: platform,
        cents: trip['cents'],
        date: DateTime.tryParse(trip['date'] ?? ''),
        startedAt: beijingTimestamp('${trip['date']}T${trip['time']}'),
        requireSameDate: true);

void linkManualTrips(Map<String, dynamic> group, TimeMatchSettings settings) {
  final trips = (group['trips'] as List? ?? []).cast<Map<String, dynamic>>();
  final payments = (group['payments'] as List).cast<Map<String, dynamic>>();
  if (trips.isEmpty) {
    group['suggestionComplete'] = false;
    return;
  }
  final suggestions = suggestPayments([
    for (final t in trips)
      tripCharge(t, t['index'].toString(), group['document']?['platform'])
  ], payments.map(paymentEvidence).toList(),
      toleranceCents: group['matchingToleranceCents'] ?? 100,
      timeSettings: settings);
  final indices = {
    for (final t in trips)
      if (suggestions[t['index'].toString()]!.selected != null)
        suggestions[t['index'].toString()]!.selected!.id: t['index']
  };
  for (final p in payments) {
    p['tripIndex'] = indices[p['hash'] ?? p['path']];
  }
  group['suggestionComplete'] =
      payments.length == trips.length && indices.length == trips.length;
}
