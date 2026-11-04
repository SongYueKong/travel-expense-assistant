from pathlib import Path
from copy import deepcopy
import hashlib
import tempfile
import unittest
from pypdf import PdfReader, PdfWriter
from pypdf.generic import RectangleObject
from reportlab.pdfgen import canvas
from reportlab.lib.pagesizes import A4, landscape
from PIL import Image
from uppercase_money import uppercase_money
from uniform_pages import uniform_pages
from worker import export_pdf


class UppercaseMoneyTests(unittest.TestCase):
    def test_integer_cents_zero_gaps_groups_and_fractions(self):
        cases = {0:'零元整',1:'零元壹分',10:'零元壹角',100:'壹元整',101:'壹元零壹分',110:'壹元壹角',
                 107:'壹元零柒分',9950:'玖拾玖元伍角',30000:'叁佰元整',39950:'叁佰玖拾玖元伍角',
                 1000000:'壹万元整',1000100:'壹万零壹元整',1001000:'壹万零壹拾元整',
                 100010000:'壹佰万零壹佰元整',10000000100:'壹亿零壹元整',
                 10001000100:'壹亿零壹万零壹元整',10010000000:'壹亿零壹拾万元整',
                 12345678901:'壹亿贰仟叁佰肆拾伍万陆仟柒佰捌拾玖元零壹分'}
        for value, expected in cases.items():
            with self.subTest(value=value): self.assertEqual(uppercase_money(value),expected)
        for invalid in [-1,1.01,True,'100',None]:
            with self.assertRaises(ValueError): uppercase_money(invalid)


class UniformExportTests(unittest.TestCase):
    def test_all_pages_uniform_content_order_and_originals_unchanged(self):
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp)
            invoice=root/'ticket.pdf'
            c=canvas.Canvas(str(invoice),pagesize=(360,160));c.drawString(15,80,'SMALL TICKET');c.save()
            itinerary=root/'itinerary.pdf'
            c=canvas.Canvas(str(itinerary),pagesize=(900,500));c.drawString(20,240,'WIDE ITINERARY');c.save()
            payment=root/'payment.png';Image.new('RGB',(300,650),'white').save(payment)
            originals={path:hashlib.sha256(path.read_bytes()).hexdigest() for path in [invoice,itinerary,payment]}
            manifest={'invoices':[{'number':'001','path':str(invoice),'itineraries':[str(itinerary)]},
                                  {'number':'002','paperTaxi':True,'invoiceCents':3500}],
                      'pictures':[{'number':'001','path':str(payment)},{'number':'002','path':str(payment)}]}
            for orientation,size in [('landscape',landscape(A4)),('portrait',A4)]:
                manifest['paymentLayout']={'orientation':orientation,'rows':2,'columns':4,'uniformPages':True}
                out=root/f'{orientation}.pdf';export_pdf(manifest,str(out))
                pages=PdfReader(out).pages
                self.assertEqual(len(pages),4)
                for page in pages:
                    self.assertAlmostEqual(float(page.mediabox.width),size[0],places=3)
                    self.assertAlmostEqual(float(page.mediabox.height),size[1],places=3)
                    self.assertEqual(page.rotation,0)
                self.assertIn('SMALL TICKET',pages[0].extract_text())
                self.assertIn('WIDE ITINERARY',pages[1].extract_text())
                self.assertIn('002',pages[2].extract_text())
                self.assertIn('001',pages[3].extract_text())
            manifest['paymentLayout']['uniformPages']=False
            out=root/'original.pdf';export_pdf(manifest,str(out))
            self.assertAlmostEqual(float(PdfReader(out).pages[0].mediabox.width),360)
            for path,digest in originals.items(): self.assertEqual(hashlib.sha256(path.read_bytes()).hexdigest(),digest)
            manifest['paymentLayout']['uniformPages']='yes'
            out.write_bytes(b'previous')
            with self.assertRaises(ValueError): export_pdf(manifest,str(out))
            self.assertEqual(out.read_bytes(),b'previous')

    def test_rotated_crop_is_scaled_with_visible_markers_and_valid_boxes(self):
        with tempfile.TemporaryDirectory() as temp:
            path=Path(temp)/'crop.pdf'
            c=canvas.Canvas(str(path),pagesize=(600,400));c.drawString(110,110,'VISIBLE MARKER');c.save()
            source=PdfWriter();source.append(str(path))
            source.pages[0].cropbox=RectangleObject([100,100,400,300]);source.pages[0].rotate(90)
            out=Path(temp)/'uniform.pdf';uniform_pages(source,A4).write(out)
            page=PdfReader(out).pages[0]
            self.assertEqual(page.rotation,0)
            self.assertAlmostEqual(float(page.cropbox.width),A4[0],places=3)
            self.assertIn('VISIBLE MARKER',page.extract_text())
