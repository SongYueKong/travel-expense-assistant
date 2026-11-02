import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'hotel_check.dart';
import 'trip_dates.dart';

/// 文件夹内的 JSON 是完整记录；运行时展开相对路径，兼容现有识别与预览。
class TripFolderStorage {
  final Directory root;
  final Map<String, Directory> locations = {};
  TripFolderStorage(this.root);
  static const recordName = '差旅记录.json';
  static const buckets = ['发票', '行程单', '支付截图', '情况说明', '其他材料', '导出文件'];
  File get marker => File('${root.path}/.storage-ready');
  String safe(String value) {
    var result = value
        .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1f]'), '_')
        .replaceAll(RegExp(r'[. ]+$'), '')
        .trim();
    if (result.length > 70) result = result.substring(0, 70);
    return result.isEmpty ? '差旅' : result;
  }

  String folderName(Map<String, dynamic> task) {
    final id = task['id'].toString();
    if (!RegExp(r'^[A-Za-z0-9_-]{1,80}$').hasMatch(id)) {
      throw const FormatException('差旅编号不适合作为文件夹标识');
    }
    final period = TripPeriod.fromTask(task);
    var name = task['name'].toString();
    if (period != null) name = name.replaceAll('（${period.label}）', '');
    var label = safe(name);
    if (label.length > 40) label = label.substring(0, 40);
    final dates = period == null
        ? ''
        : '_${tripDate(period.start)}至${tripDate(period.end)}';
    return '$label${dates}_${id.length > 8 ? id.substring(0, 8) : id}';
  }

  bool inside(String value, String parent) {
    String norm(String s) => File(s)
        .absolute
        .path
        .replaceAll('\\', '/')
        .toLowerCase()
        .replaceAll(RegExp(r'/+$'), '');
    return norm(value).startsWith('${norm(parent)}/');
  }

  String directoryKey(String path) {
    final value = Directory(path)
        .absolute
        .uri
        .normalizePath()
        .toFilePath()
        .replaceAll('\\', '/')
        .replaceAll(RegExp(r'/+$'), '');
    return Platform.isWindows ? value.toLowerCase() : value;
  }

  Future<bool> sameDirectory(Directory a, Directory b) async {
    if (directoryKey(a.path) == directoryKey(b.path)) return true;
    return await a.exists() &&
        await b.exists() &&
        await FileSystemEntity.identical(a.path, b.path);
  }

  bool relativeMaterial(String value) =>
      buckets.any((b) => value.startsWith('$b/'));
  void bindProofs(Map<String, dynamic> task, Map<int, bool> valid) {
    final groups = (task['groups'] as List? ?? []).cast<Map<String, dynamic>>();
    for (final entry in valid.entries) {
      if (entry.value &&
          groups[entry.key]['hotelVerification']?['proof'] is Map) {
        groups[entry.key]['hotelVerification']['proof']['basis'] =
            HotelCheck(groups[entry.key]).basis;
      }
    }
  }

  dynamic transform(dynamic value, String Function(String) convert) {
    if (value is String) return convert(value);
    if (value is List) return [for (final v in value) transform(v, convert)];
    if (value is Map) {
      return {
        for (final e in value.entries)
          convert(e.key.toString()): transform(e.value, convert)
      };
    }
    return value;
  }

  Future<List<Map<String, dynamic>>> readAll() async {
    await root.create(recursive: true);
    locations.clear();
    final records = <Map<String, dynamic>>[];
    await for (final entity in root.list(followLinks: false)) {
      if (entity is! Directory ||
          entity.path.replaceAll('\\', '/').split('/').last.startsWith('.')) {
        continue;
      }
      final file = File('${entity.path}/$recordName');
      if (!await file.exists()) continue;
      final envelope =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      if (envelope['formatVersion'] != 1 || envelope['task'] is! Map) {
        throw FormatException('差旅记录格式不支持：${file.path}');
      }
      final raw = Map<String, dynamic>.from(envelope['task']);
      final id = raw['id'] as String;
      final valid = {
        for (var i = 0; i < (raw['groups'] as List? ?? []).length; i++)
          if (raw['groups'][i]['category'] == 'hotel')
            i: HotelCheck(Map<String, dynamic>.from(raw['groups'][i])).resolved
      };
      if (locations.containsKey(id)) {
        throw FormatException('发现重复差旅编号，请移走重复文件夹：$id');
      }
      final task = Map<String, dynamic>.from(transform(raw, (s) {
        if (!relativeMaterial(s)) return s;
        if (s.split('/').any((p) => p == '..' || p == '.')) {
          throw FormatException('材料相对路径无效：$s');
        }
        return File('${entity.path}/$s').absolute.path;
      }));
      bindProofs(task, valid);
      locations[id] = entity;
      task['taskDirectory'] = entity.absolute.path;
      records.add(task);
    }
    return records;
  }

  Future<String> digest(File file) async =>
      (await sha256.bind(file.openRead()).first).toString();
  Future<Map<String, dynamic>> save(Map<String, dynamic> source) async {
    final task = jsonDecode(jsonEncode(source)) as Map<String, dynamic>;
    task.remove('taskDirectory');
    final id = task['id'] as String;
    final old = locations[id];
    final destination = Directory('${root.path}/${folderName(task)}').absolute;
    if (!inside(destination.path, root.path)) throw StateError('差旅目录超出保存范围');
    bool moved = false;
    final previousProofs = <int, bool>{};
    final groups = (task['groups'] as List? ?? []).cast<Map<String, dynamic>>();
    for (var i = 0; i < groups.length; i++) {
      if (groups[i]['category'] == 'hotel') {
        previousProofs[i] = HotelCheck(groups[i]).resolved;
      }
    }
    try {
      if (old == null && await destination.exists()) {
        throw StateError('目标差旅文件夹已存在，未覆盖已有记录：${destination.path}');
      }
      if (old != null && !await sameDirectory(old, destination)) {
        if (await destination.exists()) {
          throw StateError('目标差旅文件夹已存在：${destination.path}');
        }
        if (!inside(old.path, root.path)) throw StateError('原差旅目录超出保存范围');
        await old.rename(destination.path);
        moved = true;
        final rewritten = Map<String, dynamic>.from(transform(
            task,
            (s) => inside(s, old.path)
                ? '${destination.path}${File(s).absolute.path.substring(old.absolute.path.length)}'
                : s));
        task
          ..clear()
          ..addAll(rewritten);
      }
      await destination.create(recursive: true);
      for (final bucket in buckets) {
        await Directory('${destination.path}/$bucket').create();
      }
      final mapping = <String, String>{};
      final copied = <String, String>{};
      Future<void> copy(String path, String bucket, Map metadata) async {
        final source = File(path).absolute;
        final key = source.path;
        if (mapping.containsKey(key)) return;
        if (!await source.exists()) {
          if (metadata['failedInspection'] == true) {
            metadata['missingSourcePath'] = path;
            mapping[key] =
                '${destination.path}/其他材料/缺失_${safe(source.uri.pathSegments.last)}';
            return;
          }
          throw FileSystemException('材料不存在，未切换保存方式', path);
        }
        if (inside(source.path, destination.path)) {
          mapping[key] = source.path;
          return;
        }
        final hash = await digest(source);
        if (copied.containsKey(hash)) {
          mapping[key] = copied[hash]!;
          return;
        }
        final original =
            (metadata['name'] ?? source.uri.pathSegments.last).toString();
        final sourceName = source.uri.pathSegments.last;
        final dot = sourceName.lastIndexOf('.');
        final ext = dot < 0 ? '' : sourceName.substring(dot).toLowerCase();
        var label = safe(original.replaceFirst(RegExp(r'\.[^.]+$'), ''));
        if (label.length > 35) label = label.substring(0, 35);
        final target = File(
            '${destination.path}/$bucket/${label}_${hash.substring(0, 20)}$ext');
        if (await target.exists()) {
          if (await digest(target) != hash) {
            throw StateError('材料文件名冲突：${target.path}');
          }
        } else {
          final staged = File('${target.path}.incoming');
          await source.copy(staged.path);
          if (await digest(staged) != hash) throw StateError('材料复制校验失败：$path');
          await staged.rename(target.path);
        }
        copied[hash] = target.path;
        mapping[key] = target.path;
      }

      Future<void> collect(dynamic value, String bucket) async {
        if (value is List) {
          for (final item in value) {
            await collect(item, bucket);
          }
          return;
        }
        if (value is Map) {
          final doc = value['document'];
          var role = bucket;
          if (doc is Map &&
              doc['type'] == 'invoice' &&
              !['情况说明', '导出文件'].contains(bucket)) {
            role = '发票';
          }
          if (doc is Map &&
              doc['type'] == 'itinerary' &&
              !['情况说明', '导出文件'].contains(bucket)) {
            role = '行程单';
          }
          for (final entry in value.entries) {
            var child = role;
            if (['payments', 'unmatchedPayments'].contains(entry.key)) {
              child = '支付截图';
            }
            if (['itineraries', 'itineraryMaterials'].contains(entry.key)) {
              child = '行程单';
            }
            if (entry.key == 'proof') child = '情况说明';
            if (entry.key == 'exports') child = '导出文件';
            if (entry.key == 'itineraries' && entry.value is List) {
              for (final path in entry.value) {
                await copy(path as String, '行程单', {});
              }
            } else if (entry.key == 'path' && entry.value is String) {
              await copy(entry.value, role, value);
            } else {
              await collect(entry.value, child);
            }
          }
        }
      }

      // 先收集费用组，保证台账及邮件来源中的同一路径复用相同副本。
      await collect(task['groups'], '发票');
      await collect(task, '其他材料');
      final localized = Map<String, dynamic>.from(transform(
          task, (s) => mapping[s] ?? mapping[File(s).absolute.path] ?? s));
      bindProofs(localized, previousProofs);
      final relative = Map<String, dynamic>.from(transform(
          localized,
          (s) => inside(s, destination.path)
              ? File(s)
                  .absolute
                  .path
                  .substring(destination.path.length + 1)
                  .replaceAll('\\', '/')
              : s));
      bindProofs(relative, previousProofs);
      final record = File('${destination.path}/$recordName');
      final staged = File('${record.path}.new');
      await staged.writeAsString(
          const JsonEncoder.withIndent('  ')
              .convert({'formatVersion': 1, 'task': relative}),
          flush: true);
      await staged.rename(record.path);
      locations[id] = destination;
      localized['taskDirectory'] = destination.path;
      return localized;
    } catch (e) {
      if (moved && old != null && await destination.exists()) {
        await destination.rename(old.path);
      }
      rethrow;
    }
  }

  Future<Directory?> trash(String id) async {
    final directory = locations[id];
    if (directory == null) return null;
    if (!inside(directory.path, root.path)) throw StateError('目录超出差旅范围');
    final trash = Directory('${root.path}/.回收站');
    await trash.create(recursive: true);
    final target = Directory(
        '${trash.path}/${DateTime.now().microsecondsSinceEpoch}_${directory.uri.pathSegments.where((s) => s.isNotEmpty).last}');
    await directory.rename(target.path);
    locations.remove(id);
    return target;
  }

  Future<void> restoreTrash(
      String id, Directory trashed, Directory original) async {
    if (!inside(trashed.path, '${root.path}/.回收站') ||
        !inside(original.path, root.path)) {
      throw StateError('恢复目录超出保存范围');
    }
    await trashed.rename(original.path);
    locations[id] = original;
  }
}
