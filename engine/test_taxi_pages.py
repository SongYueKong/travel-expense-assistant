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
from payment_pages import payment_cell_size


class TaxiPageTests(unittest.TestCase):
    def test_three_columns_fixed_size_on_full_and_partial_pages(self):
        expected = None
        for count in [1, 2, 3, 4, 5, 6, 7, 9]:
            entries = [dict(number=f'{i+1:03d}', paperTaxi=True,invoiceCents=3500) for i in range(count)]
            with patch('taxi_pages.canvas.Canvas') as factory:
                build_taxi_pages(entries, 'unused.pdf')
                c = factory.return_value
                self.assertEqual(c.showPage.call_count, (count+2)//3)
                rects = c.rect.call_args_list
                self.assertEqual(len(rects), count)
                for index, call in enumerate(rects):
                    x, y, w, h = call.args
                    if expected is None: expected = w, h
                    self.assertEqual((w, h), expected)
                    self.assertGreaterEqual(x, 20*mm)
                    self.assertLessEqual(x+w, 291*mm+.01)
                    self.assertEqual((w,h),payment_cell_size())
                    if index % 3 == 0: self.assertAlmostEqual(x/mm, 20, places=3)
                    if index % 3:
                        self.assertGreater(x, rects[index-1].args[0]+w)

    def test_box_sizes_match_configured_payment_cells_with_twenty_mm_left_margin(self):
        layouts=[None,{'orientation':'landscape','rows':1,'columns':3},
                 {'orientation':'landscape','rows':2,'columns':4},
                 {'orientation':'portrait','rows':2,'columns':3},
                 {'orientation':'portrait','rows':1,'columns':3,'uniformPages':True},
                 {'orientation':'portrait','rows':8,'columns':8,'uniformPages':True}]
        for layout in layouts:
            for draft in [False,True]:
                with self.subTest(layout=layout,draft=draft),patch('taxi_pages.canvas.Canvas') as factory:
                    entries=[{'number':f'{i+1:03d}','invoiceCents':3500+i} for i in range(4)]
                    build_taxi_pages(entries,'unused.pdf',layout,draft)
                    c=factory.return_value;boxes=c.rect.call_args_list
                    self.assertEqual(len(boxes),4)
                    self.assertEqual(c.showPage.call_count,2)
                    for i,box in enumerate(boxes):
                        x,y,w,h=box.args
                        self.assertEqual((w,h),payment_cell_size(layout,draft))
                        if i%3==0:self.assertAlmostEqual(x/mm,20,places=4)
                        if i%3:self.assertGreater(x,boxes[i-1].args[0]+w)
                    self.assertIn('35.00',c.drawCentredString.call_args_list[0].args[-1])
                    self.assertIn('35.03',c.drawCentredString.call_args_list[-1].args[-1])

    def test_old_manifest_summary_supplies_invoice_amount_instead_of_reimbursement(self):
        with tempfile.TemporaryDirectory() as temp:
            row={'number':'001','category':'local','invoiceCents':3500,'paymentCents':3400,
                 'reimbursementCents':3400,'paymentNumbers':['001']}
            manifest={'invoices':[{'number':'001','paperTaxi':True}], 'summary':[row],
                      'categoryTotals':[{'category':'local',**{k:row[k] for k in ['invoiceCents','paymentCents','reimbursementCents']}}],
                      'grandTotals':{k:row[k] for k in ['invoiceCents','paymentCents','reimbursementCents']},
                      'paymentLayout':{'orientation':'landscape','rows':1,'columns':3}}
            path=Path(temp)/'export.pdf';export_pdf(manifest,str(path))
            pages=PdfReader(path).pages
            self.assertEqual(len(pages),2)
            text=pages[1].extract_text()
            self.assertIn('001',text);self.assertIn('35.00',text);self.assertNotIn('34.00',text)

    def test_invalid_amount_or_oversized_cell_does_not_replace_existing_output(self):
        for value in [None,-1,True,'35.00']:
            with self.subTest(value=value),patch('taxi_pages.canvas.Canvas') as factory:
                with self.assertRaises(ValueError):build_taxi_pages([{'number':'001','invoiceCents':value}],'unused.pdf')
                factory.assert_not_called()
        with tempfile.TemporaryDirectory() as temp:
            out=Path(temp)/'existing.pdf';out.write_bytes(b'previous output')
            manifest={'invoices':[{'number':'001','paperTaxi':True,'invoiceCents':3500}],
                      'paymentLayout':{'orientation':'landscape','rows':1,'columns':1}}
            with self.assertRaisesRegex(ValueError,'格子过大'):export_pdf(manifest,str(out))
            self.assertEqual(out.read_bytes(),b'previous output')

    def test_pdf_order_is_invoice_then_numbered_paper_frames_then_payments(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            invoice = root/'invoice.pdf'
            c = canvas.Canvas(str(invoice)); c.drawString(10, 700, 'NORMAL INVOICE'); c.save()
            picture = root/'payment.png'
            Image.new('RGB', (300, 500), 'white').save(picture)
            taxis = [dict(number=f'{i+2:03d}', paperTaxi=True, path=None,invoiceCents=3500) for i in range(5)]
            output = root/'complete.pdf'
            export_pdf(dict(invoices=[taxis[0], dict(number='001', path=str(invoice)), *taxis[1:]],
                            pictures=[dict(number='002', path=str(picture))]), str(output))
            pdf = PdfReader(output)
            self.assertEqual(len(pdf.pages), 4)
            self.assertIn('NORMAL INVOICE', pdf.pages[0].extract_text())
            for index, expected in [(1, ['002', '003', '004']), (2, ['005', '006'])]:
                page = pdf.pages[index]
                self.assertAlmostEqual(float(page.mediabox.width)/mm, 297, places=1)
                self.assertAlmostEqual(float(page.mediabox.height)/mm, 210, places=1)
                text = page.extract_text()
                for number in expected: self.assertIn(number, text)
                self.assertIn('35.00',text)
            self.assertIn('002', pdf.pages[3].extract_text())


if __name__ == '__main__': unittest.main()
