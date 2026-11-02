import 'package:flutter_test/flutter_test.dart';
import 'package:travel_assistant/services.dart';
import 'package:travel_assistant/import_service.dart';
import 'package:travel_assistant/export_service.dart';

class GaodeProcessor implements ProcessingClient {
  final String paymentPlatform;
  final names = <String>[];
  GaodeProcessor({this.paymentPlatform = 'gaode'});
  @override
  Future<dynamic> call(String method, Map<String, dynamic> p) async {
    if (method != 'inspect') throw StateError(method);
    final path = p['path'] as String, name = p['source_name'] as String?;
    names.add(name ?? '');
    if (path.endsWith('.jpg')) {
      return {
        'path': path,
        'name': 'payment.jpg',
        'hash': 'payment',
        'ocr': {
          'category': 'local',
          'platform': paymentPlatform,
          'paymentDate': '2026-10-20',
          'paymentDateTime': '2026-10-20T09:40:00+08:00',
          'rideDateTime': '2026-10-20T09:01:00+08:00',
          'paymentCandidate': {'cents': 3785}
        }
      };
    }
    final itinerary = path.endsWith('b.pdf');
    final valid = name != null && name.contains('高德');
    return {
      'path': path,
      'name': name ?? 'hash.pdf',
      'hash': itinerary ? 'itinerary' : 'invoice',
      'document': {
        'type': itinerary ? 'itinerary' : 'invoice',
        'category': valid ? 'local' : null,
        'platform': valid ? 'gaode' : null,
        'totalCents': 3785,
        if (itinerary) ...{
          'expectedCount': 1,
          'complete': true,
          'trips': [
            {
              'index': 1,
              'date': '2026-10-20',
              'time': '09:02',
              'cents': 3785,
              'vehicleType': '特惠快车'
            }
          ]
        }
      }
    };
  }
}

void main() {
  const a = 'C:/fixture/a.pdf',
      b = 'C:/fixture/b.pdf',
      payment = 'C:/fixture/pay.jpg';
  final sources = {
    materialPathKey(a): {'filename': '高德打车电子发票.pdf'},
    materialPathKey(b): {'filename': '高德打车电子行程单.pdf'}
  };
  test(
      'hashed mail attachments retain original filename for platform recognition and link itinerary',
      () async {
    final engine = GaodeProcessor();
    final result = await FolderImporter(engine, 'unused')
        .importPaths([a, b], 100, sourceMetadata: sources);
    expect(engine.names, ['高德打车电子发票.pdf', '高德打车电子行程单.pdf']);
    final group = (result['groups'] as List).single;
    expect(group['category'], 'local');
    expect(group['trips'].length, 1);
    expect(group['itineraries'], [b]);
    expect(group['suggestionComplete'], false);
  });
  test('gaode trip matches gaode payment; didi payment cannot cross platforms',
      () async {
    for (final platform in ['gaode', 'didi']) {
      final result = await FolderImporter(
              GaodeProcessor(paymentPlatform: platform), 'unused')
          .importPaths([a, b, payment], 100, sourceMetadata: sources);
      final group =
          (result['groups'] as List).cast<Map<String, dynamic>>().single;
      expect(group['suggestionComplete'], platform == 'gaode');
      if (platform == 'gaode') {
        expect(
            buildExportManifest([group], 100)['grandTotals']
                ['reimbursementCents'],
            3785);
      } else {
        expect(group['payments'], isEmpty);
      }
    }
  });
}
