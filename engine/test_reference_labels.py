"""关联序号字号及字重验证；仅使用合成材料。"""
from pathlib import Path
import tempfile
import unittest
from pypdf import PdfReader
from PIL import Image
from reportlab.pdfgen import canvas
from worker import export_pdf
from payment_pages import build_payment_pages
from statement_page import build_statement_image
from taxi_pages import build_taxi_pages


class ReferenceLabelTests(unittest.TestCase):
    def assert_large_reference(self, path):
        labels = []
        def visit(text, cm, tm, font, size):
            if '001' in text:
                labels.append((size, str(font.get('/BaseFont', ''))))
        PdfReader(path).pages[0].extract_text(visitor_text=visit)
        self.assertTrue(labels)
        self.assertTrue(all(abs(size-14)<0.01 for size, _ in labels))
        self.assertTrue(all('Bold' in font for _, font in labels))

    def test_invoice_payment_statement_and_taxi_numbers_are_large_and_bold(self):
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp)
            invoice=root/'invoice.pdf'
            c=canvas.Canvas(str(invoice));c.drawString(30,700,'SYNTHETIC INVOICE');c.save()
            out=root/'invoice-export.pdf'
            export_pdf({'invoices':[{'number':'001','path':str(invoice)}]},str(out))
            self.assert_large_reference(out)
            image=root/'payment.png';Image.new('RGB',(300,650),'white').save(image)
            out=root/'payments.pdf'
            build_payment_pages([{'number':'001','path':str(image)}],out)
            self.assert_large_reference(out)
            out=root/'statement.pdf'
            build_statement_image(image,out,'001 / STATEMENT')
            self.assert_large_reference(out)
            out=root/'taxi.pdf'
            build_taxi_pages([{'number':'001','invoiceCents':3500}],out)
            self.assert_large_reference(out)
