import 'dart:io';
import 'package:travel_core/travel_core.dart';
import 'services.dart';
import 'matching_helpers.dart';
import 'payment_identity.dart';

/// 文件识别由本地引擎完成，关联和金额判断统一调用 Dart 业务核心。
class FolderImporter {
  final ProcessingClient engine;
  final String materialDirectory;
  FolderImporter(this.engine, this.materialDirectory);

  Future<Map<String, dynamic>> importDirectory(String directory, int tolerance,
      {void Function(int, int, String)? onProgress,
      List<Map<String, dynamic>> excludedMaterials = const [],
      TimeMatchSettings timeSettings = const TimeMatchSettings()}) async {
    final files = await Directory(directory)
        .list(recursive: true, followLinks: false)
        .where((f) =>
            f is File &&
            RegExp(r'\.(pdf|png|jpe?g)$', caseSensitive: false)
                .hasMatch(f.path))
        .toList();
    files.sort((a, b) => a.path.compareTo(b.path));
    return importPaths(files.map((f) => f.path).toList(), tolerance,
        onProgress: onProgress,
        timeSettings: timeSettings,
        excludedMaterials: excludedMaterials);
  }

  Future<Map<String, dynamic>> importPaths(List<String> paths, int tolerance,
      {void Function(int, int, String)? onProgress,
      List<Map<String, dynamic>> paperTaxiGroups = const [],
      Map<String, Map<String, dynamic>> sourceMetadata = const {},
      Set<String> reservedPayments = const {},
      List<Map<String, dynamic>> reservedPaymentMaterials = const [],
      List<Map<String, dynamic>> excludedMaterials = const [],
      Map<String, int> reservedInvoices = const {},
      TimeMatchSettings timeSettings = const TimeMatchSettings()}) async {
    final files = paths.toSet().map(File.new).toList();
    final materials = <Map<String, dynamic>>[], issues = <String>[];
    final hasImages = files.any((f) => isScreenshot({'path': f.path}));
    final reservedIdentities = hasImages
        ? await loadPaymentIdentities(engine, reservedPaymentMaterials)
        : reservedPaymentMaterials;
    final identities = MaterialIdentityIndex(reservedIdentities),
        excluded = MaterialIdentityIndex(hasImages
            ? await loadPaymentIdentities(engine, excludedMaterials)
            : excludedMaterials);
    final duplicates = <Map<String, dynamic>>[];
    for (var i = 0; i < files.length; i++) {
      onProgress?.call(
          i, files.length, files[i].path.split(Platform.pathSeparator).last);
      if (excluded.find({'path': files[i].path}) != null) continue;
      try {
        final source = sourceMetadata[materialPathKey(files[i].path)];
        final material =
            Map<String, dynamic>.from(await engine.call('inspect', {
          'path': files[i].path,
          'material_dir': materialDirectory,
          if (source?['filename'] != null || source?['name'] != null)
            'source_name': source?['filename'] ?? source?['name']
        }));
        if (source != null) {
          if (source['hotelVerification'] is Map) {
            material['hotelVerification'] = source['hotelVerification'];
          }
          if (source['timeOverrides'] is Map) {
            material['timeOverrides'] =
                Map<String, dynamic>.from(source['timeOverrides']);
            material['timeCorrectionSource'] = source['timeCorrectionSource'];
          }
          final manual = source['manualPaymentCents'];
          final oldCandidate = source['ocr']?['paymentCandidate']?['cents'];
          if (manual is int) {
            material['manualPaymentCents'] = manual;
          } else if (source['cents'] is int &&
              oldCandidate is int &&
              source['cents'] != oldCandidate) {
            material['manualPaymentCents'] = source['cents'];
          }
          material['name'] =
              source['filename'] ?? source['name'] ?? material['name'];
          if (source['uid'] != null) {
            material['mailSource'] = source;
          } else if (source['mailSource'] != null) {
            material['mailSource'] = source['mailSource'];
          }
        }
        if (excluded.find(material) != null) continue;
        final existing = identities.find(material);
        if (existing != null ||
            (isScreenshot(material) &&
                reservedPayments.contains(material['hash']))) {
          if (isScreenshot(material)) {
            if (existing != null) {
              existing['paymentDuplicateHashes'] = {
                ...(existing['paymentDuplicateHashes'] as List? ?? []),
                if (material['hash'] != null &&
                    material['hash'] != existing['hash'])
                  material['hash']
              }.toList();
              existing['paymentDuplicatePixelHashes'] = {
                ...(existing['paymentDuplicatePixelHashes'] as List? ?? []),
                if (material['imagePixelHash'] != null &&
                    material['imagePixelHash'] != existing['imagePixelHash'])
                  material['imagePixelHash']
              }.toList();
            }
            duplicates.add({
              'name': material['name'],
              'path': material['path'],
              'hash': material['hash'],
              'keptName': existing?['name'] ?? '已有支付记录',
              'keptPath': existing?['path'],
              'reason':
                  existing != null && samePaymentContent(existing, material)
                      ? '交易字段和账单正文一致，已自动移除重复导入项'
                      : '重复图片内容或同一交易单号，已自动移除重复导入项'
            });
          }
          identities.add(material);
          continue;
        }
        identities.add(material);
        materials.add(material);
      } catch (e) {
        issues.add('${files[i].path}: $e');
        materials.add({
          'path': files[i].path,
          'name': files[i].path.replaceAll('\\', '/').split('/').last,
          'failedInspection': true,
          'inspectionError': '$e'
        });
      }
    }
    final rawInvoices =
        materials.where((m) => m['document']?['type'] == 'invoice').toList();
    final invoices = <Map<String, dynamic>>[],
        seenNumbers = <String, int>{},
        duplicateInvoices = <String>{};
    final conflictNumbers = <String>{};
    for (final m in rawInvoices) {
      final number = m['document']['number'] as String?;
      final amount = m['document']['totalCents'] as int?;
      if (number == null || amount == null) continue;
      if (seenNumbers.containsKey(number) && seenNumbers[number] != amount) {
        conflictNumbers.add(number);
      }
      seenNumbers[number] = amount;
    }
    final acceptedNumbers = <String>{};
    for (final m in rawInvoices) {
      final number = m['document']['number'] as String?;
      if (number != null && conflictNumbers.contains(number)) {
        issues.add('${m['name']}：同一发票号码出现不同金额，请人工核对');
        continue;
      }
      if (number != null && reservedInvoices.containsKey(number)) {
        duplicateInvoices.add(m['hash']);
        if (m['document']['totalCents'] != reservedInvoices[number]) {
          issues.add('${m['name']}：与已保留发票同号但金额不同，未自动纳入');
        }
        continue;
      }
      if (number != null && !acceptedNumbers.add(number)) {
        duplicateInvoices.add(m['hash']);
        continue;
      }
      invoices.add(m);
    }
    invoices.addAll(paperTaxiGroups);
    final itineraries =
        materials.where((m) => m['document']?['type'] == 'itinerary').toList();
    final paymentMaterials = materials
        .where((m) =>
            (m['ocr']?['paymentCandidate']?['cents'] != null ||
                m['manualPaymentCents'] is int) &&
            !reservedPayments.contains(m['hash']))
        .toList();
    final payments = paymentMaterials.map(paymentEvidence).toList();
    final groups = <Map<String, dynamic>>[],
        charges = <ChargeToMatch>[],
        chargeIds = <String, List<String>>{};
    final usedItineraries = <String>{};
    for (final invoice in invoices) {
      final d = invoice['document'];
      if (d['totalCents'] == null || d['category'] == null) {
        issues.add('${invoice['name']}：发票金额或类别未识别');
        continue;
      }
      final group = <String, dynamic>{
        ...invoice,
        'invoiceCents': d['totalCents'],
        'category': d['category'],
        'payments': <Map<String, dynamic>>[],
        'itineraries': <String>[],
        'itineraryMaterials': <Map<String, dynamic>>[],
        'trips': <dynamic>[],
        'confirmed': false,
        'complete': false,
        'matchingReasons': <String>[],
        'matchingPolicy': {
          'version': 4,
          'mode': 'dateTimeAndAmount',
          'timeMatching': timeSettings.toJson()
        },
      };
      final ids = <String>[];
      if (d['category'] == 'local' && invoice['paperTaxi'] != true) {
        final candidates = itineraries
            .where((m) =>
                m['document']['platform'] == d['platform'] &&
                m['document']['totalCents'] == d['totalCents'] &&
                m['document']['complete'] == true)
            .toList();
        if (candidates.length == 1 &&
            !usedItineraries.contains(candidates.single['hash'])) {
          final itinerary = candidates.single;
          usedItineraries.add(itinerary['hash']);
          group['itineraries'] = [itinerary['path']];
          group['itineraryMaterials'] = [itinerary];
          group['trips'] = itinerary['document']['trips'];
          group['matchingReasons'].add('行程单平台、总额与明细合计一致');
          for (final trip in group['trips']) {
            final id = '${invoice['hash']}/${trip['index']}';
            ids.add(id);
            charges.add(
                tripCharge(Map<String, dynamic>.from(trip), id, d['platform']));
          }
        } else {
          group['matchingReasons'].add('缺少完整且唯一对应的行程单，需要人工补充');
        }
      } else {
        final id = invoice['hash'] as String;
        ids.add(id);
        charges.add(ChargeToMatch(
            paperTaxi: invoice['paperTaxi'] == true,
            id: id,
            category: d['category'],
            platform: d['platform'],
            cents: d['totalCents'],
            date: DateTime.tryParse(d['expenseDate'] ?? d['issueDate'] ?? '')));
      }
      chargeIds[invoice['hash']] = ids;
      groups.add(group);
    }
    final suggestions = suggestPayments(charges, payments,
        toleranceCents: tolerance, timeSettings: timeSettings);
    final usedPayments = <String>{};
    for (final group in groups) {
      final ids = chargeIds[group['hash']]!;
      for (var index = 0; index < ids.length; index++) {
        final suggestion = suggestions[ids[index]]!;
        group['matchingReasons'].add(suggestion.reason);
        if (suggestion.selected != null) {
          final p = suggestion.selected!;
          final material =
              paymentMaterials.singleWhere((m) => m['hash'] == p.id);
          (group['payments'] as List).add({
            ...material,
            'cents': p.cents,
            'matchingReason': suggestion.reason,
            'tripIndex':
                group['category'] == 'local' && group['paperTaxi'] != true
                    ? group['trips'][index]['index']
                    : null
          });
          usedPayments.add(p.id);
        }
      }
      group['suggestionComplete'] =
          ids.isNotEmpty && (group['payments'] as List).length == ids.length;
    }
    const order = {'intercity': 0, 'hotel': 1, 'local': 2};
    groups.sort((a, b) =>
        (order[a['category']] ?? 3).compareTo(order[b['category']] ?? 3));
    return {
      'groups': groups,
      'materials': materials,
      'issues': issues,
      'duplicateInvoices': duplicateInvoices.length,
      'duplicatePayments': duplicates,
      'reservedPaymentIdentityUpdates': reservedIdentities,
      'unmatchedPayments': paymentMaterials
          .where((m) => !usedPayments.contains(m['hash']))
          .toList(),
      'unmatchedMaterials': materials
          .where((m) =>
              !paymentMaterials.contains(m) &&
              (m['failedInspection'] == true ||
                  m['document']?['type'] == 'unknown' ||
                  m['needsOcr'] == true ||
                  (m['ocr'] != null && m['ocr']['paymentCandidate'] == null) ||
                  (m['document']?['type'] == 'itinerary' &&
                      !usedItineraries.contains(m['hash'])) ||
                  (m['document']?['type'] == 'invoice' &&
                      !duplicateInvoices.contains(m['hash']) &&
                      !groups.any((g) => g['hash'] == m['hash']))))
          .toList()
    };
  }
}

String materialPathKey(String path) {
  final value = File(path).absolute.path.replaceAll('\\', '/');
  return Platform.isWindows ? value.toLowerCase() : value;
}
