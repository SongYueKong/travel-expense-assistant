import 'package:flutter_test/flutter_test.dart';
import 'package:travel_core/travel_core.dart';

DateTime stamp(String time) => beijingTimestamp('2026-10-$time')!;
ChargeToMatch trip(String id, String time) => ChargeToMatch(
    id: id,
    category: 'local',
    platform: 'didi',
    cents: 4650,
    startedAt: stamp(time));
PaymentEvidence pay(String id,
        {String? ride, String? paid, int cents = 4650}) =>
    PaymentEvidence(
        id: id,
        category: 'local',
        platform: 'didi',
        cents: cents,
        rideAt: ride == null ? null : stamp(ride),
        paidAt: paid == null ? null : stamp(paid));
// 显式使用历史15/180窗口，验证用户仍可自定义边界，不依赖默认值。
Map<String, MatchSuggestion> suggestWithTestWindow(
        List<ChargeToMatch> charges, List<PaymentEvidence> payments,
        {int toleranceCents = 100,
        TimeMatchSettings timeSettings = const TimeMatchSettings(
            rideToleranceMinutes: 15, paymentDelayMinutes: 180)}) =>
    suggestPayments(charges, payments,
        toleranceCents: toleranceCents, timeSettings: timeSettings);
void main() {
  test('Beijing timestamps remain strict', () {
    expect(stamp('27T10:00'), DateTime.utc(2026, 10, 27, 2));
    expect(beijingTimestamp('2026-02-30T10:00'), isNull);
  });
  test(
      'unique amount is rejected outside time range or with missing contradictory time',
      () {
    final c = trip('t', '27T10:00');
    for (final p in [
      pay('a'),
      pay('a', ride: '01T10:00'),
      pay('a', paid: '28T12:00'),
      pay('a', ride: '27T15:00', paid: '27T14:00')
    ]) {
      expect(
          suggestWithTestWindow([c], [p],
                  timeSettings: const TimeMatchSettings(
                      rideToleranceMinutes: 0, paymentDelayMinutes: 0))['t']!
              .selected
              ?.id,
          null);
    }
  });
  test('amount difference takes priority over nearby time', () {
    final c = trip('t', '27T10:00');
    expect(
        suggestWithTestWindow([
          c
        ], [
          pay('exact', ride: '01T10:00'),
          pay('near', ride: '27T10:00', cents: 4600)
        ])['t']!
            .selected
            ?.id,
        'near');
    expect(
        suggestWithTestWindow([c], [pay('over', cents: 4549)])['t']!.selected,
        isNull);
  });
  test(
      'equal amount candidates use time including payment time across midnight',
      () {
    final c = trip('t', '27T23:50');
    expect(
        suggestWithTestWindow([
          c
        ], [
          pay('far', ride: '28T02:00'),
          pay('near', ride: '28T00:01')
        ])['t']!
            .selected
            ?.id,
        'near');
    expect(
        suggestWithTestWindow([
          c
        ], [
          pay('far', paid: '28T02:00'),
          pay('near', paid: '28T00:01')
        ])['t']!
            .selected
            ?.id,
        'near');
  });
  test('missing time stays manual but ride after payment uses ride distance',
      () {
    final c = trip('t', '27T10:00');
    expect(suggestWithTestWindow([c], [pay('a'), pay('b')])['t']!.selected,
        isNull);
    expect(
        suggestWithTestWindow([c],
                [pay('a', ride: '27T09:59'), pay('b', ride: '27T10:01')])['t']!
            .selected,
        isNull);
    expect(
        suggestWithTestWindow([
          c
        ], [
          pay('bad', ride: '27T10:00', paid: '27T09:00'),
          pay('valid', ride: '27T10:10')
        ])['t']!
            .selected
            ?.id,
        'bad');
  });
  test('competing expenses cannot claim same payment', () {
    expect(
        suggestWithTestWindow(
                [trip('t', '27T10:00'), trip('u', '27T10:00')], [pay('a')])
            .values
            .every((s) => s.selected == null),
        isTrue);
  });
  test(
      'hotel and intercity require dates and enforce same-date and fourteen-day boundaries',
      () {
    for (final category in ['hotel', 'intercity']) {
      final c = ChargeToMatch(
          id: 'c',
          category: category,
          cents: 10000,
          date: DateTime(2026, 10, 27),
          requireSameDate: true);
      PaymentEvidence p(String id, DateTime? date) =>
          PaymentEvidence(id: id, category: category, cents: 10000, date: date);
      final far = p('far', DateTime(2025, 1, 1));
      expect(suggestWithTestWindow([c], [far])['c']!.selected, isNull);
      expect(suggestWithTestWindow([c], [p('unknown', null)])['c']!.selected,
          isNull);
      expect(
          suggestWithTestWindow(
                  [c], [far, p('near', DateTime(2026, 10, 27))])['c']!
              .selected
              ?.id,
          'near');
      expect(
          suggestWithTestWindow([c], [p('a', null), p('b', null)])['c']!
              .selected,
          isNull);
    }
  });
  test(
      'ride and delayed payment boundaries are inclusive, adjustable and cross midnight',
      () {
    final c = trip('t', '27T23:50');
    for (final time in ['27T23:35:00', '28T00:05:00']) {
      expect(suggestWithTestWindow([c], [pay('a', ride: time)])['t']!.selected,
          isNotNull);
    }
    expect(
        suggestWithTestWindow([c], [pay('a', ride: '28T00:05:01')])['t']!
            .selected,
        isNull);
    expect(
        suggestWithTestWindow([c], [pay('a', ride: '28T00:05:01')],
                timeSettings:
                    const TimeMatchSettings(rideToleranceMinutes: 16))['t']!
            .selected,
        isNotNull);
    expect(
        suggestWithTestWindow([c], [pay('a', paid: '28T02:50:00')])['t']!
            .selected,
        isNotNull);
    expect(
        suggestWithTestWindow([c], [pay('a', paid: '28T02:50:01')])['t']!
            .selected,
        isNull);
    expect(
        suggestWithTestWindow([c], [pay('a', paid: '27T23:49:59')])['t']!
            .selected,
        isNotNull);
    final hotel = ChargeToMatch(
        id: 'h', category: 'hotel', cents: 100, date: DateTime(2026, 10, 1));
    PaymentEvidence payment(DateTime d) =>
        PaymentEvidence(id: 'p', category: 'hotel', cents: 100, date: d);
    expect(
        suggestWithTestWindow([hotel], [payment(DateTime(2026, 10, 15))])['h']!
            .selected,
        isNotNull);
    expect(
        suggestWithTestWindow([hotel], [payment(DateTime(2026, 10, 16))])['h']!
            .selected,
        isNull);
  });
  test(
      'symmetric payment window includes both boundaries and excludes one second beyond',
      () {
    final c = trip('t', '28T01:00');
    for (final time in ['27T22:00:00', '28T04:00:00']) {
      expect(suggestWithTestWindow([c], [pay('a', paid: time)])['t']!.selected,
          isNotNull);
    }
    for (final time in ['27T21:59:59', '28T04:00:01']) {
      expect(suggestWithTestWindow([c], [pay('a', paid: time)])['t']!.selected,
          isNull);
    }
    final reversed = pay('a', ride: '28T01:05:00', paid: '28T00:30:00');
    expect(suggestWithTestWindow([c], [reversed])['t']!.selected?.id, 'a');
    expect(paymentTimeDistance(c, reversed), 300);
    expect(
        suggestWithTestWindow([c], [pay('a', paid: '27T23:59:59')],
                timeSettings:
                    const TimeMatchSettings(paymentDelayMinutes: 60))['t']!
            .selected,
        isNull);
  });
}
