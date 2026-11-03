from unittest.mock import patch
import unittest
import tempfile
from pathlib import Path
from mail_service import MailCache, extract_message
from documents import parse_pdf
from test_mail_service import message

class AirlineAndMailTests(unittest.TestCase):
    def test_agent_air_ticket_invoice_is_intercity(self):
        for amount in ['1520.00','1222.00']:
            doc=parse_pdf('电子发票（普通发票） 发票号码：99990000000000000001 开票日期：2026年04月29日 *经纪代理服务*代订机票 价税合计 ¥'+amount)
            self.assertEqual(doc['category'],'intercity')
            self.assertEqual(doc['platform'],'air')
            self.assertEqual(doc['totalCents'],int(float(amount)*100))
        self.assertEqual(parse_pdf('电子发票 *住宿费 备注：代订机票 ¥300.00')['category'],'hotel')

    def test_split_clock_keeps_both_didi_trips(self):
        doc=parse_pdf('滴滴出行行程单 2026-04-29 共2笔行程，合计158.60元\n1 快车 04-27 13:\n37 周一\n城市 起点 终点 50.8 89.70\n2 快车 04-29 17:\n06 周三\n城市 起点 终点 50.87 68.90')
        self.assertTrue(doc['complete'])
        self.assertEqual([trip['time'] for trip in doc['trips']],['13:37','17:06'])
        self.assertEqual([trip['cents'] for trip in doc['trips']],[8970,6890])

    def test_receipt_footer_is_not_an_invoice_download_task(self):
        with tempfile.TemporaryDirectory() as temp:
            cache=MailCache(Path(temp))
            try:
                raw=message(subject='感谢您在 Steam 上的购买！',body='购买记录。需要发票或报销请访问 https://example.test/help')
                result=extract_message(raw,{},cache)
                self.assertEqual(result['pending'],[])
                invoice=extract_message(message(subject='您收到来自测试酒店的发票，金额700元',body='下载 https://example.test/invoice'),{},cache)
                self.assertEqual(len(invoice['pending']),1)
                body_only=extract_message(message(body='请下载发票 https://example.test/invoice'),{},cache)
                self.assertEqual(len(body_only['pending']),1)
                cache.save('legacy',{'files':[],'pending':[{'reason':'old'}]})
                self.assertIsNone(cache.load('legacy'))
                cache.save('new',result)
                self.assertIsNotNone(cache.load('new'))
            finally:cache.db.close()

    def test_17win_html_shortlink_is_imported_and_failure_is_retryable(self):
        with tempfile.TemporaryDirectory() as temp:
            cache=MailCache(Path(temp))
            try:
                raw=message(subject='酒店电子发票',body='<a href="https://t.17win.com/DEMO123">下载发票</a>')
                with patch('mail_service.download_invoice_pdf',return_value=b'%PDF-1.4 synthetic') as download:
                    result=extract_message(raw,{},cache)
                download.assert_called_once()
                self.assertEqual(len(result['files']),1)
                self.assertEqual(result['pending'],[])
                self.assertEqual(result['files'][0]['downloadProvider'],'17win')
                with patch('mail_service.download_invoice_pdf',side_effect=ValueError('private signed link')):
                    failed=extract_message(raw,{},cache)
                self.assertTrue(failed['pending'][0]['retryableDownload'])
                self.assertNotIn('private signed link',failed['pending'][0]['reason'])
                cache.save('failed',failed)
                self.assertIsNone(cache.load('failed'))
            finally:cache.db.close()

    def test_unsupported_hosts_and_insecure_redirects_are_rejected(self):
        from invoice_links import invoice_links,validate_url
        self.assertEqual(invoice_links('https://t.17win.com/DEMO123 https://example.test/invoice.pdf'),['https://t.17win.com/DEMO123'])
        for url in ['http://t.17win.com/a','https://t.17win.com.evil.test/a','https://127.0.0.1/a','https://user:pass@t.17win.com/a','https://t.17win.com:8443/a']:
            with self.assertRaises(ValueError):validate_url(url)
