import 'dart:io';
import 'package:flutter/material.dart';

typedef DocumentPreviewLoader = Future<Map<String, dynamic>> Function(
    String path, int page);

/// 发票、行程单及未识别 PDF 共用的只读预览。
class PdfPreviewPanel extends StatefulWidget {
  final Map<String, dynamic> material;
  final DocumentPreviewLoader? loadPreview;
  final String title;
  final String? textTitle;
  final Widget Function(Map<String, dynamic>)? information;
  final bool showName;
  const PdfPreviewPanel(
      {super.key,
      required this.material,
      required this.title,
      this.loadPreview,
      this.textTitle,
      this.information,
      this.showName = true});
  @override
  State<PdfPreviewPanel> createState() => _PdfPreviewPanelState();
}

class _PdfPreviewPanelState extends State<PdfPreviewPanel> {
  Map<String, dynamic>? preview;
  int page = 0, generation = 0;
  bool loading = false;
  String? error;
  @override
  void initState() {
    super.initState();
    load(0);
  }

  @override
  void didUpdateWidget(covariant PdfPreviewPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.material['path'] != widget.material['path']) {
      generation++;
      preview = null;
      page = 0;
      error = null;
      loading = false;
      load(0);
    }
  }

  Future<void> load(int index) async {
    final request = ++generation;
    if (widget.loadPreview == null) return;
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final result = await widget.loadPreview!(widget.material['path'], index);
      if (!mounted || request != generation) return;
      setState(() {
        preview = result;
        page = index;
      });
    } catch (e) {
      if (mounted && request == generation) {
        setState(() => error = '${widget.title}预览未能读取：$e');
      }
    } finally {
      if (mounted && request == generation) setState(() => loading = false);
    }
  }

  Future<void> expand() => showDialog<void>(
      context: context,
      builder: (context) => Dialog(
          child: SizedBox(
              width: 1000,
              height: MediaQuery.sizeOf(context).height * .85,
              child: Column(children: [
                ListTile(
                    title: Text(
                        '${widget.title}原件 · 第 ${page + 1} / ${preview!['pages']} 页'),
                    trailing: IconButton(
                        tooltip: '关闭${widget.title}预览',
                        onPressed: () => Navigator.pop(context),
                        icon: const Icon(Icons.close))),
                const Text('可滚轮缩放、拖动查看；关闭后继续核对'),
                Expanded(
                    child: InteractiveViewer(
                        minScale: .5,
                        maxScale: 8,
                        child: Center(
                            child: Image.file(File(preview!['path']),
                                fit: BoxFit.contain,
                                errorBuilder: (_, __, ___) =>
                                    const Text('预览图片无法读取，请关闭后重试'))))),
              ]))));
  @override
  Widget build(BuildContext context) {
    final document = <String, dynamic>{
      ...?widget.material['document'] as Map<String, dynamic>?,
      ...?preview?['document'] as Map<String, dynamic>?
    };
    final text = preview?['text'] ?? widget.material['text'] ?? '';
    return Card(
        margin: const EdgeInsets.only(bottom: 12),
        child: Padding(
            padding: const EdgeInsets.all(12),
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              if (widget.showName) ...[
                Text(widget.title,
                    style: Theme.of(context).textTheme.titleMedium),
                SelectableText(
                    widget.material['name'] ?? widget.material['path']),
                const SizedBox(height: 8),
              ],
              if (widget.information != null) widget.information!(document),
              if (loading) const LinearProgressIndicator(),
              if (preview != null) ...[
                const SizedBox(height: 8),
                InkWell(
                    key: ValueKey('${widget.title}-thumbnail'),
                    onTap: expand,
                    child: Container(
                        color: Colors.white,
                        width: double.infinity,
                        child: Image.file(File(preview!['path']),
                            height: 190,
                            fit: BoxFit.contain,
                            errorBuilder: (_, __, ___) => const SizedBox(
                                height: 100,
                                child: Center(child: Text('预览图片无法读取')))))),
                Wrap(
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: 4,
                    children: [
                      IconButton(
                          tooltip: '${widget.title}上一页',
                          onPressed: loading || page == 0
                              ? null
                              : () => load(page - 1),
                          icon: const Icon(Icons.chevron_left)),
                      Text('第 ${page + 1} / ${preview!['pages']} 页'),
                      IconButton(
                          tooltip: '${widget.title}下一页',
                          onPressed:
                              loading || page + 1 >= (preview!['pages'] as int)
                                  ? null
                                  : () => load(page + 1),
                          icon: const Icon(Icons.chevron_right)),
                      TextButton.icon(
                          onPressed: expand,
                          icon: const Icon(Icons.zoom_in),
                          label: Text('放大${widget.title}')),
                    ]),
              ],
              if (error != null)
                Text(error!, style: const TextStyle(color: Colors.deepOrange)),
              if (error != null && widget.loadPreview != null)
                TextButton(
                    onPressed: loading ? null : () => load(page),
                    child: Text('重新读取${widget.title}')),
              ExpansionTile(
                  tilePadding: EdgeInsets.zero,
                  title: Text(widget.textTitle ?? '${widget.title}原文'),
                  children: [
                    SelectableText(text.toString().trim().isEmpty
                        ? '未提取到文字，请查看原件。'
                        : text.toString())
                  ]),
            ])));
  }
}
