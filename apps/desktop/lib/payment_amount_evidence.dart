import 'dart:io';
import 'package:flutter/material.dart';
import 'package:travel_core/travel_core.dart';

Rect? amountSourceRect(Map source, Size original, Size displayed) {
  if (original.width <= 0 || original.height <= 0) return null;
  final values = ['x', 'y', 'width', 'height'].map((k) => source[k]).toList();
  if (values.any((v) => v is! num || !v.isFinite)) return null;
  final x = (values[0] as num).toDouble(), y = (values[1] as num).toDouble();
  final w = (values[2] as num).toDouble(), h = (values[3] as num).toDouble();
  if (w <= 0 || h <= 0) return null;
  final rect = Rect.fromLTWH(x, y, w, h).intersect(Offset.zero & original);
  if (rect.isEmpty) return null;
  return Rect.fromLTRB(
      rect.left / original.width * displayed.width,
      rect.top / original.height * displayed.height,
      rect.right / original.width * displayed.width,
      rect.bottom / original.height * displayed.height);
}

Future<void> showAmountSource(
        BuildContext context, Map material, Map candidate) =>
    showDialog<void>(
        context: context,
        builder: (context) {
          final ocr = material['ocr'] as Map? ?? {};
          final original = Size((ocr['width'] as num? ?? 0).toDouble(),
              (ocr['height'] as num? ?? 0).toDouble());
          return AlertDialog(
              title: Text('金额位置 · ${candidate['label'] ?? '候选金额'}'),
              content: SizedBox(
                  width: 700,
                  height: MediaQuery.sizeOf(context).height * .7,
                  child: Column(children: [
                    Text('${candidate['source']?['text'] ?? ''}'),
                    const Text('橙色框标出金额来源，可缩放查看原图。'),
                    Expanded(child: LayoutBuilder(builder: (_, constraints) {
                      if (original.isEmpty) {
                        return const Center(child: Text('缺少截图尺寸，请查看原件'));
                      }
                      final displayed = applyBoxFit(
                              BoxFit.contain, original, constraints.biggest)
                          .destination;
                      final rect = amountSourceRect(
                          candidate['source'] as Map? ?? {},
                          original,
                          displayed);
                      return Center(
                          child: InteractiveViewer(
                              maxScale: 6,
                              child: SizedBox(
                                  width: displayed.width,
                                  height: displayed.height,
                                  child: Stack(children: [
                                    Image.file(File(material['path']),
                                        width: displayed.width,
                                        height: displayed.height,
                                        fit: BoxFit.fill,
                                        errorBuilder: (context, error,
                                                stackTrace) =>
                                            const Center(
                                                child: Text('截图无法打开，请检查文件'))),
                                    if (rect != null)
                                      Positioned.fromRect(
                                          rect: rect.inflate(2),
                                          child: IgnorePointer(
                                              child: DecoratedBox(
                                                  decoration: BoxDecoration(
                                                      border: Border.all(
                                                          color:
                                                              Colors.deepOrange,
                                                          width: 2),
                                                      color: Colors.orange
                                                          .withValues(
                                                              alpha: .12))))),
                                  ]))));
                    })),
                  ])),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('关闭'))
              ]);
        });

class PaymentAmountEvidence extends StatelessWidget {
  final Map<String, dynamic> material;
  final ValueChanged<int>? onUse;
  final ValueChanged<Map>? onPreview;
  const PaymentAmountEvidence(
      {super.key, required this.material, this.onUse, this.onPreview});
  @override
  Widget build(BuildContext context) {
    final ocr = material['ocr'] as Map? ?? {};
    final candidates =
        (ocr['amountCandidates'] as List? ?? []).whereType<Map>().toList();
    if (candidates.isEmpty) return const SizedBox.shrink();
    final refund = ocr['refundCandidate'] as Map?;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (refund?['grossCents'] is int && refund?['cents'] is int)
        Text(
            '原支付 ¥${formatMoney(refund!['grossCents'])} − 退款 ¥${formatMoney(refund['cents'])}'),
      if (ocr['amountDecision']?['reason'] is String)
        Text(ocr['amountDecision']['reason']),
      ExpansionTile(
          tilePadding: EdgeInsets.zero,
          title: const Text('查看金额依据／候选'),
          initiallyExpanded: ocr['paymentCandidate'] == null,
          children: [
            if (onUse != null) const Text('对照原图选择实际支付净额，保存后生效。'),
            if (onUse != null &&
                refund != null &&
                ocr['paymentCandidate']?['cents'] is int)
              OutlinedButton(
                  onPressed: () => onUse!(ocr['paymentCandidate']['cents']),
                  child: const Text('填入退款后净支付')),
            for (final candidate in candidates)
              Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Align(
                      alignment: Alignment.centerLeft,
                      child: Wrap(
                          spacing: 8,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            Text(
                                '${candidate['label'] ?? '候选'}：${candidate['cents'] is int ? '¥${formatMoney(candidate['cents'])}' : '金额未读清'}'),
                            TextButton(
                                onPressed: () => onPreview != null
                                    ? onPreview!(candidate)
                                    : showAmountSource(
                                        context, material, candidate),
                                child: const Text('查看位置')),
                            if (onUse != null &&
                                candidate['cents'] is int &&
                                candidate['cents'] > 0 &&
                                (refund == null ||
                                    candidate['role'] == 'net') &&
                                ![
                                  'order',
                                  'discount',
                                  'refund',
                                  'balance',
                                  'booked'
                                ].contains(candidate['role']))
                              OutlinedButton(
                                  onPressed: () => onUse!(candidate['cents']),
                                  child: const Text('填入实付')),
                          ]))),
          ]),
    ]);
  }
}
