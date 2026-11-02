import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'task_rules.dart';
import 'app_preferences.dart';
import 'payment_layout.dart';
import 'trip_dates.dart';
import 'meal_allowance.dart';
import 'trip_folder_storage.dart';
import 'package:sqlite3/sqlite3.dart' as native;

class TaskStore extends GeneratedDatabase implements MailboxPreferences {
  final File databaseFile;
  final TripFolderStorage? folders;
  Future<void>? _foldersInitialization;
  TaskStore(File file, {Directory? tripDirectory})
      : databaseFile = file,
        folders =
            tripDirectory == null ? null : TripFolderStorage(tripDirectory),
        super(NativeDatabase(file));
  Future<void> _ensureFolders() async {
    if (folders == null) return;
    await (_foldersInitialization ??= _initializeFolders());
  }

  Future<void> _initializeFolders() async {
    final storage = folders!;
    final legacy = await _readIndex();
    final migrating = !await storage.marker.exists();
    if (migrating && legacy.isNotEmpty) {
      final backupDir =
          Directory('${databaseFile.parent.path}/folder-migration-backups');
      await backupDir.create(recursive: true);
      final source = native.sqlite3
          .open(databaseFile.path, mode: native.OpenMode.readOnly);
      final backup = native.sqlite3.open(
          '${backupDir.path}/travel-${DateTime.now().microsecondsSinceEpoch}.sqlite');
      try {
        await source.backup(backup).drain<void>();
      } finally {
        source.close();
        backup.close();
      }
    }
    var stored = await storage.readAll();
    if (migrating) {
      final ids = stored.map((t) => t['id']).toSet();
      for (final task in legacy) {
        if (!ids.contains(task['id'])) await storage.save(task);
      }
      stored = await storage.readAll();
    }
    // JSON为完整记录，数据库仅维护可重建列表索引和全局设置。
    await transaction(() async {
      await customStatement('DELETE FROM tasks');
      for (final task in stored) {
        await _writeIndex(task);
      }
    });
    if (migrating) await storage.marker.writeAsString('1', flush: true);
  }

  @override
  int get schemaVersion => 2;
  @override
  Iterable<TableInfo<Table, Object?>> get allTables => const [];
  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (_) async {
          await customStatement(
            'CREATE TABLE tasks (id TEXT PRIMARY KEY, name TEXT NOT NULL, body TEXT NOT NULL)',
          );
          await _createSettings();
        },
        onUpgrade: (_, from, to) async {
          if (from < 2) await _createSettings();
        },
      );
  Future<void> _createSettings() => customStatement(
      'CREATE TABLE IF NOT EXISTS app_settings (key TEXT PRIMARY KEY, value TEXT NOT NULL)');
  @override
  Future<MailboxIdentity?> loadDefaultMailbox() async {
    final rows = await customSelect(
            "SELECT value FROM app_settings WHERE key = 'default_mailbox'")
        .get();
    if (rows.isEmpty) return null;
    try {
      final value = jsonDecode(rows.single.read<String>('value'));
      if (value is! Map) return null;
      return MailboxIdentity.fromJson(Map<String, dynamic>.from(value));
    } on FormatException {
      return null;
    }
  }

  @override
  Future<void> saveDefaultMailbox(MailboxIdentity mailbox) => customStatement(
      'INSERT INTO app_settings(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value',
      ['default_mailbox', jsonEncode(mailbox.toJson())]);

  Future<PaymentLayout> loadPaymentLayout() async {
    final rows = await customSelect(
            "SELECT value FROM app_settings WHERE key = 'payment_layout'")
        .get();
    if (rows.isEmpty) return const PaymentLayout.defaults();
    try {
      final value = jsonDecode(rows.single.read<String>('value'));
      if (value is Map<String, dynamic>) return PaymentLayout.fromJson(value);
    } on FormatException {
      // 缺失或损坏的本机偏好不影响原有差旅的打开。
    }
    return const PaymentLayout.defaults();
  }

  Future<void> savePaymentLayout(PaymentLayout layout) => customStatement(
      'INSERT INTO app_settings(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value',
      ['payment_layout', jsonEncode(layout.toJson())]);
  Future<List<Map<String, dynamic>>> _readIndex() async =>
      (await customSelect('SELECT body FROM tasks ORDER BY rowid DESC').get())
          .map(
            (r) => jsonDecode(r.read<String>('body')) as Map<String, dynamic>,
          )
          .toList();
  Future<List<Map<String, dynamic>>> load() async {
    await _ensureFolders();
    return _readIndex();
  }

  Future<void> _writeIndex(Map<String, dynamic> task) => customStatement(
        'INSERT INTO tasks(id,name,body) VALUES(?,?,?) ON CONFLICT(id) DO UPDATE SET name=excluded.name,body=excluded.body',
        [task['id'], task['name'], jsonEncode(task)],
      );
  Future<void> save(Map<String, dynamic> task) async {
    await _ensureFolders();
    final previous = folders == null
        ? null
        : (await _readIndex()).where((t) => t['id'] == task['id']).firstOrNull;
    final localized = folders == null ? task : await folders!.save(task);
    try {
      await _writeIndex(localized);
    } catch (e) {
      if (folders != null) {
        if (previous != null) {
          await folders!.save(previous);
        } else {
          await folders!.trash(task['id']);
        }
      }
      rethrow;
    }
    if (folders != null) {
      task
        ..clear()
        ..addAll(localized);
    }
  }

  Future<String?> taskDirectory(Map<String, dynamic> task) async {
    await _ensureFolders();
    final existing = folders?.locations[task['id']];
    if (folders != null && (existing == null || !await existing.exists())) {
      await folders!.readAll();
    }
    return folders?.locations[task['id']]?.absolute.path;
  }

  Future<void> recordExport(Map<String, dynamic> task, String path) async {
    if (folders == null) return;
    final updated = jsonDecode(jsonEncode(task)) as TripTask;
    updated['exports'] = [
      ...(updated['exports'] as List? ?? []),
      {
        'path': path,
        'name': File(path).uri.pathSegments.last,
        'exportedAt': DateTime.now().toIso8601String()
      }
    ];
    await save(updated);
    task
      ..clear()
      ..addAll(updated);
  }

  Future<TripTask> _taskById(String id) async {
    await _ensureFolders();
    final rows = await customSelect('SELECT body FROM tasks WHERE id = ?',
        variables: [Variable.withString(id)]).get();
    if (rows.isEmpty) throw StateError('此差旅任务已不存在，请刷新列表');
    return jsonDecode(rows.single.read<String>('body')) as TripTask;
  }

  Future<TripTask> createTask(String value, {TripPeriod? period}) =>
      transaction(() async {
        final name =
            period == null ? validateTaskName(value) : period.taskName(value);
        requireAvailableTaskName(name, await load());
        final task = <String, dynamic>{
          'id': newTaskId(),
          'name': name,
          if (period != null) ...period.toJson(),
          if (period != null) 'mealDailyRateCents': defaultMealDailyRateCents,
          if (period != null) 'mealAllowanceEnabled': true,
          'createdAt': DateTime.now().toIso8601String(),
          'toleranceCents': 100,
          'groups': <dynamic>[]
        };
        await save(task);
        return task;
      });

  Future<TripTask> renameTask(String id, String value) => transaction(() async {
        final name = validateTaskName(value), task = await _taskById(id);
        if (task['name'] != name) {
          requireAvailableTaskName(name, await load(), exceptId: id);
        }
        task['name'] = name;
        await save(task);
        return task;
      });

  Future<TripTask> updateTripSettings(String id, TripSettingsChange change) =>
      transaction(() async {
        final updated = applyTripSettings(await _taskById(id),
            baseName: change.baseName,
            period: change.period,
            dailyRateCents: change.dailyRateCents,
            mealEnabled: change.mealEnabled);
        requireAvailableTaskName(updated['name'], await load(), exceptId: id);
        await save(updated);
        return updated;
      });

  Future<TripTask> copyTask(String id, String value) => transaction(() async {
        final name = validateTaskName(value);
        requireAvailableTaskName(name, await load());
        final copy = duplicateTask(await _taskById(id), name);
        await save(copy);
        return copy;
      });

  Future<void> deleteTask(String id) => transaction(() async {
        await _taskById(id);
        final original = folders?.locations[id];
        final trashed = await folders?.trash(id);
        try {
          await customStatement('DELETE FROM tasks WHERE id = ?', [id]);
        } catch (e) {
          if (trashed != null && original != null) {
            await folders!.restoreTrash(id, trashed, original);
          }
          rethrow;
        }
      });
}

abstract interface class ProcessingClient {
  Future<dynamic> call(String method, Map<String, dynamic> params);
}

class EngineClient implements ProcessingClient {
  final Process process;
  final Map<int, Completer<dynamic>> _requests = {};
  final List<String> errors = [];
  int _nextId = 0;
  EngineClient._(this.process) {
    process.stdin.encoding = utf8;
    process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
      try {
        final data = jsonDecode(line) as Map<String, dynamic>;
        final pending = _requests.remove(data['id']);
        if (data['error'] != null) {
          pending?.completeError(StateError(data['error']['message']));
        } else {
          pending?.complete(data['result']);
        }
      } catch (_) {
        errors.add('处理引擎返回了无法解析的数据');
      }
    });
    process.stderr.transform(utf8.decoder).listen(errors.add);
    process.exitCode.then((code) {
      for (final pending in _requests.values) {
        pending.completeError(StateError('本地处理引擎已退出（$code）'));
      }
      _requests.clear();
    });
  }
  static Future<EngineClient> start(String root, {String? engineRoot}) async {
    final code = engineRoot ?? root;
    final bundled = File('$code/runtime/python/python.exe');
    final python = await bundled.exists()
        ? bundled.path
        : '$code${Platform.pathSeparator}.venv${Platform.pathSeparator}Scripts${Platform.pathSeparator}python.exe';
    final process = await Process.start(
        python,
        [
          '-B',
          '-E',
          '-s',
          '-X',
          'utf8',
          '$code/engine/worker.py',
        ],
        environment: {
          'TRAVEL_ASSISTANT_DATA_DIR': Directory(root).absolute.path
        },
        runInShell: false);
    final client = EngineClient._(process);
    try {
      await client.call('ping', {});
    } catch (e) {
      await client.close();
      rethrow;
    }
    return client;
  }

  @override
  Future<dynamic> call(String method, Map<String, dynamic> params) async {
    final id = ++_nextId;
    final completer = Completer<dynamic>();
    _requests[id] = completer;
    process.stdin.writeln(
      jsonEncode({'id': id, 'method': method, 'params': params}),
    );
    try {
      return await completer.future.timeout(const Duration(minutes: 3));
    } finally {
      _requests.remove(id);
    }
  }

  Future<void> close() async {
    await process.stdin.close();
    process.kill();
  }
}
