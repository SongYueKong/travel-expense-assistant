import unittest
from documents import parse_pdf
from ocr import enrich_ocr

class ParsingTests(unittest.TestCase):
    def test_didi_english_logo_service_fee_keeps_one_yuan_and_local_category(self):
        for brand in ['didi','DiDi','DIDI']:
            text=('开票人：测试人员\n'+brand+'\n电子发票（普通发票）\n'
                  '发票号码：99990000000000000008\n开票日期：2026年11月03日\n'
                  '名称：示例出行科技有限公司\n*生产生活服务*信息技\n术服务费\n'
                  '合计 0.94¥ 0.06¥\n价税合计（小写）1.00¥')
            parsed=parse_pdf(text)
            self.assertEqual(parsed['type'],'invoice')
            self.assertEqual(parsed['category'],'local')
            self.assertEqual(parsed['platform'],'didi')
            self.assertEqual(parsed['totalCents'],100)
            self.assertEqual(parsed['expenseKind'],'platformServiceFee')
            self.assertEqual(parsed['issueDate'],'2026-11-03')

    def test_service_fee_label_split_by_numeric_invoice_columns(self):
        text=('didi\n电子发票（普通发票）\n'
              '*生产生活服务*信息技 次 1 0.94 0.94 6% 0.06\n'
              '术服务费\n合计 0.94¥ 0.06¥\n价税合计（小写）1.00¥')
        parsed=parse_pdf(text)
        self.assertEqual(parsed['category'],'local')
        self.assertEqual(parsed['expenseKind'],'platformServiceFee')
        self.assertEqual(parsed['totalCents'],100)
        parsed=parse_pdf(text.replace('didi\n',''),source_name='滴滴电子发票.pdf')
        self.assertEqual(parsed['category'],'local')
        self.assertEqual(parsed['expenseKind'],'platformServiceFee')

    def test_didi_filename_requires_transport_or_service_item(self):
        text='电子发票 *生产生活服务*信息技术服务费 ¥1.00'
        self.assertIsNone(parse_pdf(text)['category'])
        parsed=parse_pdf(text,source_name='滴滴电子发票.pdf')
        self.assertEqual(parsed['category'],'local')
        self.assertEqual(parsed['totalCents'],100)
        self.assertIsNone(parse_pdf('电子发票 咨询费 ¥100.00',source_name='滴滴资料.pdf')['category'])
        self.assertIsNone(parse_pdf(text+' candidate')['category'])
        self.assertIsNone(parse_pdf(text+' didicloud')['category'])

    def test_didi_brand_does_not_override_explicit_hotel_or_rail_category(self):
        for item, category, platform in [('住宿费','hotel',None),('铁路电子客票','intercity','rail')]:
            parsed=parse_pdf('电子发票 didi '+item+' ¥48.00',source_name='滴滴电子发票.pdf')
            self.assertEqual(parsed['category'],category)
            self.assertEqual(parsed['platform'],platform)
            self.assertNotIn('expenseKind',parsed)
        normal=parse_pdf('电子发票 滴滴 客运服务 ¥48.00')
        self.assertEqual(normal['category'],'local')
        self.assertEqual(normal['platform'],'didi')
        self.assertNotIn('expenseKind',normal)

    def test_hotel_split_header_uses_layout_issue_date_not_checkin(self):
        text = ('电子发票 发票号码：\n开票日期：\n99990000000000000001\n2026年10月16日\n'
                '*住宿费 ¥330.00\n2026年10月15日入住-10月16日离店')
        self.assertNotIn('issueDate', parse_pdf(text))
        parsed = parse_pdf(text, layout_text='开票日期：2026年10月16日\n入住：2026年10月15日')
        self.assertEqual(parsed['issueDate'], '2026-10-16')
        self.assertEqual(parsed['issueDateMethod'], 'layout-labelled')
        self.assertEqual(parsed['totalCents'], 33000)

    def test_invalid_or_conflicting_layout_issue_dates_remain_unknown(self):
        text = '电子发票 开票日期：\n2026年10月16日\n2026年10月15日入住 *住宿费 ¥330.00'
        for layout in ['开票日期：2026年02月30日',
                       '开票日期：2026年10月16日\n开票日期：2026年10月17日',
                       '入住日期：2026年10月15日']:
            self.assertNotIn('issueDate', parse_pdf(text, layout_text=layout))

    def test_currency_total_and_separated_invoice_header(self):
        parsed=parse_pdf('电子发票（普通发票） 发票号码：\n开票日期：\n99990000000000000002\n2026年10月29日\n*住宿费 858.08 51.48\n价税合计 ¥909.56\n858.08¥ 51.48¥')
        self.assertEqual(parsed['totalCents'],90956)
        self.assertEqual(parsed['category'],'hotel')
        self.assertEqual(parsed['issueDate'],'2026-10-29')
        self.assertTrue(parsed['needsReview'])

    def test_itinerary_requires_all_rows_and_correct_total(self):
        text='滴滴出行-行程单\n申请日期：2026-10-29 共2笔行程，合计68.50元\n1 特惠\n快车 10-27 18:48\n北京 起点 终点 21.5 46.50\n2 快车 10-28 13:48\n北京 起点 终点 6.8 22.00\n页码：1/1'
        parsed=parse_pdf(text)
        self.assertTrue(parsed['complete'])
        self.assertEqual([t['cents'] for t in parsed['trips']],[4650,2200])
        self.assertFalse(parse_pdf(text.replace('共2笔','共3笔'))['complete'])
        self.assertFalse(parse_pdf(text.replace('68.50','68.51'))['complete'])

    def test_negative_expense_and_center_dot_not_notification(self):
        data=dict(text='账 单 详 情 中国铁路 交 易 成 功',height=2772,width=1272,lines=[
            dict(text='¥571·00',x=600,y=50,height=30),
            dict(text='一 371 · 00',x=460,y=649,height=78),
            dict(text='支付时间',x=50,y=900,height=35),
            dict(text='2026 一 10 一 26 09：12：48',x=400,y=904,height=34)])
        parsed=enrich_ocr(data)
        self.assertEqual(parsed['paymentCandidate']['cents'],37100)
        self.assertEqual(parsed['paymentDate'],'2026-10-26')
        self.assertEqual(parsed['category'],'intercity')

    def test_itinerary_b_recognizes_split_vehicle_name(self):
        text=('滴滴出行-行程单\n申请日期：2026-10-29 共2笔行程，合计93.39元\n'
              '1 快车 10-27 15:21 周\n二\n郑州\n市\n起点 终点 27.5 47.10\n'
              '2 甄选快\n车\n10-29 18:56 周\n四\n郑州\n市\n起点 终点 25.6 46.29\n页码：1/1')
        parsed=parse_pdf(text)
        self.assertTrue(parsed['complete'])
        self.assertEqual(parsed['expectedCount'],2)
        self.assertEqual([t['cents'] for t in parsed['trips']],[4710,4629])
        self.assertEqual([t['vehicleType'] for t in parsed['trips']],['快车','甄选快车'])
        self.assertEqual(parsed['trips'][1]['date'],'2026-10-29')
        self.assertEqual(parsed['trips'][1]['time'],'18:56')

    def test_itinerary_new_vehicle_types_and_row_integrity(self):
        text=('滴滴出行-行程单 申请日期：2026-10-29 共2笔行程，合计93.39元\n'
              '1 特惠\n拼车 10-27 15:21\n起点 终点 27.5 47.10\n'
              '2 专车-舒适型 10-29 18:56\n起点 终点 25.6 46.29')
        self.assertTrue(parse_pdf(text)['complete'])
        self.assertFalse(parse_pdf(text.replace('2 专车','1 专车'))['complete'])
        self.assertFalse(parse_pdf(text.replace('93.39','93.40'))['complete'])
        self.assertFalse(parse_pdf(text.replace('25.6 46.29','金额缺失'))['complete'])

    def test_refund_not_used_as_expense(self):
        data=dict(text='账单详情 支付成功 退款成功',height=2772,width=1272,
                  lines=[dict(text='46．50',x=500,y=649,height=78)])
        parsed=enrich_ocr(data)
        self.assertNotIn('paymentCandidate',parsed)
        self.assertEqual(parsed['direction'],'refund')

    def test_ambiguous_invoice_number_remains_unknown(self):
        parsed=parse_pdf('电子发票 99990000000000000002 99990000000000000003 ¥100.00')
        self.assertIsNone(parsed['number'])

if __name__=='__main__': unittest.main()
