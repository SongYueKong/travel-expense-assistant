import 'task_rules.dart';

String tripDate(DateTime value) =>
    '${value.year.toString().padLeft(4, '0')}-${value.month.toString().padLeft(2, '0')}-${value.day.toString().padLeft(2, '0')}';

/// 日期采用自然日，不随电脑时区或夏令时变化。
class TripPeriod {
  final DateTime start, end;
  TripPeriod(DateTime start, DateTime end)
      : start = DateTime.utc(start.year, start.month, start.day),
        end = DateTime.utc(end.year, end.month, end.day) {
    if (this.end.isBefore(this.start)) {
      throw const FormatException('结束日期不能早于开始日期');
    }
    if (this.start.year < 2000 || this.end.year > 2100) {
      throw const FormatException('出差日期请选择 2000—2100 年');
    }
  }
  factory TripPeriod.today([DateTime? now]) {
    final today = (now ?? DateTime.now()).toUtc().add(const Duration(hours: 8));
    return TripPeriod(today, today);
  }
  static TripPeriod? fromTask(Map<String, dynamic> task) {
    DateTime? parse(dynamic value) {
      if (value is! String || !RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(value)) {
        return null;
      }
      final date = DateTime.tryParse(value);
      return date != null && tripDate(date) == value ? date : null;
    }

    final start = parse(task['tripStartDate']),
        end = parse(task['tripEndDate']);
    if (start == null || end == null) return null;
    try {
      return TripPeriod(start, end);
    } on FormatException {
      return null;
    }
  }

  String get label => '${tripDate(start)} 至 ${tripDate(end)}';
  int get days => end.difference(start).inDays + 1;
  String taskName(String base) => '${validateTaskName(base)}（$label）';
  DateTime get mailStart => DateTime(start.year, start.month, start.day);
  DateTime get mailEnd {
    final next = end.add(const Duration(days: 1));
    return DateTime(next.year, next.month, next.day);
  }

  Map<String, String> toJson() =>
      {'tripStartDate': tripDate(start), 'tripEndDate': tripDate(end)};
}
