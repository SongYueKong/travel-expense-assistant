from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
from PIL import Image
from pypdf import PdfReader
from reportlab.pdfgen import canvas
from reportlab.lib.units import mm
from taxi_pages import build_taxi_pages
from worker import export_pdf


class TaxiPageTests(unittest.TestCase):
    def test_four_columns_fixed_size_on_full_and_partial_pages(self):
        expected = None
        for count in [1, 4, 5, 9]:
            entries = [dict(number=f'{i+1:03d}', paperTaxi=True) for i in range(count)]
            with patch('taxi_pages.canvas.Canvas') as factory:
                build_taxi_pages(entries, 'unused.pdf')
                c = factory.return_value
                self.assertEqual(c.showPage.call_count, (count+3)//4)
                rects = c.rect.call_args_list
                self.assertEqual(len(rects), count)
                for index, call in enumerate(rects):
                    x, y, w, h = call.args
                    if expected is None: expected = w, h
                    self.assertEqual((w, h), expected)
                    self.assertGreaterEqual(x, 10*mm)
                    self.assertLessEqual(x+w, 287*mm+.01)
                    if index % 4:
                        self.assertGreater(x, rects[index-1].args[0]+w)

    def test_pdf_order_is_invoice_then_numbered_paper_frames_then_payments(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            invoice = root/'invoice.pdf'
            c = canvas.Canvas(str(invoice)); c.drawString(10, 700, 'NORMAL INVOICE'); c.save()
            picture = root/'payment.png'
            Image.new('RGB', (300, 500), 'white').save(picture)
            taxis = [dict(number=f'{i+2:03d}', paperTaxi=True, path=None) for i in range(5)]
            output = root/'complete.pdf'
            export_pdf(dict(invoices=[taxis[0], dict(number='001', path=str(invoice)), *taxis[1:]],
                            pictures=[dict(number='002', path=str(picture))]), str(output))
            pdf = PdfReader(output)
            self.assertEqual(len(pdf.pages), 4)
            self.assertIn('NORMAL INVOICE', pdf.pages[0].extract_text())
            for index, expected in [(1, ['002', '003', '004', '005']), (2, ['006'])]:
                page = pdf.pages[index]
                self.assertAlmostEqual(float(page.mediabox.width)/mm, 297, places=1)
                self.assertAlmostEqual(float(page.mediabox.height)/mm, 210, places=1)
                text = page.extract_text()
                for number in expected: self.assertIn(number, text)
            self.assertIn('002', pdf.pages[3].extract_text())


if __name__ == '__main__': unittest.main()
