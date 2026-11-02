import 'dart:io';

String windowsFolderArgument(String path) {
  var result = Directory(path).absolute.path.replaceAll('/', '\\');
  if (result.length > 3) result = result.replaceAll(RegExp(r'\\+$'), '');
  return result;
}

Future<void> openFolder(String path) async {
  final normalized = windowsFolderArgument(path);
  if (!await Directory(normalized).exists()) {
    throw FileSystemException('文件夹不存在，请确认数据位置或重新打开软件', normalized);
  }
  final windows = Platform.environment['WINDIR'] ?? r'C:\Windows';
  await Process.start('$windows\\explorer.exe', [normalized],
      mode: ProcessStartMode.detached);
}
