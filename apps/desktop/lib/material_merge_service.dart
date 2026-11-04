import 'dart:io';
import 'dart:convert';
import 'import_service.dart';
import 'services.dart';
import 'pdf_catalog.dart';
import 'matching_helpers.dart';
import 'invoice_bundle.dart';

class MaterialMerger {
  final ProcessingClient engine;
  final String materialDirectory;
  MaterialMerger(this.engine, this.materialDirectory);

  Future<Map<String, dynamic>> merge(Map<String, dynamic> task,
      {List<Map<String, dynamic>> mailFiles = const [],
      String? paymentDirectory,
      bool recalculateManual = false,
      void Function(int, int, String)? onProgress}) async {
    task = jsonDecode(jsonEncode(task)) as Map<String, dynamic>;
    final oldGroups =
        (task['groups'] as List? ?? []).cast<Map<String, dynamic>>();
    bool protected(Map<String, dynamic> g) =>
        isInvoiceBundle(g) ||
        g['confirmed'] == true ||
        g['manuallyEntered'] == true ||
        (!recalculateManual && g['manuallyAssociated'] == true) ||
        !g.containsKey('suggestionComplete') ||
        g['document'] == null ||
        g['invoiceCents'] != g['document']['totalCents'];
    final keep = oldGroups.where(protected).toList();
    final paths = <String, String>{},
        sources = <String, Map<String, dynamic>>{},
        protectedPaths = <String>{};
    final reservedPayments = <String>{}, reservedInvoices = <String, int>{};
    for (final group in keep) {
      if (group['path'] is String) {
        protectedPaths.add(materialPathKey(group['path']));
      }
      for (final path in (group['itineraries'] as List? ?? [])) {
        protectedPaths.add(materialPathKey(path));
      }
      for (final p in group['payments']) {
        protectedPaths.add(materialPathKey(p['path']));
        reservedPayments.add(p['hash'] ?? p['path']);
      }
      for (final member in invoiceMembers(group)) {
        if (member['path'] is String) {
          protectedPaths.add(materialPathKey(member['path']));
        }
        for (final path in member['itineraries'] as List? ?? []) {
          protectedPaths.add(materialPathKey(path));
        }
        final number = member['document']?['number'] as String?;
        if (number != null) reservedInvoices[number] = member['invoiceCents'];
      }
    }
    void add(String path, [Map<String, dynamic>? source]) {
      final key = materialPathKey(path);
      if (protectedPaths.contains(key)) return;
      paths[key] = path;
      if (source != null) sources[key] = source;
    }

    for (final group in oldGroups.where((g) => !protected(g))) {
      if (group['path'] is String) add(group['path'], group);
      for (final path in group['itineraries']) {
        final metadata = (group['itineraryMaterials'] as List? ?? [])
            .where((m) => materialPathKey(m['path']) == materialPathKey(path));
        add(
            path,
            metadata.isEmpty
                ? null
                : Map<String, dynamic>.from(metadata.first));
      }
      for (final payment in group['payments']) {
        add(payment['path'], Map<String, dynamic>.from(payment));
      }
    }
    for (final key in ['unmatchedPayments', 'unmatchedMaterials']) {
      for (final m in (task[key] as List? ?? [])) {
        add(m['path'], Map<String, dynamic>.from(m));
      }
    }
    for (final file in mailFiles) {
      add(file['path'], file);
    }
    if (paymentDirectory != null) {
      await for (final item in Directory(paymentDirectory)
          .list(recursive: true, followLinks: false)) {
        if (item is File &&
            RegExp(r'\.(png|jpe?g)$', caseSensitive: false)
                .hasMatch(item.path)) {
          add(item.path);
        }
      }
    }
    final imported = await FolderImporter(engine, materialDirectory)
        .importPaths(paths.values.toList(), task['toleranceCents'],
            paperTaxiGroups: oldGroups
                .where((g) => g['paperTaxi'] == true && !protected(g))
                .toList(),
            onProgress: onProgress,
            sourceMetadata: sources,
            reservedPayments: reservedPayments,
            reservedPaymentMaterials: [
              for (final g in keep)
                ...((g['payments'] as List).cast<Map<String, dynamic>>())
            ],
            excludedMaterials: (task['ignoredMaterials'] as List? ?? [])
                .cast<Map<String, dynamic>>(),
            reservedInvoices: reservedInvoices,
            timeSettings: timeSettingsOf(task));
    for (final g in keep) {
      for (final p in (g['payments'] as List).cast<Map<String, dynamic>>()) {
        final updates = (imported['reservedPaymentIdentityUpdates'] as List)
            .where((m) =>
                materialPathKey(m['path']) == materialPathKey(p['path']));
        if (updates.isEmpty) continue;
        final identity = updates.first;
        for (final field in [
          'imagePixelHash',
          'paymentIdentityVersion',
          'paymentContentEvidence',
          'paymentDuplicateHashes',
          'paymentDuplicatePixelHashes'
        ]) {
          if (identity.containsKey(field)) p[field] = identity[field];
        }
        for (final field in ['paymentTransactionId', 'transactionIdKind']) {
          if (identity['ocr']?[field] != null) {
            p['ocr'] = {
              ...Map<String, dynamic>.from(p['ocr'] ?? {}),
              field: identity['ocr'][field]
            };
          }
        }
      }
    }
    final groups = [
      ...keep,
      ...(imported['groups'] as List).cast<Map<String, dynamic>>()
    ];
    const order = {'intercity': 0, 'hotel': 1, 'local': 2};
    groups.sort((a, b) =>
        (order[a['category']] ?? 3).compareTo(order[b['category']] ?? 3));
    final currentSources = (task['mailSources'] as List? ?? [])
        .cast<Map<String, dynamic>>()
        .toList();
    for (final source in mailFiles) {
      if (!currentSources.any((m) =>
          m['account'] == source['account'] &&
          m['folder'] == source['folder'] &&
          m['uidValidity'] == source['uidValidity'] &&
          m['uid'] == source['uid'] &&
          m['partIndex'] == source['partIndex'])) {
        currentSources.add(source);
      }
    }
    String normalize(String value) =>
        Platform.isWindows ? value.replaceAll('\\', '/').toLowerCase() : value;
    final attemptedPrefixes = [
      for (final path in paths.values) '${normalize(path)}:',
      for (final m in sources.values)
        if (m['name'] != null) '${normalize(m['name'])}：'
    ];
    final issues = {
      for (final issue in task['importIssues'] as List? ?? [])
        if (!attemptedPrefixes
            .any((prefix) => normalize(issue.toString()).startsWith(prefix)))
          issue.toString(),
      ...((imported['issues'] as List).cast<String>())
    };
    return {
      ...task,
      'groups': groups,
      'importIssues': issues.toList(),
      'unmatchedPayments': imported['unmatchedPayments'],
      'unmatchedMaterials': imported['unmatchedMaterials'],
      'mailSources': currentSources,
      'pdfMaterials': pdfCatalogMaterials({
        ...task,
        'groups': groups,
        'mailSources': currentSources,
        'unmatchedMaterials': imported['unmatchedMaterials'],
        'pdfMaterials': [
          ...(task['pdfMaterials'] as List? ?? []),
          ...(imported['materials'] as List),
          ...mailFiles
        ]
      }),
      'duplicateInvoices': imported['duplicateInvoices'],
      'duplicatePayments': imported['duplicatePayments'],
    };
  }
}
