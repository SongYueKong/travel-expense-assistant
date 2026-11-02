import 'trip_dates.dart';

Map<String, dynamic> newTaxiRecord(int cents, DateTime? date) {
  if (cents <= 0) throw const FormatException('出租车票金额必须大于零');
  return {
    'hash': 'taxi-${DateTime.now().microsecondsSinceEpoch}',
    'paperTaxi': true,
    'name': '出租车纸票${date == null ? '' : ' · ${tripDate(date)}'}',
    'category': 'local',
    'invoiceCents': cents,
    'document': {
      'type': 'invoice',
      'category': 'local',
      'totalCents': cents,
      if (date != null) 'expenseDate': tripDate(date),
    },
    'payments': <Map<String, dynamic>>[],
    'itineraries': <String>[],
    'trips': <Map<String, dynamic>>[],
    'suggestionComplete': false,
    'confirmed': false,
    'complete': false,
  };
}
