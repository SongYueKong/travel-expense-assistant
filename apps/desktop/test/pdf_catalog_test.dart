import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:travel_assistant/pdf_catalog.dart';
import 'package:travel_assistant/association_service.dart';
import 'package:travel_assistant/material_merge_service.dart';
import 'package:travel_assistant/services.dart';
import 'association_service_test.dart' show fixture, invoice, itinerary;

Map<String, dynamic> source(String id, String uid, {String? path}) => {
      'path': path ?? 'C:/mail/$id.pdf',
      'hash': id,
      'filename': '$id.pdf',
      'account': 'test@qq.com',
      'folder': 'INBOX',
      'uidValidity': '1',
      'uid': uid,
      'partIndex': 1,
      'subject': '发票邮件 $uid',
      'sender': '票据服务',
      'receivedAt': '2026-10-29',
    };

class CatalogProcessor implements ProcessingClient {
  @override
  Future<dynamic> call(String method, Map<String, dynamic> params) async {
    final name =
        params['path'].toString().replaceAll('\\', '/').split('/').last;
    if (name == 'unreadable.pdf') throw StateError('无法解析 PDF');
    return {
      'path': 'C:/managed/$name',
      'hash': name.replaceFirst('.pdf', ''),
      'name': name,
      'document': {
        'type': 'invoice',
        'number': 'same-number',
        'category': 'hotel',
        'totalCents': 10000
      }
    };
  }
}

void main() {
  test(
      'legacy task includes invoices, itinerary paths and unrelated PDFs without mutation',
      () {
    final task = fixture();
    task['groups'][0]['itineraries'] = ['C:/test/legacy-itinerary.pdf'];
    task['unmatchedMaterials'] = [
      {
        'path': 'C:/test/unknown.pdf',
        'document': {'type': 'unknown'}
      }
    ];
    final before = jsonEncode(task);
    final catalog = buildPdfCatalog(task);
    expect(catalog.length, 4);
    expect(
        catalog.where((e) => e.kind == 'itinerary').single.status, '001 配套行程单');
    expect(catalog.where((e) => e.kind == 'other').single.status, '未关联');
    expect(jsonEncode(task), before);
  });

  test(
      'same content from multiple emails keeps all unique origins and managed metadata',
      () {
    final first = source('same', '1');
    first['additionalSources'] = [source('same', '2')];
    final task = {
      'mailSources': [first, source('same', '1')],
      'pdfMaterials': [
        {
          'hash': 'same',
          'path': 'C:/managed/same.pdf',
          'name': '原始发票名.pdf',
          'document': {'type': 'invoice', 'number': '123'}
        }
      ]
    };
    final catalog = buildPdfCatalog(task);
    expect(catalog.length, 1);
    expect(catalog.single.sources.length, 2);
    expect(catalog.single.material['path'], 'C:/managed/same.pdf');
    expect(catalog.single.kind, 'invoice');
    expect(catalog.single.name, '原始发票名.pdf');
    final reopened = buildPdfCatalog(
        {'pdfMaterials': jsonDecode(jsonEncode(pdfCatalogMaterials(task)))});
    expect(reopened.single.sources.length, 2);
  });

  test(
      'path aliases still deduplicate after a legacy material obtains a content hash',
      () {
    final task = {
      'pdfMaterials': [
        {'path': 'C:/legacy/file.pdf', 'name': '旧文件.pdf'},
        {'path': 'C:/legacy/file.pdf', 'hash': 'same'},
        {'path': 'C:/managed/another.pdf', 'hash': 'same'},
      ]
    };
    expect(buildPdfCatalog(task).length, 1);
  });

  test(
      'persistent catalog does not store financial or confirmation fields from group',
      () {
    final g = invoice('one');
    g['confirmed'] = true;
    g['complete'] = true;
    final material = pdfCatalogMaterials({
      'groups': [g]
    }).single;
    for (final key in [
      'confirmed',
      'complete',
      'payments',
      'invoiceCents',
      'matchingReasons'
    ]) {
      expect(material.containsKey(key), isFalse, reason: key);
    }
  });

  test(
      'deleting an old group retains its invoice and itinerary in all PDFs as unassociated',
      () {
    final task = fixture();
    task['groups'] = [invoice('local')];
    task['groups'][0]['itineraries'] = ['C:/test/i.pdf'];
    final result = removeAssociationGroup(task, 0);
    expect(buildPdfCatalog(result).length, 2);
    expect(buildPdfCatalog(result).every((e) => e.status == '未关联'), isTrue);
  });

  test(
      'catalog makes retained unassociated itineraries available for manual selection',
      () {
    final task = fixture();
    task['pdfMaterials'] = [itinerary('saved-itinerary')];
    final editor = AssociationEditor(task, 0);
    expect(editor.itineraries.values.any((m) => m['hash'] == 'saved-itinerary'),
        isTrue);
  });

  test(
      'all imported attachments remain listed when parsing fails or invoice numbers duplicate',
      () async {
    final task = <String, dynamic>{
      'groups': <dynamic>[],
      'toleranceCents': 100
    };
    final files = [
      source('first', '1'),
      source('duplicate', '2'),
      source('unreadable', '3')
    ];
    final merged = await MaterialMerger(CatalogProcessor(), 'unused')
        .merge(task, mailFiles: files);
    expect((merged['groups'] as List).length, 1);
    expect(merged['duplicateInvoices'], 1);
    expect((merged['importIssues'] as List).length, 1);
    final catalog = buildPdfCatalog(merged);
    expect(catalog.length, 3);
    expect(catalog.where((e) => e.sources.isNotEmpty).length, 3);
    expect(catalog.any((e) => e.name == 'unreadable.pdf'), isTrue);
    expect(catalog.where((e) => e.status == '未关联').length, 2);
  });
}
