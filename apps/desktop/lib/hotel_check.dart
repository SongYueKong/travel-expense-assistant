import 'dart:convert';

const hotelStatementImages = ['jpg', 'jpeg', 'png', 'bmp', 'webp'];
String hotelStatementKind(String path) {
  final extension = path.toLowerCase().split('.').last;
  return extension == 'pdf'
      ? 'pdf'
      : hotelStatementImages.contains(extension)
          ? 'image'
          : '';
}

String normalizeUnit(String value) => value
    .replaceAll(RegExp(r'\s+'), '')
    .replaceAll('（', '(')
    .replaceAll('）', ')')
    .toLowerCase();
String hotelPaymentKey(Map<String, dynamic> p) =>
    (p['hash'] ?? p['path']).toString();

class HotelCheck {
  final Map<String, dynamic> group;
  HotelCheck(this.group);
  Map<String, dynamic> get saved =>
      Map<String, dynamic>.from(group['hotelVerification'] as Map? ?? {});
  List<Map<String, dynamic>> get payments =>
      (group['payments'] as List? ?? []).cast<Map<String, dynamic>>();
  String get seller =>
      (saved['sellerName'] ?? group['document']?['sellerName'] ?? '')
          .toString()
          .trim();
  String payee(Map<String, dynamic> p) =>
      (saved['payees']?[hotelPaymentKey(p)] ?? p['ocr']?['payeeName'] ?? '')
          .toString()
          .trim();
  bool get known =>
      seller.isNotEmpty &&
      payments.isNotEmpty &&
      payments.every((p) => payee(p).isNotEmpty);
  bool get same =>
      known &&
      payments.every((p) => normalizeUnit(payee(p)) == normalizeUnit(seller));
  String get basis {
    final values = [
      for (final p in payments)
        '${hotelPaymentKey(p)}:${normalizeUnit(payee(p))}'
    ]..sort();
    return jsonEncode(
        [group['hash'] ?? group['path'], normalizeUnit(seller), values]);
  }

  Map<String, dynamic>? get proof =>
      saved['proof'] is Map ? Map<String, dynamic>.from(saved['proof']) : null;
  bool get hasFileProof =>
      proof?['material']?['path'] is String &&
      ['pdf', 'image'].contains(proof?['kind']) &&
      hotelStatementKind(proof!['material']['path']) == proof!['kind'];
  bool get resolved =>
      same ||
      (known &&
          proof?['basis'] == basis &&
          (proof?['kind'] == 'paper' || hasFileProof));
  String get status => !known
      ? '收款单位未识别完整，请核对购销方与收款方'
      : same
          ? '发票销售方与支付收款方一致'
          : resolved
              ? (proof!['kind'] == 'paper'
                  ? '单位不一致 · 已有纸质情况说明'
                  : '单位不一致 · 已附情况说明${proof!['kind'] == 'image' ? '图片' : ' PDF'}')
              : '单位不一致，请添加情况说明 PDF／图片或确认已有纸质证明';
}
