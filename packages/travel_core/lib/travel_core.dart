enum ExpenseCategory { intercity, hotel, local }

class PaymentEvidence {
  final String id, category;
  final String? platform;
  final DateTime? date;
  final DateTime? rideAt, paidAt;
  final int cents;
  final int discountCents;
  const PaymentEvidence({
    required this.id,
    required this.category,
    required this.cents,
    this.discountCents = 0,
    this.platform,
    this.date,
    this.rideAt,
    this.paidAt,
  });
}

class ChargeToMatch {
  final bool paperTaxi;
  final String id, category;
  final String? platform;
  final DateTime? date;
  final DateTime? startedAt;
  final int cents;
  final bool requireSameDate;
  const ChargeToMatch({
    required this.id,
    required this.category,
    required this.cents,
    this.platform,
    this.date,
    this.startedAt,
    this.requireSameDate = false,
    this.paperTaxi = false,
  });
}

class TimeMatchSettings {
  final int rideToleranceMinutes, paymentDelayMinutes;
  const TimeMatchSettings({
    this.rideToleranceMinutes = 150,
    this.paymentDelayMinutes = 150,
  });
  factory TimeMatchSettings.fromJson(Map<String, dynamic>? json) {
    final ride = json?['rideToleranceMinutes'] ?? 150;
    final payment = json?['paymentDelayMinutes'] ?? 150;
    if (ride is! int ||
        payment is! int ||
        ride < 0 ||
        ride > 1440 ||
        payment < 0 ||
        payment > 10080) {
      throw ArgumentError('时间范围无效：乘车时间需为 0–1440 分钟，支付时间需为 0–10080 分钟');
    }
    return TimeMatchSettings(
      rideToleranceMinutes: ride,
      paymentDelayMinutes: payment,
    );
  }
  Map<String, int> toJson() => {
        'rideToleranceMinutes': rideToleranceMinutes,
        'paymentDelayMinutes': paymentDelayMinutes,
      };
}

/// 票据与截图时间均按北京时间解释，避免电脑时区和夏令时改变时间差。
DateTime? beijingTimestamp(String? value) {
  if (value == null) return null;
  final m = RegExp(
    r'^(\d{4})-(\d{2})-(\d{2})[T ](\d{2}):(\d{2})(?::(\d{2}))?(?:\+08:00)?$',
  ).firstMatch(value.trim());
  if (m == null) return null;
  final parts = [for (var i = 1; i <= 6; i++) int.parse(m[i] ?? '0')];
  final time = DateTime.utc(
    parts[0],
    parts[1],
    parts[2],
    parts[3],
    parts[4],
    parts[5],
  );
  if ([
    time.year,
    time.month,
    time.day,
    time.hour,
    time.minute,
    time.second,
  ].indexed.any((p) => p.$2 != parts[p.$1])) return null;
  return time.subtract(const Duration(hours: 8));
}

String formatBeijingTimestamp(DateTime? value) {
  if (value == null) return '未识别';
  final t = value.toUtc().add(const Duration(hours: 8));
  String two(int n) => n.toString().padLeft(2, '0');
  return '${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
}

class PaymentTiming {
  final bool eligible;
  final int rank;
  final int? distanceSeconds;
  final String reason;
  const PaymentTiming(
    this.eligible,
    this.rank,
    this.distanceSeconds,
    this.reason,
  );
}

PaymentTiming assessPaymentTiming(
  ChargeToMatch charge,
  PaymentEvidence payment, {
  TimeMatchSettings settings = const TimeMatchSettings(),
}) {
  if (charge.paperTaxi) {
    if (charge.date == null)
      return const PaymentTiming(true, 0, null, '出租车未填日期，按金额匹配');
    if (payment.date == null)
      return const PaymentTiming(false, 0, null, '支付日期未识别，需人工选择');
    final seconds = paymentTimeDistance(charge, payment)!;
    return PaymentTiming(
        seconds == 0, 0, seconds, seconds == 0 ? '出租车日期一致' : '出租车日期不一致');
  }
  if (charge.category != 'local') {
    if (charge.date == null || payment.date == null)
      return const PaymentTiming(false, 0, null, '缺少费用或支付日期，需人工选择');
    final seconds = paymentTimeDistance(charge, payment)!;
    final eligible =
        charge.requireSameDate ? seconds == 0 : seconds <= 14 * 86400;
    return PaymentTiming(
        eligible, 0, seconds, eligible ? '日期在允许范围内' : '日期超出允许范围');
  }
  if (charge.startedAt == null)
    return const PaymentTiming(false, 0, null, '缺少行程时间，需人工选择');
  if (payment.rideAt != null) {
    final seconds =
        payment.rideAt!.difference(charge.startedAt!).inSeconds.abs();
    final eligible = seconds <= settings.rideToleranceMinutes * 60;
    return PaymentTiming(eligible, 2, seconds,
        '乘车时间相差 ${seconds ~/ 60} 分 ${seconds % 60} 秒${eligible ? '' : '，超过时间范围'}');
  }
  if (payment.paidAt != null) {
    final seconds =
        payment.paidAt!.difference(charge.startedAt!).inSeconds.abs();
    final eligible = seconds <= settings.paymentDelayMinutes * 60;
    return PaymentTiming(eligible, 1, seconds,
        '支付时间相差 ${seconds ~/ 60} 分 ${seconds % 60} 秒${eligible ? '' : '，超过时间范围'}');
  }
  return const PaymentTiming(false, 0, null, '未识别乘车或支付时间，需人工选择');
}

/// 候选排序使用的时间差；准入范围由 assessPaymentTiming 检查。
int? paymentTimeDistance(ChargeToMatch charge, PaymentEvidence payment) {
  if (charge.category == 'local' && !charge.paperTaxi) {
    if (charge.startedAt == null) return null;
    final value = payment.rideAt ?? payment.paidAt;
    return value?.difference(charge.startedAt!).inSeconds.abs();
  }
  if (charge.date == null || payment.date == null) return null;
  final a = charge.date!, b = payment.date!;
  return DateTime.utc(
    a.year,
    a.month,
    a.day,
  ).difference(DateTime.utc(b.year, b.month, b.day)).inSeconds.abs();
}

class MatchSuggestion {
  final List<PaymentEvidence> candidates;
  final PaymentEvidence? selected;
  final String reason;
  const MatchSuggestion(this.candidates, this.selected, this.reason);
}

bool discountExplains(ChargeToMatch charge, PaymentEvidence payment) =>
    payment.discountCents > 0 &&
    charge.cents - payment.cents == payment.discountCents;

int paymentAmountGap(ChargeToMatch charge, PaymentEvidence payment) =>
    discountExplains(charge, payment)
        ? 0
        : (charge.cents - payment.cents).abs();

/// 先评估全部候选再检查争用，不按文件顺序贪心占用同一支付。
Map<String, MatchSuggestion> suggestPayments(
  List<ChargeToMatch> charges,
  List<PaymentEvidence> payments, {
  int toleranceCents = 100,
  TimeMatchSettings timeSettings = const TimeMatchSettings(),
}) {
  if (toleranceCents < 0) throw ArgumentError('容差不能为负');
  if (payments.map((p) => p.id).toSet().length != payments.length ||
      charges.map((c) => c.id).toSet().length != charges.length) {
    throw ArgumentError('匹配对象标识重复');
  }
  final choices = <String, List<PaymentEvidence>>{};
  for (final charge in charges) {
    final options = payments.where((p) {
      if ((charge.paperTaxi
              ? !['local', 'unknown'].contains(p.category)
              : p.category != charge.category) ||
          paymentAmountGap(charge, p) > toleranceCents) return false;
      if (charge.platform != null && p.platform != charge.platform)
        return false;
      return assessPaymentTiming(charge, p, settings: timeSettings).eligible;
    }).toList();
    // 金额差优先；仅在金额差相同时比较可用时间，缺失或矛盾时间排后。
    int compare(PaymentEvidence a, PaymentEvidence b) {
      final amount = paymentAmountGap(charge, a).compareTo(
        paymentAmountGap(charge, b),
      );
      if (amount != 0) return amount;
      final x = paymentTimeDistance(charge, a),
          y = paymentTimeDistance(charge, b);
      if (x == null) return y == null ? 0 : 1;
      if (y == null) return -1;
      return x.compareTo(y);
    }

    options.sort(compare);
    if (options.isNotEmpty) {
      choices[charge.id] =
          options.where((p) => compare(p, options.first) == 0).toList();
      continue;
    }
    choices[charge.id] = options;
  }
  final claims = <String, int>{};
  for (final options in choices.values) {
    for (final p in options) {
      claims[p.id] = (claims[p.id] ?? 0) + 1;
    }
  }
  return {
    for (final charge in charges)
      charge.id: (() {
        final options = choices[charge.id]!;
        if (options.isEmpty)
          return MatchSuggestion(options, null, '没有同时满足类别、平台、日期时间和金额条件的支付');
        if (options.length != 1)
          return MatchSuggestion(options, null, '存在多笔候选，需要人工选择');
        if (claims[options.single.id] != 1)
          return MatchSuggestion(options, null, '同一支付被多个费用候选引用，需要人工分配');
        return MatchSuggestion(
          options,
          options.single,
          discountExplains(charge, options.single)
              ? '差额恰好等于截图优惠 ${formatMoney(options.single.discountCents)} 元；按实付金额核算'
              : charge.category == 'local'
                  ? '类别、平台及金额符合；${assessPaymentTiming(charge, options.single, settings: timeSettings).reason}'
                  : '类别、平台、日期及金额符合',
        );
      })(),
  };
}

/// 金额使用整数分。输入错误必须显式纠正，不能默认为零。
int parseMoney(String text) {
  final input = text.trim();
  if (!RegExp(r'^(?:\d+|\d{1,3}(?:,\d{3})+)(?:\.\d{1,2})?$').hasMatch(input)) {
    throw FormatException('请输入非负金额，最多两位小数');
  }
  final clean = input.replaceAll(',', '');
  final parts = clean.split('.');
  return int.parse(parts.first) * 100 +
      (parts.length == 1 ? 0 : int.parse(parts.last.padRight(2, '0')));
}

String formatMoney(int cents) =>
    '${cents < 0 ? '-' : ''}${cents.abs() ~/ 100}.${(cents.abs() % 100).toString().padLeft(2, '0')}';

class Reconciliation {
  final int invoiceCents;
  final int allocatedNetPaymentCents;
  final int toleranceCents;
  final bool confirmed;
  final bool evidenceComplete;
  const Reconciliation({
    required this.invoiceCents,
    required this.allocatedNetPaymentCents,
    this.toleranceCents = 100,
    this.confirmed = false,
    this.evidenceComplete = false,
  });

  int get difference => invoiceCents - allocatedNetPaymentCents;
  bool get withinTolerance => difference.abs() <= toleranceCents;
  bool get included =>
      evidenceComplete &&
      invoiceCents >= 0 &&
      allocatedNetPaymentCents >= 0 &&
      toleranceCents >= 0;
  int? get reimbursementCents => included
      ? (invoiceCents < allocatedNetPaymentCents
          ? invoiceCents
          : allocatedNetPaymentCents)
      : null;
}

int reimbursementTotal(Iterable<Reconciliation> groups) =>
    groups.fold(0, (total, group) => total + (group.reimbursementCents ?? 0));

/// 分配校验适用于一笔支付对应多张发票，防止同一金额被重复使用。
void validateAllocations(int availableNetCents, Iterable<int> amounts) {
  if (availableNetCents < 0 ||
      amounts.any((v) => v < 0) ||
      amounts.fold<int>(0, (sum, v) => sum + v) > availableNetCents) {
    throw StateError('支付分配金额无效或超过可用净额');
  }
}

String invoiceNumber(int index) {
  if (index < 1) throw RangeError('发票序号从 1 开始');
  return index.toString().padLeft(3, '0');
}

String paymentNumber(int invoiceIndex, int paymentIndex, int paymentCount) {
  if (paymentIndex < 1 || paymentIndex > paymentCount)
    throw RangeError('支付序号无效');
  final parent = invoiceNumber(invoiceIndex);
  return paymentCount == 1
      ? parent
      : '$parent-${paymentIndex.toString().padLeft(2, '0')}';
}
