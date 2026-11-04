import 'invoice_bundle.dart';
import 'package:travel_core/travel_core.dart';
import 'reconciliation_service.dart';
import 'meal_allowance.dart';
import 'hotel_check.dart';
import 'trip_dates.dart';

String taskExportFilename(String name) {
  var label = name
      .trim()
      .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1f]'), '_')
      .replaceAll(RegExp(r'[. ]+$'), '');
  if (label.isEmpty) label = '差旅';
  label = String.fromCharCodes(label.runes.take(100));
  return '$label-报账材料.pdf';
}

Map<String, dynamic> buildTaskExportManifest(Map<String, dynamic> task) => {
      ...buildExportManifest(
          (task['groups'] as List).cast<Map<String, dynamic>>(),
          task['toleranceCents'] as int,
          meal: MealAllowance.fromTask(task)),
      'taskName': task['name'],
      ...?TripPeriod.fromTask(task)?.toJson(),
    };

Map<String, dynamic> buildExportManifest(
    List<Map<String, dynamic>> groups, int tolerance,
    {MealAllowance? meal}) {
  final invoices = <Map<String, dynamic>>[],
      pictures = <Map<String, dynamic>>[],
      summary = <Map<String, dynamic>>[];
  final usedPayments = <String>{};
  if (meal?.error != null) throw StateError(meal!.error!);
  if (groups.isEmpty && meal?.included != true) throw StateError('没有可导出的费用');
  final checks = assessGroups(groups, tolerance);
  for (var i = 0; i < groups.length; i++) {
    final g = groups[i], payments = g['payments'] as List;
    if (payments.isEmpty) throw StateError('发票缺少支付证据');
    final check = checks[i].reconciliation;
    if (!check.included) {
      throw StateError(
          '${invoiceNumber(i + 1)} 尚未匹配完整：${checks[i].problems.join('；')}');
    }
    if (isInvoiceBundle(g)) {
      final members = invoiceMembers(g), labels = bundleInvoiceNumbers(g, i);
      final weights = [for (final m in members) m['invoiceCents'] as int];
      final paid =
          allocateBundleAmount(check.allocatedNetPaymentCents, weights);
      final claimed = allocateBundleAmount(check.reimbursementCents!, weights);
      final p = Map<String, dynamic>.from(payments.single);
      if (!usedPayments.add(p['hash'] ?? p['path'])) {
        throw StateError('同一支付证据重复分配');
      }
      final paymentLabel = invoiceNumber(i + 1);
      pictures.add({
        'number': paymentLabel,
        'path': p['path'],
        'relatedInvoiceNumbers': labels
      });
      for (var n = 0; n < members.length; n++) {
        final m = members[n];
        invoices.add({
          'number': labels[n],
          'path': m['path'],
          'itineraries': m['itineraries'] ?? [],
          'supportingDocuments': []
        });
        summary.add({
          'number': labels[n],
          'category': g['category'],
          'invoiceCents': weights[n],
          'paymentCents': paid[n],
          'reimbursementCents': claimed[n],
          'differenceCents': weights[n] - paid[n],
          'withinTolerance': check.withinTolerance,
          'reviewed': g['confirmed'] == true,
          'description': '共同支付组 ${invoiceNumber(i + 1)} · ${m['name']}',
          'paymentNumbers': [paymentLabel]
        });
      }
      continue;
    }
    invoices.add({
      if (g['paperTaxi'] == true) 'paperTaxi': true,
      if (g['paperTaxi'] == true) 'invoiceCents': check.invoiceCents,
      if (g['paperTaxi'] == true) 'date': g['document']?['expenseDate'],
      'number': invoiceNumber(i + 1),
      'path': g['path'],
      'itineraries': g['itineraries'] ?? [],
      'supportingDocuments': [
        if (g['category'] == 'hotel' &&
            HotelCheck(g).resolved &&
            !HotelCheck(g).same &&
            HotelCheck(g).hasFileProof)
          HotelCheck(g).proof!['material']['path']
      ]
    });
    for (var j = 0; j < payments.length; j++) {
      final p = payments[j];
      if (!usedPayments.add(p['hash'] ?? p['path'])) {
        throw StateError('同一支付证据重复分配');
      }
      pictures.add({
        'number': paymentNumber(i + 1, j + 1, payments.length),
        'path': p['path']
      });
    }
    summary.add({
      'number': invoiceNumber(i + 1),
      'category': g['category'],
      'invoiceCents': check.invoiceCents,
      'paymentCents': check.allocatedNetPaymentCents,
      'reimbursementCents': check.reimbursementCents,
      'differenceCents': check.difference,
      'withinTolerance': check.withinTolerance,
      'reviewed': g['confirmed'] == true,
      'description': g['paperTaxi'] == true
          ? '出租车纸票${g['document']?['expenseDate'] == null ? '' : '（${g['document']['expenseDate']}）'}'
          : g['category'] == 'local'
              ? '市内交通（${(g['trips'] as List? ?? payments).length}笔行程）'
              : (g['document']?['platform'] == 'rail'
                  ? '铁路电子客票'
                  : (g['category'] == 'hotel'
                      ? (HotelCheck(g).same
                          ? '酒店住宿'
                          : '酒店住宿（${HotelCheck(g).proof?['kind'] == 'paper' ? '纸质情况说明已备' : '已附情况说明'}）')
                      : g['name'])),
      'paymentNumbers': [
        for (var j = 0; j < payments.length; j++)
          paymentNumber(i + 1, j + 1, payments.length)
      ]
    });
  }
  if (meal?.included == true) summary.add(meal!.summaryRow());
  Map<String, int> totals(Iterable<Map<String, dynamic>> rows) => {
        for (final key in [
          'invoiceCents',
          'paymentCents',
          'reimbursementCents'
        ])
          key: rows.fold<int>(0, (sum, row) => sum + (row[key] as int))
      };
  final categories = summary.map((r) => r['category'] as String).toSet();
  return {
    'invoices': invoices,
    'pictures': pictures,
    'summary': summary,
    'toleranceCents': tolerance,
    'reviewedInvoices': groups.where((g) => g['confirmed'] == true).length,
    'categoryTotals': [
      for (final category in categories)
        {
          'category': category,
          ...totals(summary.where((r) => r['category'] == category))
        }
    ],
    'grandTotals': totals(summary)
  };
}
