import 'package:flutter_test/flutter_test.dart';
import 'package:travel_core/travel_core.dart';

void main() {
  test('new and missing settings default to symmetric 150 minute windows', () {
    expect(const TimeMatchSettings().toJson(),
        {'rideToleranceMinutes': 150, 'paymentDelayMinutes': 150});
    expect(TimeMatchSettings.fromJson(null).toJson(),
        const TimeMatchSettings().toJson());
    expect(
        TimeMatchSettings.fromJson(
                {'rideToleranceMinutes': 20, 'paymentDelayMinutes': 60})
            .paymentDelayMinutes,
        60);
    final start = DateTime.utc(2026, 11, 1, 1);
    final charge = ChargeToMatch(
        id: 'c', category: 'local', cents: 1000, startedAt: start);
    for (final ride in [true, false]) {
      for (final sign in [-1, 1]) {
        PaymentEvidence payment(int seconds) => PaymentEvidence(
            id: 'p',
            category: 'local',
            cents: 1000,
            rideAt: ride ? start.add(Duration(seconds: sign * seconds)) : null,
            paidAt: ride ? null : start.add(Duration(seconds: sign * seconds)));
        expect(suggestPayments([charge], [payment(150 * 60)])['c']!.selected,
            isNotNull);
        expect(
            suggestPayments([charge], [payment(150 * 60 + 1)])['c']!.selected,
            isNull);
      }
    }
  });
}
