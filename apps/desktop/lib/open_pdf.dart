import 'dart:io';

typedef PdfAppLauncher = Future<ProcessResult> Function(
    String executable, List<String> arguments, Map<String, String> environment);

/// 文件路径通过环境变量传递，不拼接到 PowerShell 命令中。
Future<void> openPdfWithDefaultApp(String path,
    {PdfAppLauncher? launcher}) async {
  final file = File(path).absolute;
  if (!file.path.toLowerCase().endsWith('.pdf')) {
    throw const FormatException('只能打开 PDF 文件');
  }
  if (!await file.exists()) {
    throw FileSystemException('PDF 文件不存在，请重新导出或检查差旅文件夹', file.path);
  }
  if (!Platform.isWindows && launcher == null) {
    throw UnsupportedError('当前版本仅支持在 Windows 中打开默认 PDF 软件');
  }
  final windows = Platform.environment['WINDIR'] ?? r'C:\Windows';
  final executable =
      '$windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe';
  const command =
      r"$ErrorActionPreference = 'Stop'; try { Start-Process -FilePath $env:TRAVEL_ASSISTANT_OPEN_PDF -ErrorAction Stop | Out-Null; exit 0 } catch { exit 1 }";
  final arguments = [
    '-NoProfile',
    '-NonInteractive',
    '-WindowStyle',
    'Hidden',
    '-Command',
    command
  ];
  final environment = {'TRAVEL_ASSISTANT_OPEN_PDF': file.path};
  final launch = launcher ??
      (String program, List<String> args, Map<String, String> env) =>
          Process.run(program, args, environment: env, runInShell: false);
  try {
    final result = await launch(executable, arguments, environment);
    if (result.exitCode != 0) {
      throw StateError('无法打开 PDF，请在 Windows 中设置 PDF 默认应用后重试');
    }
  } on ProcessException {
    throw StateError('无法启动默认 PDF 软件，请检查 Windows 的 PDF 默认应用设置');
  }
}
