import 'invoice_bundle.dart';
import 'import_service.dart';
import 'package:travel_core/travel_core.dart';

typedef PdfMaterial = Map<String, dynamic>;
List<PdfMaterial> _records(dynamic value) =>
    (value as List? ?? []).cast<PdfMaterial>();

class PdfCatalogEntry {
  final String id;
  PdfMaterial material;
  final List<PdfMaterial> sources = [];
  final Set<String> uses = {};
  final Set<String> _sourceIds = {};
  PdfCatalogEntry(this.id, this.material);
  String get name => material['name'] as String;
  String get kind => material['document']?['type'] == 'invoice'
      ? 'invoice'
      : (material['document']?['type'] == 'itinerary' ? 'itinerary' : 'other');
  String get kindLabel =>
      const {'invoice': '发票', 'itinerary': '行程单', 'other': '其他 PDF'}[kind]!;
  String get status => uses.isEmpty ? '未关联' : uses.join('；');

  void addSource(PdfMaterial m) {
    if (m['uid'] != null || m['account'] != null) {
      final key = ['account', 'folder', 'uidValidity', 'uid', 'partIndex']
          .map((k) => m[k] ?? '')
          .join('|');
      if (_sourceIds.add(key)) {
        sources.add({
          for (final k in [
            'account',
            'folder',
            'uidValidity',
            'uid',
            'partIndex',
            'subject',
            'sender',
            'receivedAt',
            'filename',
            'archiveFilename',
            'archiveMember'
          ])
            if (m[k] != null) k: m[k],
        });
      }
    }
    if (m['mailSource'] is Map) addSource(PdfMaterial.from(m['mailSource']));
    for (final s in [
      ..._records(m['additionalSources']),
      ..._records(m['pdfSources'])
    ]) {
      addSource(s);
    }
  }
}

String _identity(PdfMaterial m) {
  if (m['hash'] != null) return m['hash'];
  final name = m['path'].toString().replaceAll('\\', '/').split('/').last;
  final digest = RegExp(r'^([0-9a-fA-F]{64})\.pdf$', caseSensitive: false)
      .firstMatch(name);
  return digest?[1]?.toLowerCase() ?? materialPathKey(m['path']);
}

/// 从材料台账及旧任务回填完整清单；按内容去重，保留多封邮件来源。
List<PdfCatalogEntry> buildPdfCatalog(PdfMaterial task) {
  final entries = <String, PdfCatalogEntry>{},
      paths = <String, PdfCatalogEntry>{},
      aliases = <String, PdfCatalogEntry>{};
  void add(PdfMaterial m, {String? use, String? kind}) {
    final path = m['path'] as String?;
    if (path == null || !path.toLowerCase().endsWith('.pdf')) return;
    final pathKey = materialPathKey(path), id = _identity(m);
    final e = aliases[id] ?? paths[pathKey] ?? PdfCatalogEntry(id, {});
    entries.putIfAbsent(e.id, () => e);
    aliases[id] = e;
    paths[pathKey] = e;
    final metadata = <String, dynamic>{
      for (final k in [
        'path',
        'hash',
        'text',
        'pages',
        'document',
        'needsOcr',
        'needsReview'
      ])
        if (m[k] != null) k: m[k],
    };
    final name = (m['filename'] ??
            m['name'] ??
            path.replaceAll('\\', '/').split('/').last)
        .toString();
    final hashName =
        RegExp(r'^[0-9a-fA-F]{64}\.pdf$', caseSensitive: false).hasMatch(name);
    metadata['name'] = hashName && e.material['name'] != null ? e.name : name;
    if (metadata['document']?['type'] == 'unknown' &&
        e.material['document'] != null) {
      metadata.remove('document');
    }
    e.material = {...e.material, ...metadata};
    if (kind != null) {
      e.material['document'] = {
        ...?e.material['document'] as PdfMaterial?,
        'type': kind
      };
    }
    e.addSource(m);
    if (use != null) e.uses.add(use);
  }

  for (final m in [
    ..._records(task['mailSources']),
    ..._records(task['pdfMaterials']),
    ..._records(task['unmatchedMaterials'])
  ]) {
    add(m);
  }
  final groups = _records(task['groups']);
  for (var i = 0; i < groups.length; i++) {
    final g = groups[i], number = invoiceNumber(i + 1);
    final hotel = g['hotelVerification'];
    if (hotel?['proof']?['kind'] == 'pdf' &&
        hotel['proof']['material'] is Map) {
      add(PdfMaterial.from(hotel['proof']['material']), use: '$number 酒店情况说明');
    }
    add(g,
        kind: 'invoice',
        use: '$number 发票（${g['confirmed'] == true ? '已确认' : '待核对'}）');
    if (isInvoiceBundle(g)) {
      final labels = bundleInvoiceNumbers(g, i);
      final members = invoiceMembers(g);
      for (var n = 0; n < members.length; n++) {
        add(members[n], kind: 'invoice', use: '${labels[n]} 共同支付发票');
        for (final file in _records(members[n]['itineraryMaterials'])) {
          add(file);
        }
        for (final path in members[n]['itineraries'] as List? ?? []) {
          add(
              paths[materialPathKey(path)]?.material ??
                  {
                    'path': path,
                    'name': '${members[n]['name']} · 配套行程单',
                    'document': {'type': 'itinerary'}
                  },
              kind: 'itinerary',
              use: '${labels[n]} 配套行程单');
        }
      }
    }
    for (final m in _records(g['itineraryMaterials'])) {
      add(m);
    }
    for (final path in (g['itineraries'] as List? ?? [])) {
      final existing = paths[materialPathKey(path)];
      add(
          existing?.material ??
              {
                'path': path,
                'name': '${g['name']} · 配套行程单',
                'document': {
                  'type': 'itinerary',
                  'platform': g['document']?['platform'],
                  'totalCents': g['invoiceCents'],
                  'trips': g['trips'] ?? [],
                  'complete': _records(g['trips']).isNotEmpty
                },
              },
          kind: 'itinerary',
          use: '$number 配套行程单');
    }
  }
  return entries.values.toList()..sort((a, b) => a.name.compareTo(b.name));
}

List<PdfMaterial> pdfCatalogMaterials(PdfMaterial task) => [
      for (final e in buildPdfCatalog(task))
        {...e.material, if (e.sources.isNotEmpty) 'pdfSources': e.sources},
    ];
