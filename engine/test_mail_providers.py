import unittest
from unittest.mock import patch
from mail_service import PROVIDERS,credentials,open_connection,test_connection,MailError,scan_mail
from test_mail_service import FakeIMAP,message,PDF
import tempfile
import re
from pathlib import Path

class DomesticProviderTests(unittest.TestCase):
    def test_desktop_and_engine_presets_have_identical_hosts_and_domains(self):
        text=(Path(__file__).resolve().parents[1]/'apps/desktop/lib/mail_providers.dart').read_text(encoding='utf-8')
        rows=re.findall(r"MailProvider\(\s*'([^']+)',\s*'[^']+',\s*'([^']+)',\s*\[([^]]+)\]",text)
        presets={key:(host,set(re.findall(r"'([^']+)'",domains))) for key,host,domains in rows}
        self.assertEqual(presets,{key:(value[1],value[2]) for key,value in PROVIDERS.items()})
    def test_each_domain_uses_expected_tls_server_and_netease_id(self):
        for provider,(_,host,domains) in PROVIDERS.items():
            for domain in domains:
                with self.subTest(domain=domain):
                    client=FakeIMAP({});client.capabilities=(b'IMAP4rev1',)
                    with patch('mail_service.imaplib.IMAP4_SSL',return_value=client) as connection:
                        result=test_connection(provider,f'User@{domain}','SECRET-ONLY')
                    self.assertEqual(result['account'],f'user@{domain}')
                    self.assertEqual(connection.call_args.args,(host,993))
                    self.assertTrue(connection.call_args.kwargs['ssl_context'].check_hostname)
                    self.assertEqual(any(c[0]=='ID' for c in client.calls),provider in ['163','126','yeah'])
                    with self.assertRaises(MailError):credentials(provider,f'user@{domain}.attacker','SECRET-ONLY')
    def test_each_new_provider_imports_pdf_readonly_without_storing_secret(self):
        with tempfile.TemporaryDirectory() as directory:
            for provider,(_,_,domains) in PROVIDERS.items():
                domain=sorted(domains)[0];client=FakeIMAP({1:('27-Oct-2026 12:00:00 +0800',message([('invoice.pdf',PDF)]))})
                with patch('mail_service.imaplib.IMAP4_SSL',return_value=client):
                    result=scan_mail(provider,f'user@{domain}','NEVER-SAVE-SECRET','2026-10-27','2026-10-27',['INBOX'],Path(directory)/provider)
                self.assertTrue(result['complete']);self.assertEqual(len(result['files']),1)
                self.assertTrue(all(c[2] is True for c in client.calls if c[0]=='select'))
                self.assertNotIn(b'NEVER-SAVE-SECRET',(Path(directory)/provider/'mail-cache.sqlite').read_bytes())

if __name__=='__main__':unittest.main()
