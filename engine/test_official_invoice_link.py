"""51 发票网页交付：显式浏览器辅助，不把网页当 PDF 或虚称自动下载。"""
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch
from invoice_links import invoice_links
from mail_service import MailCache,extract_message,MAIL_PARSE_VERSION
from test_mail_service import message

class OfficialInvoiceLinkTests(unittest.TestCase):
    def test_only_official_shortlink_is_extracted(self):
        self.assertEqual(invoice_links('https://a.51fapiao.cn/v/TEST123 https://www.51fapiao.cn/tydl-login/index.html'),['https://a.51fapiao.cn/v/TEST123'])
        for url in ['http://a.51fapiao.cn/v/TEST','https://a.51fapiao.cn.evil.test/v/TEST','https://user@a.51fapiao.cn/v/TEST','https://a.51fapiao.cn:8443/v/TEST']:
            self.assertEqual(invoice_links(url),[])

    def test_browser_delivery_preserves_source_and_never_calls_pdf_downloader(self):
        with tempfile.TemporaryDirectory() as temp:
            cache=MailCache(Path(temp))
            try:
                raw=message(subject='酒店电子发票',body='<a href="https://a.51fapiao.cn/v/TEST123">下载发票</a>')
                with patch('mail_service.download_invoice_pdf') as download:
                    result=extract_message(raw,{'uid':'123','folder':'INBOX'},cache)
                download.assert_not_called()
                self.assertEqual(result['files'],[])
                self.assertEqual(result['pending'][0]['downloadUrl'],'https://a.51fapiao.cn/v/TEST123')
                self.assertEqual(result['pending'][0]['uid'],'123')
                self.assertTrue(result['pending'][0]['retryableDownload'])
                cache.save('old',dict(result,parserVersion=MAIL_PARSE_VERSION-1))
                self.assertIsNone(cache.load('old'))
            finally:cache.db.close()

if __name__=='__main__':unittest.main()
