import '../lib/travel_core.dart';

void check(bool ok, String description) {
  if (!ok) throw StateError(description);
}

void main() {
  check(parseMoney('46.06') == 4606, '金额按分解析');
  check(parseMoney('1,200.1') == 120010, '千分位与小数');
  for (final invalid in ['-1', '1.001', '', 'abc', '1,00', '1,,000']) {
    var rejected = false;
    try {
      parseMoney(invalid);
    } on FormatException {
      rejected = true;
    }
    check(rejected, '拒绝无效金额 $invalid');
  }
  const a = Reconciliation(
    invoiceCents: 30000,
    allocatedNetPaymentCents: 29980,
    confirmed: true,
    evidenceComplete: true,
  );
  const b = Reconciliation(
    invoiceCents: 50000,
    allocatedNetPaymentCents: 50020,
    confirmed: true,
    evidenceComplete: true,
  );
  check(reimbursementTotal([a, b]) == 79980, '逐组取小再累加，不能先汇总抵消');
  const boundary = Reconciliation(
    invoiceCents: 10000,
    allocatedNetPaymentCents: 9900,
  );
  check(boundary.withinTolerance, '1元边界包含');
  check(
    !const Reconciliation(
      invoiceCents: 10000,
      allocatedNetPaymentCents: 9899,
    ).withinTolerance,
    '超过1元需要人工处理',
  );
  check(
    const Reconciliation(
          invoiceCents: 12000,
          allocatedNetPaymentCents: 7000,
          confirmed: true,
        ).reimbursementCents ==
        null,
    '缺失证据不能取部分金额结算',
  );
  check(
    const Reconciliation(
          invoiceCents: 12000,
          allocatedNetPaymentCents: 11980,
          confirmed: true,
          evidenceComplete: true,
        ).reimbursementCents ==
        11980,
    '一票多笔汇总取小',
  );
  validateAllocations(10000, [6000, 4000]);
  var overflow = false;
  try {
    validateAllocations(10000, [6000, 5000]);
  } on StateError {
    overflow = true;
  }
  check(overflow, '支付超额分配被拒绝');
  check(paymentNumber(4, 2, 3) == '004-02', '多支付子号');
  final day = DateTime(2026, 10, 27);
  final start = beijingTimestamp('2026-10-27T10:00');
  final charge = ChargeToMatch(
    id: 'trip1',
    category: 'local',
    platform: 'didi',
    date: day,
    startedAt: start,
    cents: 4650,
    requireSameDate: true,
  );
  final paid = PaymentEvidence(
    id: 'pay1',
    category: 'local',
    platform: 'didi',
    date: day,
    rideAt: start,
    cents: 4550,
  );
  check(
    suggestPayments([charge], [paid])['trip1']!.selected?.id == 'pay1',
    '1元内按日期平台匹配',
  );
  final duplicate = PaymentEvidence(
    id: 'pay2',
    category: 'local',
    platform: 'didi',
    date: day,
    rideAt: start,
    cents: 4650,
  );
  check(
    suggestPayments([charge], [paid, duplicate])['trip1']!.selected?.id ==
        'pay2',
    '金额差更小的候选优先',
  );
  final another = ChargeToMatch(
    id: 'trip2',
    startedAt: start,
    category: 'local',
    platform: 'didi',
    date: day,
    cents: 4650,
    requireSameDate: true,
  );
  final competing = suggestPayments([charge, another], [paid]);
  check(competing.values.every((s) => s.selected == null), '同一支付被多条行程争用时全部待处理');
  final wrongDay = PaymentEvidence(
    id: 'other-day',
    category: 'local',
    platform: 'didi',
    date: DateTime(2026, 10, 28),
    cents: 4650,
  );
  check(
    suggestPayments([charge], [wrongDay])['trip1']!.selected == null,
    '不同日期不能自动匹配',
  );
  print('PASS: 金额、容差边界、取小值、缺证据、分配和编号规则');
}
