import 'dart:io';

import 'package:flutter/material.dart';
import 'package:file_selector/file_selector.dart';
import 'package:travel_core/travel_core.dart';

import 'services.dart';
import 'import_service.dart';
import 'export_service.dart';
import 'mail_dialog.dart';
import 'material_merge_service.dart';
import 'association_dialog.dart';
import 'association_service.dart';
import 'pdf_catalog.dart';
import 'pdf_library_dialog.dart';
import 'task_management.dart';
import 'task_rules.dart';
import 'matching_helpers.dart';
import 'reconciliation_service.dart';
import 'time_matching_dialog.dart';
import 'pending_service.dart';
import 'pending_dialog.dart';
import 'payment_identity.dart';
import 'app_preferences.dart';
import 'trip_actions.dart';
import 'trip_dates.dart';
import 'create_trip_dialog.dart';
import 'meal_allowance.dart';
import 'trip_settings_dialog.dart';
import 'app_localizations.dart';
import 'runtime_paths.dart';
import 'open_folder.dart';
import 'hotel_check.dart';
import 'hotel_check_dialog.dart';
import 'taxi_dialog.dart';
import 'payment_layout.dart';
import 'payment_layout_dialog.dart';
import 'exported_pdf_dialog.dart';
import 'open_pdf.dart';

final runtimePaths = RuntimePaths.resolve();
String get projectRoot => runtimePaths.workspaceRoot;
void main(List<String> arguments) async {
  WidgetsFlutterBinding.ensureInitialized();
  if (arguments.contains('--portable-self-test')) {
    // 自检必须显式使用隔离目录，开发版也不能写入正式项目数据。
    final testRoot = Platform.environment['TRAVEL_ASSISTANT_DATA_DIR'];
    String normalized(String path) => Directory(path)
        .absolute
        .path
        .replaceAll('\\', '/')
        .toLowerCase()
        .replaceAll(RegExp(r'/+$'), '');
    if (testRoot == null ||
        testRoot.isEmpty ||
        (runtimePaths.development &&
            normalized(testRoot) == normalized(projectRoot))) {
      stderr.writeln('启动自检必须指定独立的 TRAVEL_ASSISTANT_DATA_DIR');
      exit(2);
    }
    final report = File('$testRoot/self-test.txt');
    EngineClient? client;
    TaskStore? database;
    try {
      await report.parent.create(recursive: true);
      client = await EngineClient.start(testRoot,
          engineRoot: runtimePaths.engineRoot);
      final ping = await client.call('ping', {});
      database = TaskStore(File('$testRoot/.local/travel.sqlite'),
          tripDirectory: Directory('$testRoot/差旅记录'));
      await database.databaseFile.parent.create(recursive: true);
      await database.load();
      final task = await database.createTask('免安装启动自检');
      if (!(await database.load()).any((saved) => saved['id'] == task['id'])) {
        throw StateError('启动自检未能读回保存的测试记录');
      }
      await database.close();
      database = TaskStore(File('$testRoot/.local/travel.sqlite'),
          tripDirectory: Directory('$testRoot/差旅记录'));
      final reopened = (await database.load())
          .singleWhere((saved) => saved['id'] == task['id']);
      await database.save(reopened);
      await report.writeAsString('OK\n$ping\n${task['taskDirectory']}');
      exitCode = 0;
    } catch (e) {
      await report.writeAsString('FAILED\n$e');
      exitCode = 1;
    } finally {
      await client?.close();
      await database?.close();
    }
    exit(exitCode);
  }
  runApp(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      title: '差旅报账助手',
      locale: appLocale,
      supportedLocales: appSupportedLocales,
      localizationsDelegates: appLocalizationDelegates,
      theme: ThemeData(
        useMaterial3: true,
        fontFamily: Platform.isWindows ? 'Segoe UI' : null,
        fontFamilyFallback: Platform.isWindows
            ? const ['Microsoft YaHei UI', 'Microsoft YaHei']
            : null,
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xff176b60)),
        scaffoldBackgroundColor: const Color(0xfff4f6f8),
      ),
      home: const Workspace(),
    ),
  );
}

class Workspace extends StatefulWidget {
  const Workspace({super.key});
  @override
  State<Workspace> createState() => _WorkspaceState();
}

class _WorkspaceState extends State<Workspace> {
  TaskStore? store;
  EngineClient? engine;
  List<Map<String, dynamic>> tasks = [];
  Map<String, dynamic>? task;
  PaymentLayout paymentLayout = const PaymentLayout.defaults();
  final Map<String, Map<String, dynamic>> recentExports = {};
  bool busy = true;
  String? error;
  String status = '正在打开本地工作空间';
  @override
  void initState() {
    super.initState();
    initialize();
  }

  Future<void> initialize() async {
    try {
      await Directory('$projectRoot/.local').create(recursive: true);
      store = TaskStore(File('$projectRoot/.local/travel.sqlite'),
          tripDirectory: Directory('$projectRoot/差旅记录'));
      tasks = await store!.load();
      paymentLayout = await store!.loadPaymentLayout();
      if (await store!.loadDefaultMailbox() == null) {
        final previous = mostRecentMailbox(tasks);
        if (previous != null) await store!.saveDefaultMailbox(previous);
      }
      engine = await EngineClient.start(projectRoot,
          engineRoot: runtimePaths.engineRoot);
      if (tasks.isNotEmpty) task = tasks.first;
      status = '本地工作空间已就绪';
    } catch (e) {
      error = '$e';
    }
    if (mounted) setState(() => busy = false);
  }

  List<Map<String, dynamic>> get groups =>
      (task?['groups'] as List? ?? []).cast<Map<String, dynamic>>();
  List<PendingItem> get importProblems =>
      task == null ? [] : pendingItems(task!);

  Future<void> mergeMaterials(
      {List<Map<String, dynamic>> mailFiles = const [],
      String? paymentDirectory,
      Map<String, dynamic>? sourceTask,
      bool recalculateManual = false,
      Map<String, dynamic>? mailReport}) async {
    final changed =
        await MaterialMerger(engine!, '$projectRoot/.local/materials').merge(
            sourceTask ?? task!,
            mailFiles: mailFiles,
            paymentDirectory: paymentDirectory,
            recalculateManual: recalculateManual,
            onProgress: (done, total, name) {
      if (mounted) setState(() => status = '识别与匹配 $done/$total · $name');
    });
    if (mailReport != null) {
      changed['mailHistory'] = [
        ...(task!['mailHistory'] as List? ?? []),
        {
          'provider': mailReport['provider'],
          'account': mailReport['account'],
          'startDate': mailReport['startDate'],
          'endDate': mailReport['endDate'],
          'downloaded': mailReport['downloaded'],
          'duplicates': mailReport['duplicates'],
          'pending': mailReport['pending'],
          'failures': mailReport['failures'],
          'importedAt': DateTime.now().toIso8601String()
        }
      ];
    }
    await store!.save(changed);
    final index = tasks.indexWhere((t) => t['id'] == changed['id']);
    if (index >= 0) tasks[index] = changed;
    task = changed;
    status =
        '已更新 ${groups.length} 张发票，${(changed['unmatchedPayments'] as List).length} 笔支付未匹配；已复核项目保留，匹配完整即可导出';
    message(status);
  }

  Future<void> importMail() async {
    final previous = (task!['mailHistory'] as List? ?? []).lastOrNull;
    final selection = await showDialog<Map<String, dynamic>>(
        context: context,
        barrierDismissible: false,
        builder: (_) => MailImportDialog(
            engine: engine!,
            preferences: store!,
            tripPeriod: TripPeriod.fromTask(task!),
            previous:
                previous == null ? null : Map<String, dynamic>.from(previous)));
    if (selection == null || !mounted) return;
    await run(() async {
      final report = Map<String, dynamic>.from(selection['report']);
      await mergeMaterials(
          mailFiles: (report['files'] as List).cast<Map<String, dynamic>>(),
          paymentDirectory: selection['paymentDirectory'],
          mailReport: report);
    });
  }

  Future<void> supplementPayments() async {
    final directory = await getDirectoryPath(confirmButtonText: '添加支付截图');
    if (directory == null || !mounted) return;
    await run(() => mergeMaterials(paymentDirectory: directory));
  }

  Future<void> persistAssociationTask(Map<String, dynamic> updated) async {
    updated = cleanPending(updated);
    // 先写入成功，再替换界面状态；保存失败时保留原任务。
    await store!.save(updated);
    final index = tasks.indexWhere((t) => t['id'] == updated['id']);
    if (index != -1) tasks[index] = updated;
    task = updated;
  }

  Future<void> adjustAssociation(int index) async {
    final updated = await showDialog<Map<String, dynamic>>(
        context: context,
        barrierDismissible: false,
        builder: (_) => AssociationDialog(
            task: task!,
            groupIndex: index,
            loadDocumentPreview: loadDocumentPreview));
    if (updated == null || !mounted) return;
    await run(() async {
      await persistAssociationTask(updated);
      status = '关联已保存；匹配完整即可导出，人工复核可选';
      message(status);
    });
  }

  Future<void> checkHotel(int index) async {
    final source = task!;
    await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => HotelCheckDialog(
            group: groups[index],
            engine: engine!,
            materialDirectory: '$projectRoot/.local/materials',
            loadPreview: loadDocumentPreview,
            commit: (updated) async {
              final updatedGroups = [...groups];
              updatedGroups[index] = updated;
              await persistAssociationTask(
                  {...source, 'groups': updatedGroups});
              if (mounted) setState(() {});
            }));
  }

  Future<Map<String, dynamic>> loadDocumentPreview(
          String path, int page) async =>
      Map<String, dynamic>.from(await engine!.call('document.preview', {
        'path': path,
        'page_index': page,
        'preview_dir': '$projectRoot/.local/previews',
      }));

  Future<void> viewPdfLibrary() => showDialog<void>(
      context: context,
      builder: (_) =>
          PdfLibraryDialog(task: task!, loadPreview: loadDocumentPreview));

  Future<void> dataLocation() async {
    await showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
                title: const Text('数据保存位置'),
                content: SizedBox(
                    width: 620,
                    child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SelectableText(projectRoot),
                          const SizedBox(height: 12),
                          const Text(
                              '差旅记录、列表索引和邮箱设置保存在这里。更换位置后重启生效，旧数据仍保留在原处，不自动搬移。恢复已有数据时，请选择包含“差旅记录”和“.local”的父目录。'),
                          if (runtimePaths.development)
                            const Text('当前为开发版，固定使用项目目录；免安装版可自选数据位置。')
                        ])),
                actions: [
                  TextButton(
                      onPressed: () async {
                        try {
                          await openFolder(projectRoot);
                        } catch (e) {
                          message(e);
                        }
                      },
                      child: const Text('打开数据目录')),
                  if (!runtimePaths.development)
                    TextButton(
                        onPressed: () async {
                          final path = await getDirectoryPath(
                              initialDirectory: projectRoot,
                              confirmButtonText: '使用这个数据目录');
                          if (path == null || !mounted) return;
                          try {
                            await runtimePaths.selectWorkspace(path);
                            if (dialogContext.mounted) {
                              Navigator.pop(dialogContext);
                            }
                            message('数据位置已保存，请完全退出软件后重新打开；旧数据仍保留在原处');
                          } catch (e) {
                            message('数据位置保存失败：$e');
                          }
                        },
                        child: const Text('选择数据目录')),
                  TextButton(
                      onPressed: () => Navigator.pop(dialogContext),
                      child: const Text('关闭'))
                ]));
  }

  Future<void> viewPending() => showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => PendingIssuesDialog(
          task: task!,
          loadPreview: loadDocumentPreview,
          onSave: (updated) async {
            await persistAssociationTask(updated);
            if (mounted) setState(() {});
          },
          onRetry: (source) =>
              MaterialMerger(engine!, '$projectRoot/.local/materials')
                  .merge(source),
          onResolve: resolvePending));

  Future<Map<String, dynamic>?> resolvePending(
      Map<String, dynamic> source, PendingItem item) async {
    if (item.material?['failedInspection'] == true) {
      return MaterialMerger(engine!, '$projectRoot/.local/materials')
          .merge(source);
    }
    final sourceGroups = records(source['groups']), m = item.material!;
    final index = await showDialog<int>(
        context: context,
        builder: (context) => AlertDialog(
                title: const Text('选择处理方式'),
                content: SizedBox(
                    width: 500,
                    height: 300,
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('材料：${m['name']}'),
                          const Text('选择对应发票，进入核对窗口；也可手工新建费用组。'),
                          Expanded(
                              child: sourceGroups.isEmpty
                                  ? const Center(child: Text('尚无发票费用组'))
                                  : ListView(children: [
                                      for (var i = 0;
                                          i < sourceGroups.length;
                                          i++)
                                        ListTile(
                                            title: Text(
                                                '${invoiceNumber(i + 1)} · ${sourceGroups[i]['name']}'),
                                            subtitle: Text(
                                                '发票 ¥${formatMoney(sourceGroups[i]['invoiceCents'])}'),
                                            onTap: () =>
                                                Navigator.pop(context, i)),
                                    ])),
                        ])),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('取消')),
                  FilledButton(
                      onPressed: () => Navigator.pop(context, -1),
                      child: const Text('手工新建费用组'))
                ]));
    if (index == null || !mounted) return null;
    if (index >= 0) {
      return showDialog<Map<String, dynamic>>(
          context: context,
          barrierDismissible: false,
          builder: (_) => AssociationDialog(
              task: source,
              groupIndex: index,
              loadDocumentPreview: loadDocumentPreview,
              focusMaterial: m));
    }
    final g = await showDialog<Map<String, dynamic>>(
        context: context,
        barrierDismissible: false,
        builder: (_) => AddGroup(
            engine: engine!,
            existingPictures: {
              for (final p in assignedMaterials(source).where(isScreenshot))
                p['path'] as String
            },
            existingPaymentMaterials:
                assignedMaterials(source).where(isScreenshot).toList(),
            initialMaterial: m,
            timeSettings: timeSettingsOf(source),
            toleranceCents: source['toleranceCents']));
    if (g == null) return null;
    if (sourceGroups.any((old) =>
        materialIdentities(old)
            .intersection(materialIdentities(g))
            .isNotEmpty ||
        (old['document']?['number'] != null &&
            old['document']?['number'] == g['document']?['number']))) {
      throw StateError('这张发票已有费用组，请选择该组调整关联');
    }
    return cleanPending({
      ...source,
      'groups': [...sourceGroups, g]
    });
  }

  Future<void> timeMatching() async {
    final selection = await showDialog<TimeRematchRequest>(
        context: context,
        builder: (_) => TimeMatchingDialog(settings: timeSettingsOf(task!)));
    if (selection == null || !mounted) return;
    await run(() => mergeMaterials(
        sourceTask: {...task!, 'timeMatching': selection.settings.toJson()},
        recalculateManual: selection.includeManual));
  }

  Future<void> save() async {
    task!['pdfMaterials'] = pdfCatalogMaterials(task!);
    await persistAssociationTask(task!);
    if (mounted) setState(() {});
  }

  void message(Object value, {VoidCallback? viewPdf}) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('$value'),
          action: viewPdf == null
              ? null
              : SnackBarAction(label: '查看 PDF', onPressed: viewPdf)));
    }
  }

  Future<void> run(Future<void> Function() action) async {
    setState(() => busy = true);
    try {
      await action();
    } catch (e) {
      message(e);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> newTask() async {
    final created = await showDialog<TripTask>(
        context: context,
        barrierDismissible: false,
        builder: (_) => CreateTripDialog(
            commit: (name, period) => store!.createTask(name, period: period)));
    if (created == null || !mounted) return;
    setState(() {
      tasks.insert(0, created);
      task = created;
      status = '已创建差旅报账，请选择邮箱接收日期导入材料';
    });
    await importMail();
  }

  Future<void> manageTask(TripTask target, TaskAction action) async {
    if (busy) return;
    final id = target['id'] as String;
    if (action == TaskAction.delete) {
      final deleted = await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (_) => DeleteTaskDialog(
              task: target, commit: () => store!.deleteTask(id)));
      if (deleted != true || !mounted) return;
      setState(() {
        tasks.removeWhere((t) => t['id'] == id);
        if (task?['id'] == id) task = tasks.firstOrNull;
        status = '已删除“${target['name']}”，对应文件夹已移入差旅记录的回收站';
      });
      message(status);
      return;
    }
    final copying = action == TaskAction.duplicate;
    final updated = await showDialog<TripTask>(
        context: context,
        barrierDismissible: false,
        builder: (_) => TaskNameDialog(
            title: copying ? '复制差旅报账' : '重命名差旅',
            initialName: copying
                ? suggestDuplicateName(target['name'], tasks)
                : target['name'],
            actionLabel: copying ? '复制' : '保存名称',
            description: copying ? '保留现有材料和匹配，清除人工复核标记；匹配完整即可直接导出。' : null,
            commit: (name) => copying
                ? store!.copyTask(id, name)
                : store!.renameTask(id, name)));
    if (updated == null || !mounted) return;
    setState(() {
      if (copying) {
        tasks.insert(0, updated);
        task = updated;
        status = '已复制差旅并清除人工复核标记；匹配完整即可导出';
      } else {
        final index = tasks.indexWhere((t) => t['id'] == id);
        if (index >= 0) tasks[index] = updated;
        if (task?['id'] == id) task = updated;
        status = '已重命名为“${updated['name']}”';
      }
    });
    message(status);
  }

  Future<void> tolerance() async {
    final value = TextEditingController(
      text: formatMoney(task!['toleranceCents']),
    );
    String? validation;
    final accepted = await showDialog<int>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, update) => AlertDialog(
          title: const Text('金额匹配容差'),
          content: TextField(
            controller: value,
            decoration: InputDecoration(
              labelText: '允许差额（元）',
              errorText: validation,
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () {
                try {
                  Navigator.pop(c, parseMoney(value.text));
                } catch (e) {
                  update(() => validation = '$e');
                }
              },
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
    if (accepted != null) {
      task!['toleranceCents'] = accepted;
      await save();
    }
    value.dispose();
  }

  Future<void> addTaxi() async {
    await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => TaxiDialog(commit: (cents, date) async {
              final record = newTaxiRecord(cents, date);
              await mergeMaterials(sourceTask: {
                ...task!,
                'groups': [...groups, record]
              });
              final saved =
                  groups.singleWhere((g) => g['hash'] == record['hash']);
              return saved['suggestionComplete'] == true
                  ? '已自动匹配支付截图'
                  : '已登记，待匹配支付截图';
            }));
  }

  Future<void> addGroup() async {
    final group = await showDialog<Map<String, dynamic>>(
      context: context,
      barrierDismissible: false,
      builder: (_) => AddGroup(
        engine: engine!,
        timeSettings: timeSettingsOf(task!),
        toleranceCents: task!['toleranceCents'],
        existingPictures: groups
            .expand((g) => g['payments'] as List)
            .map((p) => p['path'] as String)
            .toSet(),
        existingPaymentMaterials:
            groups.expand((g) => records(g['payments'])).toList(),
      ),
    );
    if (group != null) {
      await run(() async {
        if (groups.any((g) => g['hash'] == group['hash'])) {
          throw StateError('这张发票已经导入');
        }
        (task!['groups'] as List).add(group);
        await save();
      });
    }
  }

  Future<void> importFolder() async {
    if (!canImportFolder) {
      message('从本地文件夹导入需要空差旅；已有差旅可用“添加发票与支付”或“添加支付截图”。');
      return;
    }
    final directory = await getDirectoryPath(confirmButtonText: '导入这个文件夹');
    if (directory == null) return;
    await run(() async {
      final imported =
          await FolderImporter(engine!, '$projectRoot/.local/materials')
              .importDirectory(directory, task!['toleranceCents'],
                  excludedMaterials: records(task!['ignoredMaterials']),
                  timeSettings: timeSettingsOf(task!),
                  onProgress: (done, total, name) {
        if (mounted) setState(() => status = '识别 $done/$total · $name');
      });
      task!['groups'] = imported['groups'];
      task!['pdfMaterials'] = pdfCatalogMaterials({
        ...task!,
        'pdfMaterials': [
          ...(task!['pdfMaterials'] as List? ?? []),
          ...(imported['materials'] as List)
        ]
      });
      task!['importIssues'] = imported['issues'];
      task!['unmatchedPayments'] = imported['unmatchedPayments'];
      task!['unmatchedMaterials'] = imported['unmatchedMaterials'];
      task!['duplicatePayments'] = imported['duplicatePayments'];
      status =
          '导入 ${groups.length} 张发票，${(imported['unmatchedPayments'] as List).length} 笔支付未匹配，${(imported['issues'] as List).length} 项异常；匹配完整即可导出';
      await save();
      message(status);
    });
  }

  bool get canImportFolder =>
      task != null &&
      groups.isEmpty &&
      buildPdfCatalog(task!).isEmpty &&
      records(task!['unmatchedPayments']).isEmpty &&
      records(task!['unmatchedMaterials']).isEmpty;

  Future<void> moreAction(TripMoreAction action) async {
    switch (action) {
      case TripMoreAction.tripSettings:
        await tripSettings();
      case TripMoreAction.tolerance:
        await tolerance();
      case TripMoreAction.timeMatching:
        await timeMatching();
      case TripMoreAction.paymentLayout:
        await editPaymentLayout();
      case TripMoreAction.mailImport:
        await importMail();
      case TripMoreAction.localImport:
        await importFolder();
    }
  }

  Future<void> tripSettings() async {
    if (busy || task == null) return;
    final id = task!['id'] as String;
    final updated = await showDialog<Map<String, dynamic>>(
        context: context,
        builder: (_) => TripSettingsDialog(
            task: task!,
            commit: (change) => store!.updateTripSettings(id, change)));
    if (updated != null && mounted) {
      setState(() {
        final index = tasks.indexWhere((t) => t['id'] == id);
        if (index >= 0) tasks[index] = updated;
        if (task?['id'] == id) task = updated;
      });
    }
  }

  Future<void> editPaymentLayout() async {
    if (busy || store == null) return;
    final updated = await showDialog<PaymentLayout>(
        context: context,
        builder: (_) => PaymentLayoutDialog(
            initial: paymentLayout, commit: store!.savePaymentLayout));
    if (updated != null && mounted) {
      setState(() => paymentLayout = updated);
      message('已保存支付截图排版，后续导出自动沿用');
    }
  }

  Future<void> export() async {
    final exportingTask = task!;
    late final Map<String, dynamic> manifest;
    try {
      manifest = buildTaskExportManifest(task!);
    } catch (e) {
      message(e);
      return;
    }
    manifest['taskName'] = task!['name'];
    manifest['paymentLayout'] = paymentLayout.toJson();
    final location = await getSaveLocation(
      suggestedName: taskExportFilename(task!['name']),
      initialDirectory: await store!.taskDirectory(task!) == null
          ? null
          : '${await store!.taskDirectory(task!)}/导出文件',
      acceptedTypeGroups: [
        const XTypeGroup(label: 'PDF', extensions: ['pdf']),
      ],
    );
    if (location == null) return;
    await run(() async {
      final output = await engine!.call('export', {
        'manifest': manifest,
        'output': location.path,
      });
      String? archiveError;
      try {
        await store!.recordExport(exportingTask, location.path);
      } catch (e) {
        archiveError = '$e';
      }
      final history = exportedPdfFiles(exportingTask);
      recentExports[exportingTask['id']] =
          archiveError == null && history.isNotEmpty
              ? history.first
              : {
                  'path': location.path,
                  'name': File(location.path).uri.pathSegments.last
                };
      final files = exportedPdfFiles(exportingTask,
          recent: recentExports[exportingTask['id']]);
      status =
          '已导出 ${output['pages']} 页 · ${location.path}${archiveError == null ? '' : '；差旅文件夹归档失败：$archiveError'}';
      message(status, viewPdf: () => openExport(files.first['path']));
    });
  }

  Future<void> openExport(String path) async {
    try {
      await openPdfWithDefaultApp(path);
    } catch (e) {
      message(e);
    }
  }

  Future<void> showExports(List<Map<String, dynamic>> files) async {
    if (!mounted || files.isEmpty) return;
    if (files.length == 1) {
      await openExport(files.single['path']);
      return;
    }
    await showDialog<void>(
        context: context,
        builder: (_) =>
            ExportedPdfDialog(files: files, openFile: openPdfWithDefaultApp));
  }

  @override
  void dispose() {
    engine?.close();
    store?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final checks = assessGroups(groups, task?['toleranceCents'] ?? 100);
    final meal = task == null ? null : MealAllowance.fromTask(task!);
    final receiptTotal =
        reimbursementTotal(checks.map((c) => c.reconciliation));
    return Scaffold(
      appBar: AppBar(
        title: const Text('差旅报账助手'),
        actions: [
          TextButton.icon(
              onPressed: busy ? null : dataLocation,
              icon: const Icon(Icons.folder_outlined),
              label: const Text('数据位置')),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Center(child: Text(busy ? '正在处理…' : '本地工作空间')),
          ),
        ],
      ),
      body: error != null
          ? Center(child: SelectableText('启动失败\n$error'))
          : Row(
              children: [
                SizedBox(
                  width: 240,
                  child: Material(
                    color: Colors.white,
                    child: Column(
                      children: [
                        Padding(
                          padding: const EdgeInsets.all(20),
                          child: FilledButton.icon(
                            onPressed: busy ? null : newTask,
                            icon: const Icon(Icons.add),
                            label: const Text('新建差旅报账'),
                          ),
                        ),
                        ListTile(
                          title: Text(
                            '我的差旅（${tasks.length}）',
                            style: const TextStyle(fontWeight: FontWeight.bold),
                          ),
                        ),
                        Expanded(
                          child: ListView(
                            children: tasks
                                .map(
                                  (t) => TaskListTile(
                                      task: t,
                                      selected: t['id'] == task?['id'],
                                      busy: busy,
                                      onSelect: () => setState(() => task = t),
                                      onAction: (action) =>
                                          manageTask(t, action)),
                                )
                                .toList(),
                          ),
                        ),
                        const Padding(
                          padding: EdgeInsets.all(16),
                          child: Text(
                            '本地识别与核对\n国内常用邮箱导入\n开发者：松月空',
                            style: TextStyle(color: Colors.grey),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                Expanded(
                  child: task == null
                      ? const Center(child: Text('新建一次差旅，开始整理发票和支付凭证'))
                      : Padding(
                          padding: const EdgeInsets.all(24),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(children: [
                                Expanded(
                                    child: Text(task!['name'],
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                        style: Theme.of(context)
                                            .textTheme
                                            .headlineMedium)),
                                IconButton(
                                    tooltip: '打开差旅文件夹',
                                    onPressed: busy
                                        ? null
                                        : () async {
                                            try {
                                              final path = await store!
                                                  .taskDirectory(task!);
                                              if (path == null) {
                                                throw StateError(
                                                    '未找到当前差旅文件夹，请重新打开软件');
                                              }
                                              await openFolder(path);
                                            } catch (e) {
                                              message(e);
                                            }
                                          },
                                    icon:
                                        const Icon(Icons.folder_open_outlined)),
                                PopupMenuButton<TaskAction>(
                                    tooltip: '管理当前差旅',
                                    enabled: !busy,
                                    onSelected: (action) =>
                                        manageTask(task!, action),
                                    itemBuilder: (_) => taskMenuItems()),
                              ]),
                              const SizedBox(height: 8),
                              const Text(
                                '导入材料  →  日期时间与金额匹配  →  按组取较小金额  →  导出 PDF（人工复核可选）',
                              ),
                              const SizedBox(height: 20),
                              TripActionsBar(
                                  busy: busy,
                                  localImportAvailable: canImportFolder,
                                  pdfCount: buildPdfCatalog(task!).length,
                                  toleranceCents: task!['toleranceCents'],
                                  timeSettings: timeSettingsOf(task!),
                                  onPdf: viewPdfLibrary,
                                  onAddInvoice: addGroup,
                                  onAddTaxi: addTaxi,
                                  onAddPayments: supplementPayments,
                                  onExport: export,
                                  onViewExport: exportedPdfFiles(task!,
                                              recent:
                                                  recentExports[task!['id']])
                                          .isEmpty
                                      ? null
                                      : () => showExports(exportedPdfFiles(
                                          task!,
                                          recent: recentExports[task!['id']])),
                                  onMore: moreAction),
                              const SizedBox(height: 20),
                              Card(
                                child: Padding(
                                  padding: const EdgeInsets.all(20),
                                  child: Row(
                                    children: [
                                      Expanded(
                                        child: Text(
                                          '已核算费用合计  ¥ ${formatMoney(receiptTotal + (meal?.amountCents ?? 0))}',
                                          style: Theme.of(context)
                                              .textTheme
                                              .titleLarge,
                                        ),
                                      ),
                                      Flexible(
                                          child: Text(
                                              '票据 ¥${formatMoney(receiptTotal)} · 伙食补助 ¥${formatMoney(meal!.amountCents)}\n'
                                              '${groups.length} 张发票 · ${checks.where((c) => !c.ready).length} 组待匹配 · '
                                              '${groups.where((g) => g['confirmed'] == true).length} 组已复核',
                                              textAlign: TextAlign.right)),
                                    ],
                                  ),
                                ),
                              ),
                              const SizedBox(height: 12),
                              OutlinedButton.icon(
                                  onPressed: busy ? null : viewPending,
                                  icon: const Icon(Icons.fact_check_outlined),
                                  label: Text(
                                      '导入待处理事项（${importProblems.length} 项） · 查看／处理')),
                              Expanded(
                                child: ListView.builder(
                                  key: const ValueKey('expense-list'),
                                  itemCount: groups.length + 1,
                                  itemBuilder: (c, i) {
                                    if (i == groups.length) {
                                      return MealAllowanceCard(
                                          key: const ValueKey(
                                              'meal-allowance-card'),
                                          meal: meal,
                                          onSettings:
                                              busy ? null : tripSettings);
                                    }
                                    final g = groups[i],
                                        r = checks[i].reconciliation;
                                    final ps = g['payments'] as List;
                                    return Card(
                                      child: Padding(
                                        padding: const EdgeInsets.all(16),
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              '${invoiceNumber(i + 1)}  ${g['name']}',
                                              style: Theme.of(context)
                                                  .textTheme
                                                  .titleMedium,
                                            ),
                                            const SizedBox(height: 8),
                                            Text('类别：${{
                                                  'intercity': '城际交通',
                                                  'hotel': '酒店住宿',
                                                  'local': '市内交通'
                                                }[g['category']] ?? '待分类'} · ${g['paperTaxi'] == true ? '出租车纸票 · ${g['document']?['expenseDate'] ?? '日期未填写'}' : g['document']?['number'] ?? '票号待核对'}'),
                                            Text(
                                              '发票 ¥${formatMoney(r.invoiceCents)}   支付合计 ¥${formatMoney(r.allocatedNetPaymentCents)}   差额 ¥${formatMoney(r.difference)}',
                                            ),
                                            if (g['category'] == 'hotel')
                                              Text(
                                                  '收款单位核对：${HotelCheck(g).status}',
                                                  style: TextStyle(
                                                      color: HotelCheck(g)
                                                              .resolved
                                                          ? Colors.teal
                                                          : Colors.deepOrange)),
                                            Text(
                                              groupDiscountExplains(g)
                                                  ? '差额恰好等于截图优惠 · 按实付金额核算'
                                                  : r.withinTolerance
                                                      ? '金额差在容差内 · 请核实商户、日期及订单'
                                                      : '金额差超过容差 · 请核实原因',
                                              style: TextStyle(
                                                color: r.withinTolerance
                                                    ? Colors.teal
                                                    : Colors.deepOrange,
                                              ),
                                            ),
                                            Wrap(
                                              spacing: 12,
                                              children: [
                                                for (var j = 0;
                                                    j < ps.length;
                                                    j++)
                                                  Padding(
                                                    padding: const EdgeInsets
                                                        .symmetric(
                                                      vertical: 8,
                                                    ),
                                                    child: Column(
                                                      children: [
                                                        Image.file(
                                                          File(ps[j]['path']),
                                                          height: 130,
                                                          width: 75,
                                                          fit: BoxFit.contain,
                                                        ),
                                                        Text(
                                                          '${paymentNumber(i + 1, j + 1, ps.length)}  ¥${formatMoney(ps[j]['cents'])}',
                                                        ),
                                                      ],
                                                    ),
                                                  ),
                                              ],
                                            ),
                                            if ((g['trips'] as List? ?? [])
                                                .isNotEmpty)
                                              ExpansionTile(
                                                  title: Text(
                                                      '逐条行程核对（${(g['trips'] as List).length} 笔）'),
                                                  children: [
                                                    for (final trip
                                                        in g['trips'])
                                                      ListTile(
                                                        dense: true,
                                                        title: Text(
                                                            '${invoiceNumber(i + 1)}-${trip['index'].toString().padLeft(2, '0')}   ${trip['date']} ${trip['time']}   行程 ¥${formatMoney(trip['cents'])}'),
                                                        subtitle: Text(
                                                            '已建议关联 ${(ps.where((p) => p['tripIndex'] == trip['index'])).length} 笔支付；请核实时间和路线'),
                                                      )
                                                  ]),
                                            if ((g['matchingReasons']
                                                        as List? ??
                                                    [])
                                                .isNotEmpty)
                                              Text(
                                                  (g['matchingReasons'] as List)
                                                      .toSet()
                                                      .join('；'),
                                                  style: const TextStyle(
                                                      color: Colors.blueGrey)),
                                            if (g['mailSource'] != null)
                                              ExpansionTile(
                                                  title: const Text('查看邮件来源'),
                                                  children: [
                                                    ListTile(
                                                      title: Text(
                                                          g['mailSource']
                                                                  ['subject'] ??
                                                              ''),
                                                      subtitle: Text(
                                                          '发件人：${g['mailSource']['sender'] ?? ''}\n邮箱：${g['mailSource']['account']}\n接收时间：${g['mailSource']['receivedAt']}\n文件夹：${g['mailSource']['folder']} · 邮件编号：${g['mailSource']['uid']}'),
                                                    )
                                                  ]),
                                            Wrap(
                                              crossAxisAlignment:
                                                  WrapCrossAlignment.center,
                                              children: [
                                                if (g['category'] == 'hotel')
                                                  OutlinedButton.icon(
                                                      onPressed: busy
                                                          ? null
                                                          : () => checkHotel(i),
                                                      icon: const Icon(
                                                          Icons.business),
                                                      label: const Text(
                                                          '收款单位／情况说明')),
                                                OutlinedButton.icon(
                                                  onPressed: busy
                                                      ? null
                                                      : () =>
                                                          adjustAssociation(i),
                                                  icon: const Icon(Icons.rule),
                                                  label: const Text('选择／调整关联'),
                                                ),
                                                const SizedBox(width: 12),
                                                FilledButton.tonal(
                                                  onPressed: busy ||
                                                          (!checks[i].ready &&
                                                              g['confirmed'] !=
                                                                  true)
                                                      ? null
                                                      : () async {
                                                          g['confirmed'] =
                                                              !(g['confirmed'] ==
                                                                  true);
                                                          await save();
                                                        },
                                                  child: Text(
                                                    g['confirmed'] == true
                                                        ? '撤销复核'
                                                        : '标记已复核（可选）',
                                                  ),
                                                ),
                                                const SizedBox(width: 16),
                                                Text(
                                                  r.included
                                                      ? '计入 ¥${formatMoney(r.reimbursementCents!)}'
                                                      : '待匹配，暂不计入',
                                                ),
                                                IconButton(
                                                  onPressed: busy
                                                      ? null
                                                      : () async {
                                                          await run(() =>
                                                              persistAssociationTask(
                                                                  removeAssociationGroup(
                                                                      task!,
                                                                      i)));
                                                        },
                                                  icon: const Icon(
                                                    Icons.delete_outline,
                                                  ),
                                                  tooltip: '移除此组（保留原件）',
                                                ),
                                              ],
                                            ),
                                            if (!checks[i].ready)
                                              Text(
                                                  checks[i]
                                                      .problems
                                                      .toSet()
                                                      .join('；'),
                                                  style: const TextStyle(
                                                      color:
                                                          Colors.deepOrange)),
                                          ],
                                        ),
                                      ),
                                    );
                                  },
                                ),
                              ),
                              Text(
                                status,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(color: Colors.grey),
                              ),
                              if (busy) const LinearProgressIndicator(),
                            ],
                          ),
                        ),
                ),
              ],
            ),
    );
  }
}

class AddGroup extends StatefulWidget {
  final ProcessingClient engine;
  final Set<String> existingPictures;
  final List<Map<String, dynamic>> existingPaymentMaterials;
  final Map<String, dynamic>? initialMaterial;
  final TimeMatchSettings timeSettings;
  final int toleranceCents;
  const AddGroup({
    super.key,
    required this.engine,
    required this.existingPictures,
    this.existingPaymentMaterials = const [],
    this.initialMaterial,
    this.timeSettings = const TimeMatchSettings(),
    this.toleranceCents = 100,
  });
  @override
  State<AddGroup> createState() => _AddGroupState();
}

class _AddGroupState extends State<AddGroup> {
  final amount = TextEditingController();
  Map<String, dynamic>? invoice;
  final List<String> itineraries = [];
  final List<Map<String, dynamic>> itineraryMaterials = [];
  final List<Map<String, dynamic>> payments = [];
  final List<TextEditingController> paymentAmounts = [];
  String category = 'intercity';
  bool busy = false;
  String? error;
  int duplicateSkipped = 0;
  @override
  void initState() {
    super.initState();
    final m = widget.initialMaterial;
    if (m == null) return;
    if (isScreenshot(m)) {
      payments.add(m);
      final cents = m['manualPaymentCents'] ??
          m['cents'] ??
          m['ocr']?['paymentCandidate']?['cents'];
      paymentAmounts.add(
          TextEditingController(text: cents is int ? formatMoney(cents) : ''));
    } else if (m['document']?['type'] == 'itinerary') {
      itineraries.add(m['path']);
      itineraryMaterials.add(m);
      category = 'local';
    } else {
      invoice = m;
      final cents = m['document']?['totalCents'];
      if (cents is int) amount.text = formatMoney(cents);
      if (['intercity', 'hotel', 'local']
          .contains(m['document']?['category'])) {
        category = m['document']['category'];
      }
    }
  }

  Future<Map<String, dynamic>> inspect(String path) async =>
      Map<String, dynamic>.from(
        await widget.engine.call('inspect', {
          'path': path,
          'material_dir': '$projectRoot/.local/materials',
        }),
      );
  Future<void> select(String kind) async {
    setState(() => busy = true);
    try {
      final files = await openFiles(
        acceptedTypeGroups: [
          XTypeGroup(
            label: kind == 'payment' ? '支付截图' : 'PDF',
            extensions: kind == 'payment' ? ['jpg', 'jpeg', 'png'] : ['pdf'],
          ),
        ],
      );
      final known = MaterialIdentityIndex([
        ...payments,
        if (kind == 'payment' && files.isNotEmpty)
          ...await loadPaymentIdentities(
              widget.engine, widget.existingPaymentMaterials)
      ]);
      for (final file in files) {
        final item = await inspect(file.path);
        if (kind == 'invoice') {
          invoice = item;
          break;
        }
        if (kind == 'itinerary') {
          if (!itineraries.contains(item['path'])) {
            itineraries.add(item['path']);
            itineraryMaterials.add(item);
          }
        }
        if (kind == 'payment') {
          if (widget.existingPictures.contains(item['path']) ||
              known.find(item) != null) {
            duplicateSkipped++;
            continue;
          }
          payments.add(item);
          known.add(item);
          final candidate = item['ocr']?['paymentCandidate']?['cents'] as int?;
          paymentAmounts.add(
            TextEditingController(
              text: candidate == null ? '' : formatMoney(candidate),
            ),
          );
        }
      }
    } catch (e) {
      error = '$e';
    }
    if (mounted) setState(() => busy = false);
  }

  void submit() {
    try {
      if (invoice == null || payments.isEmpty) {
        throw StateError('请选择发票和至少一张支付截图');
      }
      final cents = parseMoney(amount.text);
      if (cents == 0) throw StateError('发票金额必须大于零');
      final ps = <Map<String, dynamic>>[];
      for (var i = 0; i < payments.length; i++) {
        final value = parseMoney(paymentAmounts[i].text);
        if (value == 0) throw StateError('支付金额必须大于零');
        ps.add({...payments[i], 'cents': value, 'manualPaymentCents': value});
      }
      if (category == 'local' && itineraries.isEmpty) {
        throw StateError('市内交通需要配套行程单');
      }
      final group = <String, dynamic>{
        ...invoice!,
        'invoiceCents': cents,
        'manuallyEntered': true,
        'category': category,
        'payments': ps,
        'itineraries': itineraries,
        'itineraryMaterials': itineraryMaterials,
        'trips': category == 'local' && itineraryMaterials.length == 1
            ? (itineraryMaterials.single['document']?['trips'] ?? <dynamic>[])
            : <dynamic>[],
        'matchingToleranceCents': widget.toleranceCents,
        'confirmed': false,
        'complete': false,
      };
      if (category == 'local') {
        linkManualTrips(group, widget.timeSettings);
      } else {
        group['suggestionComplete'] = true;
      }
      Navigator.pop(context, group);
    } catch (e) {
      setState(() => error = '$e');
    }
  }

  @override
  void dispose() {
    amount.dispose();
    for (final c in paymentAmounts) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('添加一组发票与支付材料'),
        content: SizedBox(
          width: 650,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '系统本地 OCR 填入实付候选，每张截图暂按一笔支付处理。填写实际支付净额；材料匹配完整即可导出，人工复核可选。',
                ),
                const SizedBox(height: 16),
                DropdownButtonFormField<String>(
                  initialValue: category,
                  items: const [
                    DropdownMenuItem(value: 'intercity', child: Text('城际交通')),
                    DropdownMenuItem(value: 'hotel', child: Text('酒店住宿')),
                    DropdownMenuItem(value: 'local', child: Text('市内交通')),
                  ],
                  onChanged: busy ? null : (v) => setState(() => category = v!),
                ),
                const SizedBox(height: 12),
                OutlinedButton(
                  onPressed: busy ? null : () => select('invoice'),
                  child: Text(invoice?['name'] ?? '选择发票 PDF'),
                ),
                TextField(
                  controller: amount,
                  decoration: const InputDecoration(labelText: '发票金额（元）'),
                ),
                const SizedBox(height: 12),
                OutlinedButton(
                  onPressed: busy ? null : () => select('itinerary'),
                  child: Text('添加配套行程单（已选 ${itineraries.length} 份）'),
                ),
                OutlinedButton(
                  onPressed: busy ? null : () => select('payment'),
                  child: const Text('添加支付截图，可多选'),
                ),
                for (var i = 0; i < payments.length; i++)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Row(
                      children: [
                        Image.file(
                          File(payments[i]['path']),
                          height: 90,
                          width: 55,
                          fit: BoxFit.contain,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: TextField(
                            controller: paymentAmounts[i],
                            decoration: InputDecoration(
                              labelText: '第 ${i + 1} 笔实付净额（元）',
                              helperText: payments[i]['name'],
                            ),
                          ),
                        ),
                        IconButton(
                          onPressed: busy
                              ? null
                              : () => setState(() {
                                    payments.removeAt(i);
                                    paymentAmounts.removeAt(i).dispose();
                                  }),
                          icon: const Icon(Icons.close),
                        ),
                      ],
                    ),
                  ),
                if (error != null)
                  Text(error!, style: const TextStyle(color: Colors.red)),
                if (duplicateSkipped > 0)
                  Text('已自动移除 $duplicateSkipped 项重复支付截图（原始文件保留）',
                      style: const TextStyle(color: Colors.teal)),
                if (busy) const LinearProgressIndicator(),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: busy ? null : () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
              onPressed: busy ? null : submit, child: const Text('保存并核对')),
        ],
      );
}
