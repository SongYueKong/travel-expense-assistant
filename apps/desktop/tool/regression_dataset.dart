// 本地真实材料回归入口；所有引擎写入限定在独立临时工作区。
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:travel_core/travel_core.dart';
import 'package:travel_assistant/services.dart';
import 'package:travel_assistant/import_service.dart';
import 'package:travel_assistant/hotel_check.dart';
import 'package:travel_assistant/export_service.dart';
import 'package:travel_assistant/taxi_record.dart';

dynamic field(dynamic value, String path) {
  for (final key in path.split('.')) {
    if (value is Map) {
      value = value[key];
    } else if (value is List && int.tryParse(key) != null) {
      final index = int.parse(key);
      value = index < value.length ? value[index] : null;
    } else {
      return null;
    }
  }
  return value;
}

class CachedEngine implements ProcessingClient {
  final EngineClient engine;
  final Map<String, dynamic> inspected;
  CachedEngine(this.engine, this.inspected);
  @override
  Future<dynamic> call(String method, Map<String, dynamic> params) async =>
      method == 'inspect' && inspected.containsKey(params['path'])
          ? jsonDecode(jsonEncode(inspected[params['path']]))
          : engine.call(method, params);
}

Future<void> main(List<String> args) async {
  if (args.length != 3) {
    stderr.writeln('参数：项目根目录 数据集目录 报告目录');
    exitCode = 2;
    return;
  }
  final root = Directory(args[0]).absolute;
  final dataset = Directory(args[1]).absolute;
  final reports = Directory(args[2]).absolute;
  await reports.create(recursive: true);
  final sandbox = await Directory.systemTemp.createTemp('travel-regression-');
  EngineClient? engine;
  final results = <Map<String, dynamic>>[];
  final actuals = <String, dynamic>{};
  final metadata = <String, dynamic>{};
  void check(String id, String title, Map<String, dynamic> expected,
      Map<String, dynamic> actual) {
    final differences = <Map<String, dynamic>>[];
    for (final e in expected.entries) {
      final got = field(actual, e.key);
      if (jsonEncode(got) != jsonEncode(e.value)) {
        differences.add({'field': e.key, 'expected': e.value, 'actual': got});
      }
    }
    results.add({
      'id': id,
      'title': title,
      'passed': differences.isEmpty,
      'differences': differences
    });
    stdout.writeln('${differences.isEmpty ? 'PASS' : 'FAIL'} $id · $title');
  }

  try {
    final manifest =
        jsonDecode(await File('${dataset.path}/dataset.json').readAsString())
            as Map<String, dynamic>;
    if (manifest['schemaVersion'] != 1) {
      throw const FormatException('不支持的数据集版本');
    }
    metadata.addAll({
      'datasetId': manifest['id'],
      'datasetVersion': manifest['version'],
      'startedAt': DateTime.now().toIso8601String(),
      'platform': Platform.operatingSystem,
      'dart': Platform.version,
      'dataPolicy': 'local-only; no production database or credentials',
      'syntheticSuite':
          'test/taxi_test.dart, test/discount_matching_test.dart, test/time_matching_test.dart'
    });
    metadata['manifestSha256'] = sha256
        .convert(await File('${dataset.path}/dataset.json').readAsBytes())
        .toString();
    final sourceHashes = <String, String>{};
    for (final name in [
      'engine/ocr.py',
      'engine/documents.py',
      'engine/worker.py',
      'packages/travel_core/lib/travel_core.dart',
      'apps/desktop/lib/import_service.dart',
      'apps/desktop/lib/material_merge_service.dart',
      'testdata/rules.json'
    ]) {
      sourceHashes[name] = sha256
          .convert(await File('${root.path}/$name').readAsBytes())
          .toString();
    }
    metadata['sourceSha256'] = sourceHashes;
    final rules = jsonDecode(
            await File('${root.path}/testdata/rules.json').readAsString())
        as Map<String, dynamic>;
    for (final scenario
        in (rules['cases'] as List).cast<Map<String, dynamic>>()) {
      final charges = [
        for (final c in scenario['charges'])
          ChargeToMatch(
              id: c['id'],
              category: c['category'],
              cents: c['cents'],
              platform: c['platform'],
              date: DateTime.tryParse(c['date'] ?? ''),
              startedAt: beijingTimestamp(c['startedAt']),
              paperTaxi: c['paperTaxi'] == true,
              requireSameDate: c['requireSameDate'] == true)
      ];
      final payments = [
        for (final p in scenario['payments'])
          PaymentEvidence(
              id: p['id'],
              category: p['category'],
              cents: p['cents'],
              platform: p['platform'],
              date: DateTime.tryParse(p['date'] ?? ''),
              rideAt: beijingTimestamp(p['rideAt']),
              paidAt: beijingTimestamp(p['paidAt']),
              discountCents: p['discountCents'] ?? 0)
      ];
      final suggestions = suggestPayments(charges, payments,
          toleranceCents: scenario['toleranceCents'] ?? 100);
      check('rule:${scenario['id']}', scenario['title'], {
        'selected': scenario['selected']
      }, {
        'selected': {
          for (final c in charges) c.id: suggestions[c.id]?.selected?.id
        }
      });
    }
    engine = await EngineClient.start(sandbox.path, engineRoot: root.path);
    final paths = <String, String>{},
        hashes = <String, String>{},
        inspected = <String, dynamic>{};
    final assetFiles = (manifest['files'] as List).cast<Map<String, dynamic>>();
    if (assetFiles.isEmpty) throw const FormatException('真实材料数据集为空');
    // 原件完整性有异常时停止识别，不用变更后的样本继续生成“通过”结果。
    for (final asset in assetFiles) {
      final id = asset['id'] as String, relative = asset['file'] as String;
      if (asset['expected'] is! Map || (asset['expected'] as Map).isEmpty) {
        throw FormatException('材料缺少人工预期：$id');
      }
      if (paths.containsKey(id) ||
          !RegExp(r'^assets/[A-Za-z0-9_.-]+$').hasMatch(relative)) {
        throw FormatException('重复编号或非法材料路径：$id');
      }
      final file = File('${dataset.path}/$relative');
      final resolved = await file.resolveSymbolicLinks();
      final base = (await dataset.resolveSymbolicLinks())
          .replaceAll('\\', '/')
          .toLowerCase();
      if (!resolved.replaceAll('\\', '/').toLowerCase().startsWith('$base/')) {
        throw const FormatException('材料路径越界');
      }
      final digest = (await sha256.bind(file.openRead()).first).toString();
      if (digest != asset['sha256']) throw FormatException('样本哈希不一致：$id');
      paths[id] = file.absolute.path;
      hashes[id] = digest;
    }
    for (final asset in assetFiles) {
      final id = asset['id'] as String;
      try {
        final record = await engine.call('inspect', {
          'path': paths[id],
          'material_dir': '${sandbox.path}/materials',
          if (asset['sourceName'] != null) 'source_name': asset['sourceName']
        });
        inspected[paths[id]!] = record;
        actuals[id] = record;
        check(
            'file:$id',
            asset['title'] ?? id,
            Map<String, dynamic>.from(asset['expected'] ?? {}),
            Map<String, dynamic>.from(record));
      } catch (e) {
        results.add({
          'id': 'file:$id',
          'title': asset['title'],
          'passed': false,
          'error': '$e'
        });
      }
    }
    final cached = CachedEngine(engine, inspected);
    for (final scenario
        in (manifest['cases'] as List).cast<Map<String, dynamic>>()) {
      final id = scenario['id'] as String;
      try {
        final input = (scenario['inputs'] as List).cast<String>();
        if (input.any((key) => !paths.containsKey(key))) {
          throw const FormatException('场景引用未知材料');
        }
        final imported =
            await FolderImporter(cached, '${sandbox.path}/materials')
                .importPaths(input.map((key) => paths[key]!).toList(),
                    scenario['toleranceCents'] ?? 100,
                    paperTaxiGroups: [
              for (final taxi in scenario['taxis'] as List? ?? [])
                newTaxiRecord(taxi['cents'],
                    taxi['date'] == null ? null : DateTime.parse(taxi['date']))
            ]);
        final groups =
            (imported['groups'] as List).cast<Map<String, dynamic>>();
        String assetId(Map record) =>
            paths.keys.firstWhere((key) => hashes[key] == record['hash'],
                orElse: () => record['hash'].toString());
        final assignments = {
          for (final g in groups)
            if (g['paperTaxi'] != true)
              assetId(g): [
                for (final p in g['payments'])
                  assetId(Map<String, dynamic>.from(p))
              ]
        };
        Map<String, dynamic>? exportManifest;
        String? exportError;
        try {
          exportManifest =
              buildExportManifest(groups, scenario['toleranceCents'] ?? 100);
        } catch (e) {
          exportError = '$e';
        }
        final actual = <String, dynamic>{
          'groups': groups.length,
          'matched':
              groups.where((g) => g['suggestionComplete'] == true).length,
          'duplicatePayments': (imported['duplicatePayments'] as List).length,
          'duplicateInvoices': imported['duplicateInvoices'],
          'unmatchedPayments': (imported['unmatchedPayments'] as List).length,
          'unmatchedMaterials': (imported['unmatchedMaterials'] as List).length,
          'exportReady': exportManifest != null,
          'totalCents': exportManifest?['grandTotals']?['reimbursementCents'],
          'assignments': assignments,
          'tripCounts': {
            for (final g in groups.where((g) => g['paperTaxi'] != true))
              assetId(g): (g['trips'] as List).length
          },
          'hotelSame': {
            for (final g in groups.where((g) => g['category'] == 'hotel'))
              assetId(g): HotelCheck(g).same
          },
        };
        check('case:$id', scenario['title'] ?? id,
            Map<String, dynamic>.from(scenario['expected']), actual);
        actuals['case:$id'] = {
          'actual': actual,
          'exportError': exportError,
          'groups': groups,
          'issues': imported['issues']
        };
      } catch (e) {
        results.add({
          'id': 'case:$id',
          'title': scenario['title'],
          'passed': false,
          'error': '$e'
        });
      }
    }
    // 重新计算源样本摘要，检测测试过程中原件是否被改写。
    for (final e in paths.entries) {
      final hash =
          (await sha256.bind(File(e.value).openRead()).first).toString();
      if (hash != hashes[e.key]) throw StateError('测试过程中源材料发生变化：${e.key}');
    }
  } catch (e, stack) {
    results.add({
      'id': 'dataset:setup',
      'title': '数据集完整性与执行环境',
      'passed': false,
      'error': '$e',
      'stack': '$stack'
    });
  } finally {
    await engine?.close();
    final failed = results.where((r) => r['passed'] != true).length;
    final report = {
      'metadata': metadata,
      'completedAt': DateTime.now().toIso8601String(),
      'total': results.length,
      'passed': results.length - failed,
      'failed': failed,
      'results': results
    };
    await File('${reports.path}/report.json')
        .writeAsString(const JsonEncoder.withIndent('  ').convert(report));
    await File('${reports.path}/actual.json')
        .writeAsString(const JsonEncoder.withIndent('  ').convert(actuals));
    final lines = <String>[
      '# 本地算法回归报告',
      '',
      '通过 ${results.length - failed} / ${results.length}，失败 $failed。',
      ''
    ];
    for (final r in results) {
      lines.add(
          '- ${r['passed'] == true ? '通过' : '失败'}：${r['id']} · ${r['title']}');
      if (r['error'] != null) lines.add('  - ${r['error']}');
      for (final d in r['differences'] as List? ?? []) {
        lines.add(
            '  - ${d['field']}：预期 `${jsonEncode(d['expected'])}`；实际 `${jsonEncode(d['actual'])}`');
      }
    }
    await File('${reports.path}/report.md').writeAsString(lines.join('\n'));
    stdout.writeln(
        '结果 ${results.length - failed}/${results.length}；报告：${reports.path}');
    await sandbox.delete(recursive: true);
    if (failed > 0) exitCode = 1;
  }
}
