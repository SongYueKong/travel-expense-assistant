import 'dart:convert';
import 'dart:io';

class RuntimePaths {
  final String engineRoot, workspaceRoot;
  final bool development;
  final File? configuration;
  const RuntimePaths(this.engineRoot, this.workspaceRoot, this.development,
      this.configuration);
  factory RuntimePaths.resolve(
      {String? executable,
      Map<String, String>? environment,
      String developmentRoot = const String.fromEnvironment('PROJECT_ROOT')}) {
    if (developmentRoot.isNotEmpty) {
      return RuntimePaths(developmentRoot, developmentRoot, true, null);
    }
    final env = environment ?? Platform.environment;
    final directory =
        File(executable ?? Platform.resolvedExecutable).absolute.parent.path;
    final local = env['LOCALAPPDATA'] ??
        (env['USERPROFILE'] == null
            ? null
            : '${env['USERPROFILE']}/AppData/Local');
    if (local == null || local.isEmpty) {
      throw StateError('无法定位当前用户的数据目录（LOCALAPPDATA）');
    }
    final configuration = File('$local/TravelExpenseAssistant/workspace.json');
    var data = '$local/TravelExpenseAssistant/Workspace';
    if (configuration.existsSync()) {
      final config =
          jsonDecode(configuration.readAsStringSync()) as Map<String, dynamic>;
      if (config['workspace'] is! String ||
          !(config['workspace'] as String)
              .contains(RegExp(r'^(?:[A-Za-z]:[\\/]|\\\\|/)'))) {
        throw const FormatException('数据目录配置无效，请检查 workspace.json');
      }
      data = config['workspace'];
    }
    final override = env['TRAVEL_ASSISTANT_DATA_DIR'];
    if (override != null && override.isNotEmpty) {
      data = Directory(override).absolute.path;
    }
    return RuntimePaths(directory, data, false, configuration);
  }
  Future<void> selectWorkspace(String path) async {
    if (configuration == null) throw StateError('开发版使用项目目录，请在免安装版中选择数据位置');
    await Directory(path).create(recursive: true);
    await configuration!.parent.create(recursive: true);
    final staged = File('${configuration!.path}.new');
    await staged.writeAsString(
        jsonEncode({'workspace': Directory(path).absolute.path}),
        flush: true);
    await staged.rename(configuration!.path);
  }
}
