"""金额区域补识别：只接受两种裁剪结果一致的明确金额。"""
import copy
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from PIL import Image
from ocr import enrich_ocr, recognize_image


def row(text, x=470, y=647, width=281, height=74):
    return dict(text=text, x=x, y=y, width=width, height=height)


def raw(text='账单详情 中国铁路 交易成功', amount='一 4 & 00'):
    return dict(text=text+' '+amount, height=2700, width=1224, lines=[row(amount)])


def crop(text):
    return dict(lines=[row(text)], text=text)


class AmountRetryTests(unittest.TestCase):
    def recognize(self, original, *retries):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)/'payment.png'
            Image.new('RGB', (1224, 2700), 'white').save(path)
            with patch('ocr.os.name', 'nt'), patch('ocr._run_ocr', side_effect=[original, *retries]) as run:
                result = recognize_image(str(path))
                return result, run.call_count

    def test_consistent_crop_recovers_amount_and_retains_original(self):
        original = raw()
        snapshot = copy.deepcopy(original)
        parsed, calls = self.recognize(original, crop('一 48 ． 00'), crop('-48.00'))
        self.assertEqual(calls, 3)
        self.assertEqual(parsed['paymentCandidate']['cents'], 4800)
        self.assertEqual(parsed['paymentCandidate']['source']['text'], '一 4 & 00')
        self.assertEqual(parsed['text'], snapshot['text'])
        self.assertEqual(parsed['lines'], snapshot['lines'])
        self.assertEqual(enrich_ocr(parsed)['paymentCandidate']['cents'], 4800)

    def test_ambiguous_character_is_never_directly_substituted(self):
        self.assertNotIn('paymentCandidate', enrich_ocr(raw()))

    def test_conflicting_or_unreadable_crops_remain_unknown(self):
        for first, second in [('48.00', '43.00'), ('48.00', '一 4 & 00')]:
            with self.subTest(first=first, second=second):
                result, _ = self.recognize(raw(), crop(first), crop(second))
                self.assertNotIn('paymentCandidate', result)

    def test_empty_or_multiple_numbers_remain_unknown(self):
        for retry in [dict(lines=[], text=''), dict(lines=[row('48.00'), row('43.00')], text='48.00 43.00')]:
            result, _ = self.recognize(raw(), retry, crop('48.00'))
            self.assertNotIn('paymentCandidate', result)

    def test_refund_and_unsupported_pages_do_not_retry(self):
        for text in ['账单详情 交易成功 退款成功', '优惠券 48元']:
            result, calls = self.recognize(raw(text))
            self.assertEqual(calls, 1)
            self.assertNotIn('paymentCandidate', result)

    def test_existing_valid_amount_does_not_retry(self):
        result, calls = self.recognize(raw(amount='-46.06'))
        self.assertEqual(calls, 1)
        self.assertEqual(result['paymentCandidate']['cents'], 4606)

    def test_retry_failure_preserves_raw_text(self):
        original = raw()
        result, _ = self.recognize(original, dict(available=False))
        self.assertEqual(result['text'], original['text'])
        self.assertNotIn('paymentCandidate', result)

    def test_missing_geometry_and_merchant_names_do_not_retry(self):
        for amount in ['铁路12306', '一 4 & 00']:
            original = raw(amount=amount)
            if '&' in amount: original['lines'][0].pop('width')
            result, calls = self.recognize(original)
            self.assertEqual(calls, 1)
            self.assertNotIn('paymentCandidate', result)


if __name__ == '__main__':
    unittest.main()
