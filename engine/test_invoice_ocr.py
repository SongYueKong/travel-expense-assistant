"""扫描发票后备识别：明确合计、冲突和引擎回退边界。仅使用合成数据。"""
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch
from pypdf import PdfWriter
from invoice_ocr import parse_invoice_ocr, recognize_invoice_pdf
from worker import inspect_file


def ocr(*texts):
    return dict(available=True, lines=[dict(text=t,x=0,y=i*40,width=600,height=20)
                                      for i,t in enumerate(texts)])


class InvoiceOcrTest(unittest.TestCase):
    def test_explicit_total_overrides_item_and_tax(self):
        _, doc = parse_invoice_ocr(ocr('电子发票 铁路电子客票',
            '发票号码:26000000000000000001', '金额￥3301.89', '税额￥198.11',
            '价税合计(小写)￥3500.00'))
        self.assertEqual(doc['type'], 'invoice')
        self.assertEqual(doc['totalCents'], 350000)
        self.assertEqual(doc['number'], '26000000000000000001')

    def test_conflict_missing_total_and_non_invoice_are_not_guessed(self):
        for rows in [('电子发票', '项目￥3500.00'),
                     ('电子发票', '小写￥3500.00', '价税合计￥3400.00'),
                     ('账单详情', '小写￥3500.00'),
                     ('红字电子发票', '小写￥3500.00'),
                     ('电子发票', '小写-3500.00'),
                     ('电子发票', '小写￥3500.00', '26000000000000000001', '26000000000000000002')]:
            with self.subTest(rows=rows):
                self.assertIsNone(parse_invoice_ocr(ocr(*rows))[1]['totalCents'])

    def test_split_label_and_value_use_relative_geometry(self):
        raw=ocr('电子发票', '(小写)', '￥48.00')
        raw['lines'][1].update(x=0,y=80,width=70)
        raw['lines'][2].update(x=100,y=80,width=100)
        self.assertEqual(parse_invoice_ocr(raw)[1]['totalCents'],4800)

    def test_scanned_pdf_uses_ocr_only_when_explicitly_imported_as_invoice(self):
        with tempfile.TemporaryDirectory() as temp:
            path=Path(temp)/'blank.pdf'
            writer=PdfWriter();writer.add_blank_page(width=600,height=400);writer.write(path)
            original=path.read_bytes()
            raw=ocr('电子发票 铁路电子客票', '发票号码:26000000000000000001', '小写￥48.00')
            with patch('invoice_ocr._run_ocr',return_value=raw) as run:
                plain=inspect_file(str(path),str(Path(temp)/'materials'))
                self.assertEqual(run.call_count,0)
                result=inspect_file(str(path),str(Path(temp)/'materials'),purpose='invoice')
            self.assertTrue(plain['needsOcr'])
            self.assertEqual(result['document']['totalCents'],4800)
            self.assertEqual(result['purpose'],'invoice')
            self.assertEqual(path.read_bytes(),original)

    def test_multi_page_scans_and_unavailable_ocr_remain_for_manual_review(self):
        with tempfile.TemporaryDirectory() as temp:
            path=Path(temp)/'scan.pdf'
            writer=PdfWriter();writer.add_blank_page(width=600,height=400);writer.add_blank_page(width=600,height=400);writer.write(path)
            with patch('invoice_ocr._run_ocr') as run:
                self.assertFalse(recognize_invoice_pdf(str(path))['available'])
                run.assert_not_called()
            with patch('invoice_ocr.recognize_invoice_pdf',side_effect=OSError('unavailable')):
                result=inspect_file(str(path),str(Path(temp)/'materials'),purpose='invoice')
            self.assertTrue(result['needsOcr'])
            self.assertEqual(result['document']['type'],'unknown')
            self.assertIn('人工录入',result['ocrReason'])


if __name__=='__main__': unittest.main()
