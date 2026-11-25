import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

class PendingPdfDropArea extends StatefulWidget {
  final bool enabled;
  final Future<void> Function(List<String>) onFiles;
  final Future<String?> Function()? pickFile;
  const PendingPdfDropArea(
      {super.key, required this.onFiles, this.enabled = true, this.pickFile});
  @override
  State<PendingPdfDropArea> createState() => _PendingPdfDropAreaState();
}

class _PendingPdfDropAreaState extends State<PendingPdfDropArea> {
  bool hovering = false, picking = false, receiving = false;
  String? error;
  Future<void> submit(List<String> paths) async {
    if (!widget.enabled || receiving) return;
    setState(() {
      receiving = true;
      hovering = false;
      error = null;
    });
    try {
      await widget.onFiles(paths);
    } catch (e) {
      if (mounted) setState(() => error = '导入失败：$e');
    } finally {
      if (mounted) setState(() => receiving = false);
    }
  }

  Future<void> choose() async {
    if (!widget.enabled || picking || receiving) return;
    setState(() => picking = true);
    try {
      final path = widget.pickFile != null
          ? await widget.pickFile!()
          : (await openFile(acceptedTypeGroups: [
              const XTypeGroup(label: 'PDF 发票', extensions: ['pdf'])
            ]))
              ?.path;
      if (path != null && mounted) await submit([path]);
    } catch (e) {
      if (mounted) setState(() => error = '选择文件失败：$e');
    } finally {
      if (mounted) setState(() => picking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final active = widget.enabled && !picking && !receiving;
    final colors = Theme.of(context).colorScheme;
    return DropTarget(
        enable: active,
        onDragEntered: (_) => setState(() => hovering = true),
        onDragExited: (_) => setState(() => hovering = false),
        onDragDone: (details) {
          if (!active || picking) return;
          submit(details.files.map((file) => file.path).toList());
        },
        child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            width: double.infinity,
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                    color: hovering ? colors.primary : colors.outlineVariant,
                    width: hovering ? 2 : 1),
                color: hovering
                    ? colors.primaryContainer
                    : colors.surfaceContainerLow),
            child: Center(
                child: SingleChildScrollView(
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.upload_file_outlined, size: 48, color: colors.primary),
              const SizedBox(height: 12),
              Text(
                  !widget.enabled || receiving
                      ? '正在识别、匹配并保存…'
                      : hovering
                          ? '松开鼠标导入 PDF'
                          : '将下载好的 PDF 拖到这里',
                  style: Theme.of(context).textTheme.titleMedium,
                  textAlign: TextAlign.center),
              const SizedBox(height: 8),
              const Text('一次一份，导入到当前差旅。核对邮件后关闭本条待办。\n原下载文件保留。',
                  textAlign: TextAlign.center),
              const SizedBox(height: 16),
              OutlinedButton.icon(
                  onPressed: active ? choose : null,
                  icon: const Icon(Icons.folder_open),
                  label: const Text('选择 PDF 文件')),
              if (error != null)
                Text(error!, style: TextStyle(color: colors.error)),
            ])))));
  }
}
