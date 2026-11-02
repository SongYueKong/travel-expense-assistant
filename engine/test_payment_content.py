import copy
import base64
from pathlib import Path
import tempfile
import unittest
from PIL import Image, ImageDraw, ImageFont
from ocr import enrich_ocr
from payment_content import payment_content_evidence


def line(text, x, y, height=40):
    return dict(text=text, x=x, y=y, height=height)


def bill_data():
    rows = [line('46.06', 300, 300, 60)]
    for label, value, y in [('订单金额', '46.29', 600), ('支付时间', '2026-10-29 19:50:22', 700),
                            ('付款方式', '支付宝小荷包(白松包)', 800),
                            ('商品说明', '滴滴快车打车-白师傅-10月29日行程', 900),
                            ('乘车时间', '2026-10-29 18:51:46', 1000)]:
        rows += [line(label, 20, y), line(value, 200, y)]
    return enrich_ocr(dict(text='账单详情 滴滴出行 自动扣款成功', height=1800, width=1000, lines=rows))


class ContentTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.path = Path(self.temp.name)/'bill.png'
        image = Image.new('RGB', (1000, 1800), 'white')
        draw = ImageDraw.Draw(image)
        font_path = Path('C:/Windows/Fonts/segoeui.ttf')
        font = ImageFont.truetype(str(font_path), 32) if font_path.exists() else ImageFont.load_default()
        for text, x, y in [('46.06', 300, 300), ('46.29', 200, 600), ('2026-10-29 19:50:22', 200, 700),
                            ('Alipay account', 200, 800), ('Didi ride - driver Bai', 200, 900),
                            ('2026-10-29 18:51:46', 200, 1000)]:
            draw.text((x, y), text, fill='black', font=font)
        image.save(self.path)

    def tearDown(self): self.temp.cleanup()

    def test_bill_body_evidence_does_not_include_status_bar_or_floating_banner(self):
        data = bill_data()
        before = payment_content_evidence(self.path, data)
        self.assertIsNotNone(before)
        with Image.open(self.path) as im:
            draw = ImageDraw.Draw(im);draw.rectangle((0, 0, 1000, 180), fill='black');im.save(self.path)
        after = payment_content_evidence(self.path, data)
        self.assertEqual(before, after)
        self.assertEqual(before['facts']['cents'], 4606)
        self.assertEqual(set(before['rows']), {'amount', 'orderAmount', 'description', 'method', 'paymentDateTime', 'rideDateTime'})

    def test_incomplete_time_context_or_different_direction_cannot_create_identity(self):
        data = bill_data()
        for change in [lambda d:d.pop('rideDateTime'), lambda d:d.pop('paymentDateTimeSource'),
                       lambda d:d.update(direction='refund'), lambda d:d.update(paymentTransactionId='20261029000000000001')]:
            changed = copy.deepcopy(data);change(changed)
            self.assertIsNone(payment_content_evidence(self.path, changed))
        data['rideDateTimeSource']['text'] = '2026-10-29 18:51'
        self.assertIsNone(payment_content_evidence(self.path, data))

    def test_field_images_change_even_when_ocr_mistakenly_reports_same_text(self):
        data = bill_data();before = payment_content_evidence(self.path, data)
        with Image.open(self.path) as im:
            ImageDraw.Draw(im).rectangle((300, 300, 470, 345), fill='white');im.save(self.path)
        after = payment_content_evidence(self.path, data)
        self.assertTrue(after is None or before['rows']['amount']['bits'] != after['rows']['amount']['bits'])

    def test_single_digit_change_is_larger_than_allowed_compression_noise(self):
        data = bill_data();before = payment_content_evidence(self.path, data)
        font_path = Path('C:/Windows/Fonts/segoeui.ttf')
        if not font_path.exists(): self.skipTest('Windows 字体回归使用本机 Segoe UI')
        with Image.open(self.path) as im:
            draw = ImageDraw.Draw(im);draw.rectangle((190, 695, 900, 745), fill='white')
            draw.text((200, 700), '2026-10-29 19:30:22', fill='black', font=ImageFont.truetype(str(font_path), 32));im.save(self.path)
        # 模拟不同截图的 3/5 被 OCR 识别为相同值；字形校验仍必须拒绝合并。
        after = payment_content_evidence(self.path, data)
        a,b=[base64.b64decode(e['rows']['paymentDateTime']['bits'])for e in [before,after]]
        changed=sum((p^q).bit_count()for p,q in zip(a,b))
        ink=min(e['rows']['paymentDateTime']['ink']for e in [before,after])
        self.assertGreater(changed, max(3, ink*.005))


if __name__ == '__main__': unittest.main()
