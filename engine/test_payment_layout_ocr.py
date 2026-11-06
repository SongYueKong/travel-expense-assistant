"""合成微信/银行账单；不包含真实账户、单位或交易号。"""
import copy
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
from PIL import Image
from hotel_identity import payment_payee
from ocr import enrich_ocr, recognize_image


def row(text, x=400, y=1200, height=44, width=400):
    return dict(text=text, x=x, y=y, height=height, width=width)


def wechat(amount='一 10 ． 90', transfer=False, status='支付成功', refund=None):
    lines = [row(amount, x=500, y=1300, height=74, width=300)]
    fields = [('当前状态', status, 1650),
              ('转账时间' if transfer else '支付时间', '2026年1 1月2日1 8：10：14', 1750),
              ('转账单号' if transfer else '交易单号', '9999000011112222333344445555', 2200)]
    if refund is not None:
        fields.append(('退款记录', refund, 1500))
    for label, value, y in fields:
        lines.extend([row(label, x=100, y=y, width=190), row(value, y=y)])
    return dict(text=' '.join(r['text'] for r in lines), width=1316, height=2832, lines=lines)


def bank():
    lines = [row('一 880 ℃ 0', y=312, height=86), row('余额：12,345.67', y=446)]
    for label, value, y in [('交易时间','2026一10一08 14：51：20',900),
                            ('交易金额','880 ， 00',1200), ('记账金额','880 ， 00',1600),
                            ('记账币种','人民币',1700),('对方户名','示例协会',2000)]:
        lines.extend([row(label,x=36,y=y), row(value,x=1000,y=y)])
    return dict(text='收支详情 '+' '.join(r['text'] for r in lines),width=1316,height=2598,lines=lines)


def replace(data, before, after):
    for r in data['lines']:
        if r['text'] == before:
            r['text'] = after
    data['text'] = data['text'].replace(before,after)


class PaymentLayoutOcrTests(unittest.TestCase):
    def test_wechat_middle_amount_chinese_date_and_unknown_category(self):
        data=wechat()
        result=enrich_ocr(data)
        self.assertEqual(result['paymentCandidate']['cents'],1090)
        self.assertEqual(result['paymentDateTime'],'2026-11-02T18:10:14+08:00')
        self.assertIsNone(result['category'])
        self.assertEqual(result['paymentTransactionId'],'9999000011112222333344445555')
        self.assertNotIn('paymentCandidate',data)

    def test_state_must_be_success_and_generic_success_page_is_supported(self):
        for data in [wechat(status='支付中'),wechat(status='交易关闭'),wechat(status='退款成功')]:
            self.assertNotIn('paymentCandidate',enrich_ocr(data))
        data=wechat();replace(data,'当前状态','说明')
        # 不再要求某一种平台固定的状态标签；成功状态与支付时间仍可提供上下文。
        self.assertEqual(enrich_ocr(data)['paymentCandidate']['cents'],1090)

    def test_detail_amount_and_equal_size_conflicting_amounts_not_selected(self):
        data=wechat();data['lines'].append(row('999.00',y=2000,height=100))
        self.assertEqual(enrich_ocr(data)['paymentCandidate']['cents'],1090)
        data['lines'].append(row('44.00',x=500,y=1400,height=74,width=300))
        self.assertNotIn('paymentCandidate',enrich_ocr(data))

    def test_wrapped_transfer_id_and_date(self):
        data=wechat(transfer=True)
        data['lines'].append(row('6666',y=2265))
        result=enrich_ocr(data)
        self.assertEqual(result['paymentTransactionId'],'99990000111122223333444455556666')
        self.assertEqual(result['paymentDate'],'2026-11-02')

    def test_ride_service_description_can_identify_local_without_brand_logo(self):
        data=wechat();data['text']+=' 先乘车后付款'
        self.assertEqual(enrich_ocr(data)['category'],'local')

    def test_partial_refund_uses_net_and_reenrichment_does_not_double_subtract(self):
        original=wechat('一1500.00',status='已退款（¥480.00）',refund='已退款¥480.00〉')
        before=copy.deepcopy(original)
        result=enrich_ocr(original)
        self.assertEqual(result['paymentCandidate']['cents'],102000)
        self.assertEqual(result['refundCandidate']['grossCents'],150000)
        self.assertEqual(result['refundCandidate']['cents'],48000)
        self.assertEqual(result['direction'],'expense')
        self.assertEqual(enrich_ocr(result)['paymentCandidate']['cents'],102000)
        self.assertEqual(original,before)

    def test_full_refund_conflicting_or_missing_refund_evidence_remains_unknown(self):
        for status,refund in [('已退款（¥480.00）',None),('已退款（¥480.00）','已退款¥470.00〉'),
                              ('已退款（¥1500.00）','已退款¥1500.00〉'),
                              ('已退款（¥1600.00）','已退款¥1600.00〉')]:
            self.assertNotIn('paymentCandidate',enrich_ocr(wechat('一1500.00',status=status,refund=refund)))

    def test_bank_uses_consistent_rmb_fields_not_balance_or_corrupted_header(self):
        result=enrich_ocr(bank())
        self.assertEqual(result['paymentCandidate']['cents'],88000)
        self.assertEqual(result['paymentDateTime'],'2026-10-08T14:51:20+08:00')
        self.assertEqual(result['payeeName'],'示例协会')

    def test_bank_income_foreign_currency_and_conflicting_amounts_not_accepted(self):
        for before,after in [('一 880 ℃ 0','+880.00'),('人民币','美元'),('记账金额','其他金额')]:
            data=bank();replace(data,before,after)
            self.assertNotIn('paymentCandidate',enrich_ocr(data))
        data=bank();data['lines'][-5]['text']='881.00'
        self.assertNotIn('paymentCandidate',enrich_ocr(data))
        data=bank();data['lines'].append(row('1.00',x=1000,y=1200))
        self.assertNotIn('paymentCandidate',enrich_ocr(data))

    def test_payee_wrapping_stops_before_next_field(self):
        data=dict(lines=[row('商户全称',x=100,y=1755),
                         row('示例文化发展有限公司测试万',y=1755),row('枫酒店分公司',y=1825),
                         row('收单机构',x=100,y=1923),row('示例银行',y=1923)])
        self.assertEqual(payment_payee(data),'示例文化发展有限公司测试万枫酒店分公司')
        data['lines'][-2]['y']=1825
        self.assertEqual(payment_payee(data),'示例文化发展有限公司测试万')

    def test_fuzzy_wechat_amount_requires_two_confirmations_and_rejects_conflict(self):
        def crop(text):return dict(lines=[row(text)],text=text)
        for retries,expected in [([crop('11.00'),crop('一1t00'),crop('11.00')],1100),
                                  ([crop('11.00'),crop('12.00'),crop('11.00')],None),
                                  ([crop('一1t00'),crop('一1t00'),crop('11.00')],None),
                                  ([crop('11.00'),crop('一1t00'),dict(available=False)],None)]:
            with self.subTest(expected=expected),tempfile.TemporaryDirectory() as folder:
                path=Path(folder)/'payment.png';Image.new('RGB',(1316,2832),'white').save(path)
                with patch('ocr.os.name','nt'),patch('ocr._run_ocr',side_effect=[wechat('一1t00'),*retries]):
                    result=recognize_image(str(path))
                self.assertEqual(result.get('paymentCandidate',{}).get('cents'),expected)
                if expected:self.assertEqual(enrich_ocr(result)['paymentCandidate']['cents'],expected)


if __name__ == '__main__':unittest.main()
