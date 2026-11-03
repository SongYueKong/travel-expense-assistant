import 'package:flutter/material.dart';

List<Map<String, dynamic>> exportedPdfFiles(Map<String, dynamic> task,
    {Map<String, dynamic>? recent}) {
  final seen = <String>{};
  final result = <Map<String, dynamic>>[];
  for (final entry in [
    if (recent != null) recent,
    ...(task['exports'] as List? ?? []).reversed
  ]) {
    if (entry is! Map || entry['path'] is! String) continue;
    final path = (entry['path'] as String).trim();
    if (!path.toLowerCase().endsWith('.pdf') ||
        !seen.add(path.replaceAll('\\', '/').toLowerCase())) {
      continue;
    }
    result.add({
      ...Map<String, dynamic>.from(entry),
      'path': path,
      'name': entry['name'] is String
          ? entry['name']
          : path.replaceAll('\\', '/').split('/').last
    });
  }
  return result;
}

class ExportedPdfDialog extends StatefulWidget {
  final List<Map<String, dynamic>> files;
  final Future<void> Function(String path) openFile;
  const ExportedPdfDialog(
      {super.key, required this.files, required this.openFile});
  @override
  State<ExportedPdfDialog> createState() => _ExportedPdfDialogState();
}

class _ExportedPdfDialogState extends State<ExportedPdfDialog> {
  bool opening = false;
  String? error;

  Future<void> open(String path) async {
    setState(() {
      opening = true;
      error = null;
    });
    try {
      await widget.openFile(path);
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        setState(() {
          opening = false;
          error = '$e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('已导出的 PDF'),
        content: SizedBox(
            width: 680,
            height: MediaQuery.sizeOf(context).height * .55,
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('选择文件，使用系统默认 PDF 软件打开。'),
              if (opening) const LinearProgressIndicator(),
              if (error != null)
                Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Text(error!,
                        style: TextStyle(
                            color: Theme.of(context).colorScheme.error))),
              const SizedBox(height: 8),
              Expanded(
                  child: widget.files.isEmpty
                      ? const Center(child: Text('当前差旅尚无导出记录。'))
                      : ListView(children: [
                          for (final file in widget.files)
                            ListTile(
                              enabled: !opening,
                              leading:
                                  const Icon(Icons.picture_as_pdf_outlined),
                              title: Text(file['name']),
                              subtitle: Text(file['path']),
                              trailing: const Icon(Icons.open_in_new),
                              onTap: opening ? null : () => open(file['path']),
                            )
                        ])),
            ])),
        actions: [
          TextButton(
              onPressed: opening ? null : () => Navigator.pop(context),
              child: const Text('关闭'))
        ],
      );
}
