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
        self.assertIn('住宿费',pages[0].extract_text())
        self.assertIn('申报金额合计',pages[0].extract_text())
        self.assertIn('99.50',pages[0].extract_text())
        self.assertIn('玖拾玖元伍角',pages[0].extract_text())
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
        text=pages[0].extract_text();self.assertIn('伙食补助费',text);self.assertIn('399.50',text);self.assertIn('2027-01-02',text)
        self.assertNotIn('allowance-meal',text)
        self.assertIn('叁佰玖拾玖元伍角',text)

    def test_meal_only_has_one_summary_page(self):
        self.with_meal(only=True);out=self.root/'meal.pdf';export_pdf(self.manifest,str(out))
        pages=PdfReader(out).pages;self.assertEqual(len(pages),1);self.assertIn('300.00',pages[0].extract_text())
        self.assertIn('叁佰元整',pages[0].extract_text())

    def test_uniform_landscape_summary_contains_total_on_first_page(self):
        self.with_meal()
        self.manifest['paymentLayout']={'orientation':'landscape','rows':2,'columns':4,'uniformPages':True}
        out=self.root/'uniform.pdf';export_pdf(self.manifest,str(out))
        pages=PdfReader(out).pages
        self.assertIn('叁佰玖拾玖元伍角',pages[0].extract_text())
        self.assertLess(pages[0].extract_text().index('费用类别'),pages[0].extract_text().index('人民币大写'))
        for page in pages:
            self.assertAlmostEqual(float(page.mediabox.width),297*72/25.4,places=3)
            self.assertAlmostEqual(float(page.mediabox.height),210*72/25.4,places=3)

    def test_invalid_meal_cannot_replace_existing_output(self):
        self.with_meal();baseline=deepcopy(self.manifest)
        for field,value in [('days',4),('dailyRateCents',True),('tripEndDate','2027-01-03'),('tripEndDate','2027-02-30'),('invoiceCents',1),('kind','receipt')]:
            self.manifest=deepcopy(baseline);self.manifest['summary'][-1][field]=value
            out=self.root/'existing.pdf';out.write_bytes(b'previous')
            with self.assertRaises(ValueError):export_pdf(self.manifest,str(out))
            self.assertEqual(out.read_bytes(),b'previous')

class ClaimCoverTests(unittest.TestCase):
    setUp = SummaryTests.setUp
    tearDown = SummaryTests.tearDown
    def test_category_counts_and_lodging_use_trip_days_not_invoice_count(self):
        from summary_page import validate_summary, claim_rows
        self.manifest.update(tripStartDate='2026-12-31',tripEndDate='2027-01-02')
        for number,category,amount in [('002','hotel',20000),('003','intercity',50000),('004','intercity',40000),('005','local',3500)]:
            self.manifest['invoices'].append({'number':number,'path':self.manifest['invoices'][0]['path']})
            self.manifest['summary'].append({'number':number,'category':category,'description':'test',
                'paymentNumbers':[number],'invoiceCents':amount,'paymentCents':amount,'reimbursementCents':amount})
        self.manifest['pictures']=[{'number':str(i),'path':'unused'} for i in range(9)]
        fields=['invoiceCents','paymentCents','reimbursementCents']
        self.manifest['categoryTotals']=[{'category':key,**{f:sum(r[f] for r in self.manifest['summary'] if r['category']==key) for f in fields}} for key in ['intercity','local','hotel']]
        self.manifest['grandTotals']={f:sum(r[f] for r in self.manifest['summary']) for f in fields}
        rows=claim_rows(self.manifest,validate_summary(self.manifest))
        self.assertEqual(rows,[['城市间交通费','2','—','—',90000],['市内交通费','—','—','—',3500],['住宿费','—','1','3',29950]])

    def test_full_landscape_cover_keeps_all_categories_and_both_totals_on_one_page(self):
        from summary_page import build_summary_pdf
        from reportlab.lib.pagesizes import landscape, A4
        SummaryTests.with_meal(self)
        for number,category in [('002','intercity'),('003','local')]:
            self.manifest['invoices'].append({'number':number})
            row={'number':number,'category':category,'invoiceCents':10000,'paymentCents':10000,'reimbursementCents':10000,'paymentNumbers':[number]}
            self.manifest['summary'].append(row)
            self.manifest['categoryTotals'].append(dict(row))
        self.manifest['grandTotals']={field:sum(row[field] for row in self.manifest['summary']) for field in ['invoiceCents','paymentCents','reimbursementCents']}
        self.manifest['taskName']='跨年出差申报示例'
        output=self.root/'landscape-cover.pdf'
        build_summary_pdf(self.manifest,output,page_size=landscape(A4))
        pages=PdfReader(output).pages
        self.assertEqual(len(pages),1)
        text=pages[0].extract_text()
        for value in ['城市间交通费','市内交通费','住宿费','伙食补助费','人民币大写','人民币小写','599.50']:
            self.assertIn(value,text)

    def test_cover_total_is_bold_and_numeric_is_present(self):
        from typography import report_fonts
        out=self.root/'cover.pdf';export_pdf(self.manifest,str(out))
        fragments=[]
        page=PdfReader(out).pages[0]
        page.extract_text(visitor_text=lambda text,cm,tm,font,size:fragments.append((text,str((font or {}).get('/BaseFont','')),size)))
        upper=[row for row in fragments if '玖拾玖元伍角' in row[0]]
        self.assertTrue(upper)
        self.assertTrue(any(row[2]>=16 for row in upper))
        if report_fonts().chinese_bold!=report_fonts().chinese:
            self.assertTrue(any('bold' in row[1].lower() for row in upper))
        self.assertTrue(any('99.50' in row[0] and row[2]>=14 for row in fragments))
        text=page.extract_text()
        for label in ['城市间交通费','单据数量','市内交通费','住宿费','人数','天数','申报金额合计','人民币大写','人民币小写']:
            self.assertIn(label,text)
        self.assertNotIn('发票金额',text)
        self.assertNotIn('支付净额',text)

    def test_legacy_no_dates_is_explicit_and_invalid_period_preserves_output(self):
        from summary_page import validate_summary,claim_rows
        self.assertEqual(claim_rows(self.manifest,validate_summary(self.manifest))[2][2:4],['1','未设置'])
        self.manifest.update(tripStartDate='2027-01-02',tripEndDate='2027-01-01')
        out=self.root/'previous.pdf';out.write_bytes(b'previous')
        with self.assertRaises(ValueError):export_pdf(self.manifest,str(out))
        self.assertEqual(out.read_bytes(),b'previous')

if __name__=='__main__':unittest.main()
