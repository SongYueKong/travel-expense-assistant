from pathlib import Path
import tempfile
import unittest
from copy import deepcopy
from pypdf import PdfReader
from reportlab.pdfgen import canvas
from worker import export_pdf

class SummaryTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.root=Path(self.temp.name)
        source=self.root/'invoice.pdf'
        c=canvas.Canvas(str(source));c.drawString(30,700,'INVOICE');c.save()
        self.manifest={'invoices':[{'number':'001','path':str(source)}],
          'summary':[{'number':'001','category':'hotel','description':'酒店住宿',
            'paymentNumbers':['001'],'invoiceCents':10000,'paymentCents':9950,'reimbursementCents':9950}],
          'categoryTotals':[{'category':'hotel','invoiceCents':10000,'paymentCents':9950,'reimbursementCents':9950}],
          'grandTotals':{'invoiceCents':10000,'paymentCents':9950,'reimbursementCents':9950}}

    def tearDown(self):self.temp.cleanup()

    def test_summary_is_first_and_uses_client_totals(self):
        out=self.root/'summary.pdf';export_pdf(self.manifest,str(out))
        pages=PdfReader(out).pages
        self.assertEqual(len(pages),2)
        self.assertIn('差旅报账费用汇总',pages[0].extract_text())
        self.assertIn('酒店住宿小计',pages[0].extract_text())
        self.assertIn('费用总计',pages[0].extract_text())
        self.assertIn('99.50',pages[0].extract_text())
        self.assertIn('INVOICE',pages[1].extract_text())

    def test_inconsistent_totals_do_not_replace_output(self):
        self.manifest['grandTotals']['reimbursementCents']=10000
        output=self.root/'existing.pdf';output.write_bytes(b'previous')
        with self.assertRaises(ValueError):export_pdf(self.manifest,str(output))
        self.assertEqual(output.read_bytes(),b'previous')

    def with_meal(self, only=False):
        meal={'number':'allowance-meal','kind':'allowance','category':'meal','description':'伙食补助费（3天 × 100.00元／天）',
          'invoiceCents':0,'paymentCents':0,'reimbursementCents':30000,'paymentNumbers':[],
          'days':3,'dailyRateCents':10000,'tripStartDate':'2026-12-31','tripEndDate':'2027-01-02'}
        if only: self.manifest['invoices']=[];self.manifest['summary']=[];self.manifest['categoryTotals']=[]
        self.manifest['summary'].append(meal)
        self.manifest['categoryTotals'].append({key:meal[key] for key in ['category','invoiceCents','paymentCents','reimbursementCents']})
        self.manifest['grandTotals']={key:sum(row[key] for row in self.manifest['summary']) for key in ['invoiceCents','paymentCents','reimbursementCents']}

    def test_meal_adds_to_total_without_fake_invoice(self):
        self.with_meal();out=self.root/'meal.pdf';export_pdf(self.manifest,str(out))
        pages=PdfReader(out).pages;self.assertEqual(len(pages),2)
        text=pages[0].extract_text();self.assertIn('伙食补助费小计',text);self.assertIn('399.50',text);self.assertIn('2027-01-02',text)
        self.assertNotIn('allowance-meal',text)

    def test_meal_only_has_one_summary_page(self):
        self.with_meal(only=True);out=self.root/'meal.pdf';export_pdf(self.manifest,str(out))
        pages=PdfReader(out).pages;self.assertEqual(len(pages),1);self.assertIn('300.00',pages[0].extract_text())

    def test_invalid_meal_cannot_replace_existing_output(self):
        self.with_meal();baseline=deepcopy(self.manifest)
        for field,value in [('days',4),('dailyRateCents',True),('tripEndDate','2027-01-03'),('tripEndDate','2027-02-30'),('invoiceCents',1),('kind','receipt')]:
            self.manifest=deepcopy(baseline);self.manifest['summary'][-1][field]=value
            out=self.root/'existing.pdf';out.write_bytes(b'previous')
            with self.assertRaises(ValueError):export_pdf(self.manifest,str(out))
            self.assertEqual(out.read_bytes(),b'previous')

if __name__=='__main__':unittest.main()
