import 'package:flutter/material.dart';

/// 核验实际导出的票据类别；零金额材料仍视为该类别存在。
List<String> missingExpenseCategories(Map<String, dynamic> manifest) {
  const categories = {
    'intercity': '城市间交通费',
    'local': '市内交通费',
    'hotel': '住宿费',
  };
  final present = {
    for (final row in (manifest['summary'] as List? ?? []))
      if (row['kind'] != 'allowance') row['category']
  };
  return [
    for (final entry in categories.entries)
      if (!present.contains(entry.key)) entry.value
  ];
}

Future<bool> confirmExpenseCategories(
    BuildContext context, Map<String, dynamic> manifest) async {
  final missing = missingExpenseCategories(manifest);
  if (missing.isEmpty) return true;
  return await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (context) => AlertDialog(
          title: const Text('请核验报销费用类别'),
          content: SizedBox(
            width: 440,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('本次导出未包含以下费用类别：'),
                const SizedBox(height: 12),
                for (final name in missing)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Text('• $name',
                        style: const TextStyle(fontWeight: FontWeight.bold)),
                  ),
                const SizedBox(height: 12),
                const Text('请核验是否漏加发票或关联支付；如本次确实没有这些费用，可继续导出。'),
              ],
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('返回检查')),
            FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('已核验，继续导出')),
          ],
        ),
      ) ??
      false;
}
