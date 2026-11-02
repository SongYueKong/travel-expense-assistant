/// 本机通用的支付截图排版；不随差旅切换而改变。
class PaymentLayout {
  final String orientation;
  final int rows, columns;
  const PaymentLayout.defaults()
      : orientation = 'landscape',
        rows = 2,
        columns = 4;

  PaymentLayout(
      {required this.orientation, required this.rows, required this.columns}) {
    if (!['landscape', 'portrait'].contains(orientation) ||
        rows < 1 ||
        rows > 8 ||
        columns < 1 ||
        columns > 8) {
      throw const FormatException('请选择 A4 方向，行数和列数均须为 1～8');
    }
  }

  factory PaymentLayout.fromJson(Map<String, dynamic> value) {
    if (value['orientation'] is! String ||
        value['rows'] is! int ||
        value['columns'] is! int) {
      throw const FormatException('支付截图排版设置格式无效');
    }
    return PaymentLayout(
        orientation: value['orientation'],
        rows: value['rows'],
        columns: value['columns']);
  }

  bool get landscape => orientation == 'landscape';
  int get perPage => rows * columns;
  Map<String, dynamic> toJson() =>
      {'orientation': orientation, 'rows': rows, 'columns': columns};
}
