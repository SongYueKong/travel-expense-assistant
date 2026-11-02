import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:travel_assistant/runtime_paths.dart';

void main() {
  test(
      'release resolves engine beside executable and isolates data outside package',
      () {
    final paths = RuntimePaths.resolve(
        executable: 'D:/软件 目录/差旅报账助手.exe',
        environment: {'LOCALAPPDATA': 'C:/Users/Test/AppData/Local'},
        developmentRoot: '');
    expect(paths.engineRoot.replaceAll('\\', '/'), 'D:/软件 目录');
    expect(paths.workspaceRoot,
        'C:/Users/Test/AppData/Local/TravelExpenseAssistant/Workspace');
    expect(paths.development, isFalse);
  });
  test(
      'development retains existing workspace and does not read user configuration',
      () {
    final paths = RuntimePaths.resolve(
        developmentRoot: 'D:/Work/Project', environment: {});
    expect(paths.workspaceRoot, 'D:/Work/Project');
    expect(paths.engineRoot, paths.workspaceRoot);
    expect(paths.configuration, isNull);
  });
  test(
      'custom workspace persists while test overrides never modify configuration',
      () async {
    final base = await Directory.systemTemp.createTemp('portable-path-test-');
    var paths = RuntimePaths.resolve(
        developmentRoot: '',
        executable: 'D:/程序/app.exe',
        environment: {'LOCALAPPDATA': base.path});
    final custom = Directory('${base.path}/指定数据');
    await paths.selectWorkspace(custom.path);
    paths = RuntimePaths.resolve(
        developmentRoot: '',
        executable: 'E:/新版本/app.exe',
        environment: {'LOCALAPPDATA': base.path});
    expect(paths.workspaceRoot, custom.absolute.path);
    expect(paths.engineRoot.replaceAll('\\', '/'), 'E:/新版本');
    final isolated = RuntimePaths.resolve(developmentRoot: '', environment: {
      'LOCALAPPDATA': base.path,
      'TRAVEL_ASSISTANT_DATA_DIR': '${base.path}/自检'
    });
    expect(isolated.workspaceRoot, contains('自检'));
    expect(jsonDecode(await paths.configuration!.readAsString())['workspace'],
        custom.absolute.path);
  });
}
