"""语义金额规则的布局扰动、干扰及拒绝判断测试；全部使用合成文字。"""
import copy
import unittest
from ocr import enrich_ocr
from payment_amounts import evidence
from test_payment_layout_ocr import wechat, bank


def row(text, x=100, y=300, height=30, width=180):
    return dict(text=text,x=x,y=y,height=height,width=width)


def page(lines, title='付款成功'):
    return dict(text=title+' '+' '.join(r['text'] for r in lines),lines=lines,width=1200,height=2400)


def moved(data, scale=1, dx=0, dy=0, tail=0):
    data=copy.deepcopy(data)
    for r in data['lines']:
        for k in ('x','y','width','height'):r[k]*=scale
        r['x']+=dx;r['y']+=dy
    data['width']=data['width']*scale+max(dx,0)
    data['height']=data['height']*scale+max(dy,0)+tail
    return data


class SemanticAmountTests(unittest.TestCase):
    def test_translation_scaling_and_long_image_do_not_change_semantic_amounts(self):
        for base,cents in [(wechat(),1090),(bank(),88000),
                           (wechat('一1500.00',status='已退款（¥480.00）',refund='已退款¥480.00〉'),102000)]:
            for scale in (.5,1,1.7):
                for dx,dy,tail in [(0,0,0),(700,4000,0),(0,0,8000)]:
                    with self.subTest(cents=cents,scale=scale,dy=dy,tail=tail):
                        result=enrich_ocr(moved(base,scale,dx,dy,tail))
                        self.assertEqual(result['paymentCandidate']['cents'],cents)

    def test_explicit_paid_field_can_be_anywhere_not_largest_or_topmost(self):
        for y in (10,1000,2200):
            data=page([row('支付时间：2026-11-06 12:00:00'),row('账户余额：¥9999.00',y=50,height=90),
                       row('订单金额：¥50.00',y=500),row('优惠：-3.50元',y=600),
                       row('实际支付：46.50元',y=y,height=22)])
            result=enrich_ocr(data)
            self.assertEqual(result['paymentCandidate']['cents'],4650)
            self.assertEqual({r['role'] for r in result['amountCandidates']},{'paid','balance','order','discount'})

    def test_label_beside_or_above_value_and_currency_integer(self):
        for rows in [[row('实付金额',y=100),row('¥48.00',x=400,y=100)],
                     [row('实付金额',y=100),row('48.00元',y=145)],
                     [row('实付金额：¥48',y=1800)]]:
            result=enrich_ocr(page([row('支付时间：2026-11-06 12:00:00',y=2000),*rows]))
            self.assertEqual(result['paymentCandidate']['cents'],4800)

    def test_labeled_conflicts_and_header_disagreement_stay_pending(self):
        for rows in [[row('实付：48.00',y=400),row('实际支付：49.00',y=500)],
                     [row('实付：48.00',y=400),row('-49.00',y=200,height=60)],
                     [row('订单金额：50.00',y=400),row('优惠：-3.50',y=500),row('实付：48.00',y=600)]]:
            result=enrich_ocr(page([*rows,row('支付时间：2026-11-06 12:00:00',y=1800)]))
            self.assertNotIn('paymentCandidate',result)
            self.assertEqual(result['amountDecision']['status'],'needsReview')

    def test_balance_order_refund_discount_only_never_become_paid(self):
        for name in ('订单金额','优惠','退款金额','余额','记账金额'):
            result=enrich_ocr(page([row(name+'：48.00'),row('支付时间：2026-11-06 12:00:00',y=500)]))
            self.assertNotIn('paymentCandidate',result)
            self.assertTrue(result['amountCandidates'])

    def test_unknown_or_failed_status_never_automatically_accepts_amount(self):
        for status in ('处理中','支付失败','交易关闭','退款成功','收入到账'):
            result=enrich_ocr(page([row('实付金额：48.00'),row('支付时间：2026-11-06 12:00:00',y=500)],title=status))
            self.assertNotIn('paymentCandidate',result)

    def test_status_negation_and_advertising_cannot_overrule_failed_state(self):
        for state in ('交易关闭', '支付失败', '未支付成功'):
            data=page([row('实付：48.00'),row('交易状态：'+state,y=600),
                       row('支付时间：2026-11-06 12:00:00',y=700),row('支付成功享优惠',y=800)])
            self.assertNotIn('paymentCandidate',enrich_ocr(data))
        data=page([row('实付：48.00'),row('支付时间：2026-11-06 12:00:00',y=700),row('未支付成功',y=800)])
        self.assertNotIn('paymentCandidate',enrich_ocr(data))

    def test_label_value_does_not_cross_next_field(self):
        data=page([row('实付金额',y=100),row('订单金额',y=130),row('48.00',y=165),
                   row('支付时间：2026-11-06 12:00:00',y=700)])
        self.assertNotIn('paymentCandidate',enrich_ocr(data))

    def test_identifiers_and_status_bar_clock_not_amount_candidates(self):
        data=page([row('9999000011112222333344445555'),row('12:16'),row('86%')])
        self.assertEqual(evidence(data),[])

    def test_net_with_refund_is_verified_and_not_subtracted_twice(self):
        data=wechat('一1500.00',status='已退款（¥480.00）',refund='已退款¥480.00〉')
        data['lines'].append(row('净支付金额：1020.00',y=2400))
        data['text']+=' 净支付金额：1020.00'
        result=enrich_ocr(data)
        self.assertEqual(result['paymentCandidate']['cents'],102000)
        self.assertEqual(enrich_ocr(result)['paymentCandidate']['cents'],102000)
        data['lines'][-1]['text']='净支付金额：1100.00'
        self.assertNotIn('paymentCandidate',enrich_ocr(data))

    def test_enrichment_is_idempotent_and_preserves_raw_ocr(self):
        data=wechat();before=copy.deepcopy(data)
        result=enrich_ocr(data)
        self.assertEqual(enrich_ocr(result),result)
        self.assertEqual(data,before)


if __name__=='__main__':unittest.main()
