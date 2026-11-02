import unittest
from documents import parse_pdf
from ocr import enrich_ocr

ITINERARY = ('高德地图—打车——行程单 AMAP ITINERARY\n申请时间：2026-10-18\n'
             '共计2单行程，合计50.00元\n序号 服务商 车型 上车时间 城市 起点 终点 金额\n'
             '1 及时用\n车特选 特惠快车 2026-10-15 09:02 郑州市 起点 终点 37.85元\n'
             '2 T3出行 舒适车型 2026-10-16 10:10 无锡市 起点 终点 12.15元\n页码：1/1')

class GaodeTests(unittest.TestCase):
    def test_multiline_provider_and_full_dates(self):
        result = parse_pdf(ITINERARY)
        self.assertTrue(result['complete'])
        self.assertEqual(result['platform'], 'gaode')
        self.assertEqual([r['cents'] for r in result['trips']], [3785, 1215])
        self.assertEqual(result['trips'][0]['serviceProvider'], '及时用车特选')
        self.assertEqual(result['trips'][0]['date'], '2026-10-15')
        self.assertEqual(result['trips'][1]['vehicleType'], '舒适车型')

    def test_incomplete_conflicting_or_invalid_trips_not_accepted(self):
        for text in [ITINERARY.replace('共计2单', '共计3单'), ITINERARY.replace('50.00', '50.01'),
                     ITINERARY.replace('2 T3', '1 T3'), ITINERARY.replace('2026-10-16', '2026-02-30'),
                     ITINERARY.replace('12.15元', '金额缺失')]:
            self.assertFalse(parse_pdf(text)['complete'])

    def test_transport_invoice_uses_original_attachment_name(self):
        text = '电子发票（普通发票） *交通运输服务*客运服务 价税合计 ¥37.85'
        self.assertIsNone(parse_pdf(text)['category'])
        result = parse_pdf(text, source_name='【服务商】高德打车电子发票.pdf')
        self.assertEqual((result['category'], result['platform'], result['totalCents']), ('local', 'gaode', 3785))
        self.assertIsNone(parse_pdf('电子发票 餐饮费 ¥37.85', source_name='高德打车电子发票.pdf')['category'])
        self.assertEqual(parse_pdf('电子发票 *住宿费 ¥37.85', source_name='高德打车电子发票.pdf')['category'], 'hotel')

    def test_explicit_gaode_payment_is_local_and_not_didi(self):
        result = enrich_ocr(dict(text='账单详情 高德打车 支付成功', height=2000, width=1000,
                                 lines=[dict(text='-37.85', x=300, y=500, height=60)]))
        self.assertEqual((result['category'], result['platform']), ('local', 'gaode'))
        self.assertEqual(result['paymentCandidate']['cents'], 3785)

if __name__ == '__main__': unittest.main()
