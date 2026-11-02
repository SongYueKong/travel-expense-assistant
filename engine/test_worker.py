import hashlib
from pathlib import Path
import tempfile
import unittest
import subprocess
import json
import sys
from PIL import Image
from pypdf import PdfReader
from pypdf import PdfWriter
from pypdf.generic import RectangleObject
from reportlab.pdfgen import canvas
from worker import inspect_file, export_pdf

class MaterialTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.image = self.root/'payment.jpg'
        Image.new('RGB', (300, 600), 'white').save(self.image)
        self.invoice = self.pdf('invoice.pdf', 'INVOICE')
        self.itinerary = self.pdf('itinerary.pdf', 'ITINERARY')

    def tearDown(self): self.temp.cleanup()

    def pdf(self, name, text):
        file = self.root/name
        c = canvas.Canvas(str(file)); c.drawString(30, 700, text); c.save()
        return file

    def test_content_addressed_copy_survives_source_move(self):
        result = inspect_file(str(self.image), str(self.root/'materials'))
        again = inspect_file(str(self.image), str(self.root/'materials'))
        self.assertEqual(result['path'], again['path'])
        self.image.unlink()
        self.assertTrue(Path(result['path']).exists())
        self.assertTrue(result['needsOcr'])

    def test_invoice_itinerary_then_grid_page_counts(self):
        original = hashlib.sha256(self.invoice.read_bytes()).hexdigest()
        for count in [0, 1, 8, 9, 16]:
            with self.subTest(count=count):
                output = self.root/f'export-{count}.pdf'
                manifest = {'invoices':[{'number':'001','path':str(self.invoice),
                                        'itineraries':[str(self.itinerary)]}],
                            'pictures':[{'number':f'001-{n+1:02d}', 'path':str(self.image)} for n in range(count)]}
                result = export_pdf(manifest, str(output))
                self.assertEqual(result['pages'], 2+(count+7)//8)
                pdf = PdfReader(output)
                self.assertIn('INVOICE', pdf.pages[0].extract_text())
                self.assertIn('ITINERARY', pdf.pages[1].extract_text())
                if count:
                    self.assertIn('001-01', pdf.pages[2].extract_text())
                    for page in pdf.pages[2:]:
                        self.assertAlmostEqual(float(page.mediabox.width),297*72/25.4,places=3)
                        self.assertAlmostEqual(float(page.mediabox.height),210*72/25.4,places=3)
        self.assertEqual(original, hashlib.sha256(self.invoice.read_bytes()).hexdigest())

    def test_failed_export_preserves_existing_output(self):
        output = self.root/'existing.pdf'; output.write_bytes(b'previous output')
        with self.assertRaises(FileNotFoundError):
            export_pdf({'invoices':[{'number':'001','path':str(self.root/'missing.pdf')}]}, str(output))
        self.assertEqual(output.read_bytes(), b'previous output')

    def test_custom_payment_layout_is_applied_only_to_screenshot_pages(self):
        for orientation,rows,columns in [('portrait',3,2),('landscape',1,4)]:
            with self.subTest(orientation=orientation):
                output = self.root/f'{orientation}.pdf'
                count = rows*columns+1
                result = export_pdf({'invoices':[{'number':'001','path':str(self.invoice)}],
                    'pictures':[{'number':f'001-{i+1:02d}','path':str(self.image)} for i in range(count)],
                    'paymentLayout':{'orientation':orientation,'rows':rows,'columns':columns}}, str(output))
                pages = PdfReader(output).pages
                self.assertEqual(result['pages'], 3)
                self.assertIn('INVOICE', pages[0].extract_text())
                expected = (210,297) if orientation == 'portrait' else (297,210)
                for page in pages[1:]:
                    for actual, millimeters in zip((page.mediabox.width,page.mediabox.height),expected):
                        self.assertAlmostEqual(float(actual),millimeters*72/25.4,places=3)
                self.assertIn(f'001-{count:02d}', pages[-1].extract_text())
                output.write_bytes(b'previous output')
                with self.assertRaises(ValueError):
                    export_pdf({'invoices':[{'number':'001','path':str(self.invoice)}],
                        'paymentLayout':{'orientation':orientation,'rows':0,'columns':columns}}, str(output))
                self.assertEqual(output.read_bytes(), b'previous output')

    def test_hotel_statement_follows_invoice_before_payment_screenshots(self):
        statement=self.pdf('statement.pdf','HOTEL STATEMENT TEST')
        output=self.root/'hotel.pdf'
        export_pdf({'invoices':[{'number':'001','path':str(self.invoice),'supportingDocuments':[str(statement)]}],
                    'pictures':[{'number':'001','path':str(self.image)}]},str(output))
        pages=PdfReader(output).pages
        self.assertEqual(len(pages),3)
        self.assertIn('INVOICE',pages[0].extract_text())
        self.assertIn('HOTEL STATEMENT TEST',pages[1].extract_text())
        self.assertIn('001 / STATEMENT',pages[1].extract_text())
        output.write_bytes(b'previous output')
        with self.assertRaises(FileNotFoundError):
            export_pdf({'invoices':[{'number':'001','path':str(self.invoice),'supportingDocuments':[str(self.root/'missing.pdf')]}]},str(output))
        self.assertEqual(output.read_bytes(),b'previous output')

    def test_visible_crop_is_preserved_without_large_blank_area(self):
        cropped=self.root/'cropped.pdf'
        writer=PdfWriter();writer.append(self.invoice)
        writer.pages[0].cropbox=RectangleObject([0,400,595,850])
        writer.write(cropped)
        original=hashlib.sha256(cropped.read_bytes()).hexdigest()
        output=self.root/'crop-export.pdf'
        export_pdf({'invoices':[{'number':'001','path':str(cropped)}]},str(output))
        page=PdfReader(output).pages[0]
        expected_height=min(850,float(PdfReader(cropped).pages[0].mediabox.top))-400+10*72/25.4
        self.assertAlmostEqual(float(page.mediabox.height),expected_height,places=3)
        self.assertEqual(original,hashlib.sha256(cropped.read_bytes()).hexdigest())

    def test_protocol_recovers_after_invalid_request(self):
        requests = '\n'.join([json.dumps({'id':1,'method':'unknown'}),
                               json.dumps({'id':2,'method':'ping'})])+'\n'
        process = subprocess.run([sys.executable, str(Path(__file__).with_name('worker.py'))],
                                 input=requests, text=True, encoding='utf-8', capture_output=True, timeout=20)
        self.assertEqual(process.returncode,0)
        results=[json.loads(line) for line in process.stdout.splitlines()]
        self.assertIn('error',results[0])
        self.assertEqual(results[1]['id'],2)
        self.assertIn('ocrEngine',results[1]['result'])

if __name__ == '__main__': unittest.main()
