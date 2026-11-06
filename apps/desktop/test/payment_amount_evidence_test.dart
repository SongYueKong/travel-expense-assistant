import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:travel_assistant/payment_amount_evidence.dart';

Map<String, dynamic> material() => {
      'path': 'missing.png',
      'ocr': {
        'width': 1000,
        'height': 2000,
        'amountDecision': {'status': 'needsReview', 'reason': '存在多个实付候选，请核对'},
        'amountCandidates': [
          {
            'cents': 4800,
            'role': 'paid',
            'label': '实付金额',
            'source': {
              'text': '48.00',
              'x': 100,
              'y': 800,
              'width': 200,
              'height': 60
            }
          },
          {
            'cents': 5000,
            'role': 'order',
            'label': '订单金额',
            'source': {'text': '50.00'}
          },
          {
            'cents': 100000,
            'role': 'balance',
            'label': '余额',
            'source': {'text': '1000.00'}
          },
          {
            'cents': 200,
            'role': 'discount',
            'label': '优惠',
            'source': {'text': '-2.00'}
          },
        ]
      }
    };

void main() {
  testWidgets(
      'candidate selection only emits explicit user choice and never alters OCR',
      (tester) async {
    final m = material(), before = jsonEncode(material());
    int? chosen;
    Map? source;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SingleChildScrollView(
                child: PaymentAmountEvidence(
                    material: m,
                    onUse: (v) => chosen = v,
                    onPreview: (v) => source = v)))));
    expect(find.text('余额：¥1000.00'), findsOneWidget);
    expect(find.text('填入实付'), findsOneWidget);
    expect(chosen, isNull);
    await tester.tap(find.text('填入实付'));
    await tester.pumpAndSettle();
    expect(chosen, 4800);
    await tester.tap(find.text('查看位置').first);
    await tester.pumpAndSettle();
    expect(source!['source']['y'], 800);
    expect(jsonEncode(m), before);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
      'refunded payment offers net amount, never original gross as paid',
      (tester) async {
    final m = material();
    m['ocr']['refundCandidate'] = {'grossCents': 150000, 'cents': 48000};
    m['ocr']['paymentCandidate'] = {'cents': 102000};
    m['ocr']['amountCandidates'][0]['cents'] = 150000;
    m['ocr']['amountCandidates'][0]['role'] = 'header';
    int? chosen;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body:
                PaymentAmountEvidence(material: m, onUse: (v) => chosen = v))));
    await tester.tap(find.text('查看金额依据／候选'));
    await tester.pumpAndSettle();
    expect(find.text('填入实付'), findsNothing);
    await tester.tap(find.text('填入退款后净支付'));
    await tester.pumpAndSettle();
    expect(chosen, 102000);
  });
  testWidgets(
      'read-only view has no amount edit action and old material is supported',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: PaymentAmountEvidence(material: material()))));
    expect(find.text('填入实付'), findsNothing);
    await tester.pumpWidget(
        const MaterialApp(home: PaymentAmountEvidence(material: {})));
    expect(find.text('查看金额依据／候选'), findsNothing);
  });
  test(
      'source rectangle follows displayed image scale and clamps off-image coordinates',
      () {
    expect(
        amountSourceRect({'x': 100, 'y': 800, 'width': 200, 'height': 60},
            const Size(1000, 2000), const Size(250, 500)),
        const Rect.fromLTWH(25, 200, 50, 15));
    expect(
        amountSourceRect({'x': -10, 'y': 0, 'width': 20, 'height': 10},
            const Size(1000, 2000), const Size(250, 500)),
        const Rect.fromLTWH(0, 0, 2.5, 2.5));
    expect(amountSourceRect({}, const Size(1000, 2000), const Size(250, 500)),
        isNull);
  });
}
