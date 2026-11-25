import 'dart:io';
import 'open_pdf.dart' show PdfAppLauncher;

/// 仅打开已适配平台的官方 HTTPS 短链接，URL 作为环境变量传递，不拼接命令。
bool isOfficialInvoiceLink(String value) {
  final uri = Uri.tryParse(value);
  return uri != null &&
      uri.scheme == 'https' &&
      uri.userInfo.isEmpty &&
      uri.host == 'a.51fapiao.cn' &&
      (!uri.hasPort || uri.port == 443) &&
      RegExp(r'^/v/[A-Za-z0-9]+$').hasMatch(uri.path) &&
      !uri.hasQuery &&
      !uri.hasFragment;
}

Future<void> openOfficialInvoiceLink(String url,
    {PdfAppLauncher? launcher}) async {
  if (!isOfficialInvoiceLink(url)) throw const FormatException('发票下载地址不在支持范围');
  if (!Platform.isWindows && launcher == null) {
    throw UnsupportedError('请在 Windows 中打开官方下载页');
  }
  final windows = Platform.environment['WINDIR'] ?? r'C:\Windows';
  const command =
      r"$ErrorActionPreference='Stop'; try { Start-Process -FilePath $env:TRAVEL_INVOICE_URL -ErrorAction Stop | Out-Null; exit 0 } catch { exit 1 }";
  final launch = launcher ??
      (String program, List<String> args, Map<String, String> env) =>
          Process.run(program, args, environment: env, runInShell: false);
  final result = await launch(
      '$windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe', [
    '-NoProfile',
    '-NonInteractive',
    '-WindowStyle',
    'Hidden',
    '-Command',
    command
  ], {
    'TRAVEL_INVOICE_URL': url
  });
  if (result.exitCode != 0) throw StateError('无法打开官方下载页，请检查默认浏览器设置');
}
