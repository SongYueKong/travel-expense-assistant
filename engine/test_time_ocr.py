import unittest
from ocr import enrich_ocr

def line(text, x=40, y=500, height=30):
    return dict(text=text, x=x, y=y, height=height)

def ocr(lines):
    return dict(text='账单详情 滴滴 支付成功', height=2000, width=1000, lines=lines)

class TimeOcrTests(unittest.TestCase):
    def test_inline_and_adjacent_fields_remain_separate(self):
        parsed = enrich_ocr(ocr([
            line('乘车时间 2026-10-27 23:58:30'),
            line('支付时间', y=600), line('2026-10-28 00:18:40', x=300, y=603),
            line('08:30', y=10)]))
        self.assertEqual(parsed['rideDateTime'], '2026-10-27T23:58:30+08:00')
        self.assertEqual(parsed['paymentDateTime'], '2026-10-28T00:18:40+08:00')
        self.assertEqual(parsed['paymentDate'], '2026-10-28')

    def test_fullwidth_and_ocr_separator(self):
        parsed = enrich_ocr(ocr([line('上车时间'),
            line('２０２６ 一 １０ 一 ２７ １８：５８：５０', x=300, y=502)]))
        self.assertEqual(parsed['rideDateTime'], '2026-10-27T18:58:50+08:00')

    def test_no_time_from_unrelated_row_date_only_or_invalid_date(self):
        for rows in [[line('支付时间'),line('2026-10-27 10:00',x=300,y=700)],
                     [line('支付时间 2026-10-27')],
                     [line('支付时间 2026-02-30 10:00')],
                     [line('订单创建时间 2026-10-27 10:00')]]:
            self.assertNotIn('paymentDateTime', enrich_ocr(ocr(rows)))

    def test_equally_close_conflicting_values_remain_unknown(self):
        parsed = enrich_ocr(ocr([line('乘车时间'),
            line('2026-10-27 10:00',x=300,y=499),
            line('2026-10-27 11:00',x=300,y=501)]))
        self.assertNotIn('rideDateTime',parsed)

    def test_cached_enrichment_recalculates_without_mutating_input(self):
        data = ocr([line('支付时间 2026-10-27 10:00')])
        data.update(available=True,rideDateTime='stale',paymentDateTime='stale')
        parsed = enrich_ocr(data)
        self.assertEqual(parsed['paymentDateTime'],'2026-10-27T10:00:00+08:00')
        self.assertNotIn('rideDateTime',parsed)
        self.assertEqual(data['rideDateTime'],'stale')

if __name__ == '__main__': unittest.main()
