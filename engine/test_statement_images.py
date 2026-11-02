import hashlib
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
from PIL import Image
from pypdf import PdfReader
from reportlab.pdfgen import canvas
from reportlab.lib.units import mm
from worker import inspect_file, export_pdf
from statement_page import build_statement_image


class StatementImageTests(unittest.TestCase):
    def test_photo_orientation_and_transparency_are_preserved_for_print(self):
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary)
            image=Image.new('RGB',(300,100),'red');exif=image.getexif();exif[274]=6
            path=root/'rotated.jpg';image.save(path,exif=exif)
            output=root/'rotation.pdf';build_statement_image(path,output,'001 / STATEMENT')
            page=PdfReader(output).pages[0]
            self.assertLess(float(page.mediabox.width),float(page.mediabox.height))
            transparent=root/'transparent.png';Image.new('RGBA',(100,200),(0,0,0,0)).save(transparent)
            with patch('statement_page.canvas.Canvas') as factory:
                build_statement_image(transparent,root/'unused.pdf','001 / STATEMENT')
                reader=factory.return_value.drawImage.call_args.args[0]
                self.assertEqual(reader.getRGBData()[:3],b'\xff\xff\xff')
    def test_statement_images_are_validated_and_never_ocr_as_payments(self):
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary)
            for ext in ['jpg','jpeg','png','bmp','webp']:
                path=root/f'statement.{ext}';Image.new('RGB',(200,300),'white').save(path)
                with patch('worker.recognize_image') as ocr:
                    result=inspect_file(str(path),str(root/'materials'),purpose='statement')
                    ocr.assert_not_called()
                self.assertEqual(result['document']['type'],'supportingDocument')
                self.assertNotIn('ocr',result)
                self.assertEqual(Path(result['path']).read_bytes(),path.read_bytes())
            bad=root/'bad.png';bad.write_bytes(b'not an image')
            with self.assertRaises(OSError):inspect_file(str(bad),str(root/'materials'),purpose='statement')

    def test_images_export_after_invoice_before_payment_with_number_and_a4_bounds(self):
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary);invoice=root/'invoice.pdf'
            c=canvas.Canvas(str(invoice));c.drawString(20,700,'INVOICE');c.save()
            for ext,size in [('png',(400,800)),('jpeg',(1000,600)),('bmp',(400,800)),('webp',(400,800))]:
                statement=root/f'statement.{ext}';Image.new('RGB',size,'white').save(statement)
                before=hashlib.sha256(statement.read_bytes()).hexdigest()
                output=root/f'export-{ext}.pdf'
                export_pdf({'invoices':[{'number':'001','path':str(invoice),'supportingDocuments':[str(statement)]}],
                            'pictures':[{'number':'001','path':str(statement)}]},str(output))
                pages=PdfReader(output).pages
                self.assertEqual(len(pages),3)
                self.assertIn('INVOICE',pages[0].extract_text())
                self.assertIn('001 / STATEMENT',pages[1].extract_text())
                self.assertAlmostEqual(float(pages[1].mediabox.width)/mm,297 if size[0]>size[1] else 210,places=1)
                self.assertAlmostEqual(float(pages[1].mediabox.height)/mm,210 if size[0]>size[1] else 297,places=1)
                self.assertIn('001',pages[2].extract_text())
                self.assertEqual(hashlib.sha256(statement.read_bytes()).hexdigest(),before)
                output.write_bytes(b'previous valid output')
                with self.assertRaises(FileNotFoundError):
                    export_pdf({'invoices':[{'number':'001','path':str(invoice),'supportingDocuments':[str(root/'missing.png')]}]},str(output))
                self.assertEqual(output.read_bytes(),b'previous valid output')
