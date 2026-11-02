import unittest
from unittest.mock import patch
from pathlib import Path
import tempfile
from PIL import Image, PngImagePlugin
from ocr import enrich_ocr
from worker import inspect_file

def row(text,x=40,y=500):return dict(text=text,x=x,y=y,height=30)
def parsed(rows,text='账单详情 支付成功'):
    return enrich_ocr(dict(text=text,height=2000,width=1000,lines=rows))

class PaymentIdentityTests(unittest.TestCase):
    def test_full_inline_and_separate_transaction_ids(self):
        transaction='2026102722001456789012345678'
        for rows in [[row('交易号 '+transaction)],
                     [row('支付宝交易号'),row(transaction,x=300,y=501)]]:
            self.assertEqual(parsed(rows)['paymentTransactionId'],transaction)

    def test_order_number_masked_id_ambiguous_id_and_refund_are_not_transaction_evidence(self):
        for rows,text in [([row('商户订单号 20261027000000001')],'账单详情 支付成功'),
                          ([row('交易号 2026****00000001')],'账单详情 支付成功'),
                          ([row('交易号 20261027000000001'),row('交易号 20261027000000002',y=700)],'账单详情 支付成功'),
                          ([row('交易号 20261027000000001')],'账单详情 支付成功 已退款')]:
            self.assertNotIn('paymentTransactionId',parsed(rows,text))

    def test_nearby_other_row_is_not_mistaken_for_transaction_id(self):
        self.assertNotIn('paymentTransactionId',parsed([
            row('交易号'),row('20261027000000001',x=300,y=600)]))

    def test_decoded_pixel_identity_ignores_file_metadata_and_lossless_format(self):
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder);im=Image.new('RGB',(24,36),'white')
            im.putpixel((2,2),(20,80,120))
            a=root/'a.png';b=root/'b.png';c=root/'c.bmp';different=root/'different.png'
            im.save(a);info=PngImagePlugin.PngInfo();info.add_text('Comment','different metadata');im.save(b,pnginfo=info)
            # 检查同解码像素；支持的 PNG 文件也可使用不同压缩级别。
            im.save(c,format='PNG',compress_level=0)
            im.putpixel((2,2),(21,80,120));im.save(different)
            with patch('worker.recognize_image',return_value={'available':False}):
                x=inspect_file(str(a),str(root/'materials'))
                y=inspect_file(str(b),str(root/'materials'))
                zfile=root/'c.png';c.rename(zfile);z=inspect_file(str(zfile),str(root/'materials'))
                other=inspect_file(str(different),str(root/'materials'))
            self.assertNotEqual(x['hash'],y['hash'])
            self.assertEqual(x['imagePixelHash'],y['imagePixelHash'])
            self.assertEqual(x['imagePixelHash'],z['imagePixelHash'])
            self.assertNotEqual(x['imagePixelHash'],other['imagePixelHash'])
            self.assertTrue(a.exists() and b.exists())

if __name__=='__main__':unittest.main()
