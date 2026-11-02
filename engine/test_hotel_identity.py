import unittest
from hotel_identity import payment_payee,invoice_seller
class Page:
    def extract_text(self,visitor_text=None):
        if visitor_text:
            for text,x,y in [('销',300,296),('名称：',316,293),('销售酒店有限公司',340,293),('购买公司',50,293)]:visitor_text(text,None,[1,0,0,1,x,y],None,10)
        return ''
class HotelIdentityTests(unittest.TestCase):
    def test_layout_seller_fallback_keeps_buyer_column_separate(self):
        class LayoutPage:
            def extract_text(self, visitor_text=None, extraction_mode=None):
                return ('购 名称：购买单位   销 名称：销售酒店有限公司\n'
                        '买 统一社会信用代码：123   售 统一社会信用代码：456') if extraction_mode else ''
        reader=type('Reader',(),{'pages':[LayoutPage()]})()
        self.assertEqual(invoice_seller(reader), '销售酒店有限公司')

    def test_layout_seller_fallback_rejects_ambiguous_or_unlabelled_names(self):
        class LayoutPage:
            def __init__(self, text): self.text = text
            def extract_text(self, visitor_text=None, extraction_mode=None):
                return self.text if extraction_mode else ''
        for text in ['购 名称：购买单位', '销 名称：A酒店\n销 名称：B酒店']:
            reader=type('Reader',(),{'pages':[LayoutPage(text)]})()
            self.assertIsNone(invoice_seller(reader))

    def test_invoice_reads_seller_column_not_buyer(self):
        reader=type('Reader',(),{'pages':[Page()]})();self.assertEqual(invoice_seller(reader),'销售酒店有限公司')
    def test_payee_explicit_label_with_adjacent_row(self):
        def row(text,x,y):return dict(text=text,x=x,y=y,height=40)
        data={'lines':[row('收 款 方 全 称',50,100),row('收 款 酒 店 （ 上 海 ） 有 限 公 司',400,100),row('购买公司',400,200)]}
        self.assertEqual(payment_payee(data),'收款酒店(上海)有限公司')
    def test_missing_or_ambiguous_field_is_not_assumed_equal(self):
        self.assertIsNone(payment_payee({'lines':[]}))
        data={'lines':[dict(text='收款方：A公司',x=0,y=0,height=20),dict(text='收款方：B公司',x=0,y=100,height=20)]}
        self.assertIsNone(payment_payee(data))
if __name__=='__main__':unittest.main()
