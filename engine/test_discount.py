import unittest
from ocr import enrich_ocr
class DiscountTests(unittest.TestCase):
    def data(self,rows,text='账单详情 支付成功 滴滴'):
        return dict(text=text,height=2772,width=1272,lines=[dict(text='-46.50',x=460,y=650,height=78),*[dict(text=t,x=x,y=y,height=35) for t,x,y in rows]])
    def test_inline_and_separate_discount_currency_and_fullwidth(self):
        for rows in [[('优惠 -3.50元',50,1000)],[('商家优惠',50,1000),('−３．５０',400,1000)],[('优惠券:-￥3.50',50,1000)]]:
            data=enrich_ocr(self.data(rows));self.assertEqual(data['discountCandidate']['cents'],350);self.assertEqual(data['paymentCandidate']['cents'],4650)
    def test_multiple_components_and_total_not_double_counted(self):
        rows=[('商家优惠-1.00',50,1000),('平台优惠-2.50',50,1100)]
        self.assertEqual(enrich_ocr(self.data(rows))['discountCandidate']['cents'],350)
        rows.append(('优惠合计-3.50',50,1200))
        self.assertEqual(enrich_ocr(self.data(rows))['discountCandidate']['cents'],350)
    def test_unlabelled_negative_refund_positive_and_ambiguous_values_not_discounts(self):
        cases=[self.data([]),self.data([('订单金额-3.50',50,1000)]),self.data([('优惠+3.50',50,1000)]),self.data([('优惠',50,1000),('-3.50',400,1000),('-4.00',600,1000)]),self.data([('优惠-3.50',50,1000)],text='账单详情 退款成功')]
        for data in cases:self.assertNotIn('discountCandidate',enrich_ocr(data))
    def test_generic_total_and_components_are_not_added_twice(self):
        rows=[('优惠-3.50',50,1000),('商家优惠-1.00',50,1100),('平台优惠-2.50',50,1200)]
        self.assertEqual(enrich_ocr(self.data(rows))['discountCandidate']['cents'],350)

    def test_enrichment_clears_stale_discount(self):
        data=self.data([]);data['discountCandidate']={'cents':999};self.assertNotIn('discountCandidate',enrich_ocr(data))
if __name__=='__main__':unittest.main()
