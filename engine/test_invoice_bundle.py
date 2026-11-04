"""共同支付导出：原件、子编号和一次支付保持对应。"""
from pathlib import Path
import tempfile
import unittest
from PIL import Image
from pypdf import PdfReader
from reportlab.pdfgen import canvas
from worker import export_pdf
from summary_page import claim_rows, validate_summary


class InvoiceBundleExportTests(unittest.TestCase):
    def test_two_invoices_one_payment_keep_order_labels_and_original_document_count(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            invoices, summary = [], []
            for index, cents in enumerate([500,1200]):
                label = f'001-{index+1:02d}'
                path = root/f'{label}.pdf'
                page = canvas.Canvas(str(path), pagesize=(400,200))
                page.drawString(30,100,f'SYNTHETIC REFUND FEE {index+1}')
                page.save()
                invoices.append({'number':label,'path':str(path)})
                summary.append({'number':label,'category':'intercity','invoiceCents':cents,
                                'paymentCents':cents,'reimbursementCents':cents,'paymentNumbers':['001']})
            image = root/'payment.png'
            Image.new('RGB',(300,650),'white').save(image)
            manifest = {'invoices':invoices, 'summary':summary,
                        'pictures':[{'number':'001','path':str(image),'relatedInvoiceNumbers':['001-01','001-02']}],
                        'categoryTotals':[{'category':'intercity','invoiceCents':1700,'paymentCents':1700,'reimbursementCents':1700}],
                        'grandTotals':{'invoiceCents':1700,'paymentCents':1700,'reimbursementCents':1700}}
            rows = claim_rows(manifest,validate_summary(manifest))
            self.assertEqual(rows[0][1],'2')
            self.assertEqual(rows[0][-1],1700)
            output = root/'bundle.pdf'
            export_pdf(manifest,str(output))
            pages = PdfReader(output).pages
            self.assertEqual(len(pages),4)
            self.assertIn('17.00',pages[0].extract_text())
            self.assertIn('001-01',pages[1].extract_text())
            self.assertIn('SYNTHETIC REFUND FEE 1',pages[1].extract_text())
            self.assertIn('001-02',pages[2].extract_text())
            self.assertIn('SYNTHETIC REFUND FEE 2',pages[2].extract_text())
            self.assertIn('001 -> 001-01, 001-02',pages[3].extract_text())
            self.assertEqual(len(pages[3].images),1)
