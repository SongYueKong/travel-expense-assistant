import base64
from email.message import EmailMessage
import imaplib
import json
from pathlib import Path
import tempfile
import threading
import time
import unittest
from unittest.mock import patch
from mail_service import (scan_mail,test_connection,MailJobManager,MailError,decode_mailbox,date_window)

PDF=b'%PDF-1.4\nTEST FIXTURE'
def message(attachments=(),body='差旅材料',subject='普通邮件'):
    m=EmailMessage();m['Subject']=subject;m['From']='invoice@example.test'
    m['Date']='Mon, 01 Jan 2001 00:00:00 +0000';m.set_content(body)
    for name,data in attachments:m.add_attachment(data,maintype='application',subtype='pdf' if name.lower().endswith('.pdf') else 'zip',filename=name)
    return m.as_bytes()

class FakeIMAP:
    capabilities=(b'IMAP4rev1',b'ID')
    def __init__(self,messages,validity='100',failed=()):
        self.messages=messages;self.validity=validity;self.calls=[];self.failed=set(failed);self.debug=0
    def login(self,*args):self.calls.append(('login',));return 'OK',[]
    def xatom(self,*args):self.calls.append(('ID',));return 'OK',[]
    def list(self):
        chinese='&'+base64.b64encode('已发送'.encode('utf-16-be')).decode().rstrip('=')+'-'
        return 'OK',[b'(\\HasNoChildren) "/" "INBOX"',f'(\\HasNoChildren) "/" "{chinese}"'.encode(),b'(\\Noselect) "/" "Container"']
    def select(self,folder,readonly=False):
        self.calls.append(('select',folder,readonly));return 'OK',[str(len(self.messages)).encode()]
    def response(self,key):return key,[self.validity.encode()]
    def uid(self,command,*args):
        self.calls.append((command,*args))
        if command=='SEARCH':return 'OK',[b' '.join(str(uid).encode() for uid in self.messages)]
        if command!='FETCH':raise AssertionError('不允许修改邮箱')
        uid=int(args[0]);received,raw=self.messages[uid];query=args[1]
        header=f'1 (UID {uid} INTERNALDATE "{received}" RFC822.SIZE {len(raw)})'.encode()
        if 'BODY.PEEK[]' in query:
            if uid in self.failed:return 'NO',[]
            return 'OK',[(header,raw),b')']
        return 'OK',[header]
    def logout(self):self.calls.append(('logout',));return 'BYE',[]
    @property
    def bodies(self):return [c for c in self.calls if c[0]=='FETCH' and 'BODY.PEEK[]' in c[2]]

class MailTests(unittest.TestCase):
    def setUp(self):self.temp=tempfile.TemporaryDirectory();self.root=Path(self.temp.name)
    def tearDown(self):self.temp.cleanup()
    def scan(self,client,**extra):
        with patch('mail_service.imaplib.IMAP4_SSL',return_value=client):
            return scan_mail('qq','test@qq.com','TEST-ONLY-SECRET','2026-10-27','2026-10-27',['INBOX'],self.root,**extra)

    def test_date_boundaries_use_internal_receive_time_not_date_header(self):
        raw=message([('票据.pdf',PDF)])
        client=FakeIMAP({1:('26-Oct-2026 15:59:59 +0000',raw),2:('26-Oct-2026 16:00:00 +0000',raw),
                         3:('27-Oct-2026 15:59:59 +0000',raw),4:('27-Oct-2026 16:00:00 +0000',raw)})
        result=self.scan(client)
        self.assertEqual(result['inRangeMessages'],2)
        self.assertEqual(len(client.bodies),2)
        self.assertEqual(len(result['files']),1)
        self.assertTrue(result['complete'])
        self.assertTrue(all(c[2] is True for c in client.calls if c[0]=='select'))
        self.assertTrue(all('RFC822)' not in str(c) for c in client.bodies))
        cache_bytes=(self.root/'mail-cache.sqlite').read_bytes()
        self.assertNotIn(b'TEST-ONLY-SECRET',cache_bytes)

    def test_all_pdf_attachments_and_path_traversal_filename(self):
        raw=message([('../../票据.pdf',PDF),('行程单.PDF',PDF+b'2')],subject='没有关键字的标题')
        result=self.scan(FakeIMAP({1:('27-Oct-2026 12:00:00 +0800',raw)}))
        self.assertEqual(len(result['files']),2)
        self.assertTrue(all(Path(f['path']).parent==self.root/'materials' for f in result['files']))
        self.assertTrue(any(f['filename']=='../../票据.pdf' for f in result['files']))

    def test_repeat_scan_reuses_cached_messages(self):
        messages={1:('27-Oct-2026 12:00:00 +0800',message([('票据.pdf',PDF)]))}
        first=self.scan(FakeIMAP(messages));second_client=FakeIMAP(messages)
        second=self.scan(second_client)
        self.assertEqual(first['downloaded'],1)
        self.assertEqual(second['duplicates'],1)
        self.assertEqual(second['cachedMessages'],1)
        self.assertEqual(len(second_client.bodies),0)

    def test_uidvalidity_change_does_not_reuse_stale_uid(self):
        messages={1:('27-Oct-2026 12:00:00 +0800',message([('票据.pdf',PDF)]))}
        self.scan(FakeIMAP(messages,validity='1'))
        client=FakeIMAP(messages,validity='2');result=self.scan(client)
        self.assertEqual(result['cachedMessages'],0);self.assertEqual(len(client.bodies),1)

    def test_cancel_keeps_files_and_next_run_resumes(self):
        messages={i:('27-Oct-2026 12:00:00 +0800',message([(f'{i}.pdf',PDF+str(i).encode())])) for i in [1,2]}
        stop=threading.Event()
        result=self.scan(FakeIMAP(messages),cancel=stop,progress=lambda s:stop.set() if s['downloaded']==1 else None)
        self.assertEqual(result['state'],'cancelled');self.assertEqual(len(result['files']),1)
        client=FakeIMAP(messages);again=self.scan(client)
        self.assertEqual(len(again['files']),2);self.assertEqual(len(client.bodies),1)

    def test_failed_message_is_retried_and_not_hidden_as_success(self):
        messages={i:('27-Oct-2026 12:00:00 +0800',message([(f'{i}.pdf',PDF+str(i).encode())])) for i in [1,2]}
        result=self.scan(FakeIMAP(messages,failed=[2]))
        self.assertFalse(result['complete']);self.assertEqual(len(result['failures']),1)
        client=FakeIMAP(messages);again=self.scan(client)
        self.assertEqual(len(again['files']),2);self.assertEqual(len(client.bodies),1)

    def test_links_archives_and_fake_pdfs_remain_pending(self):
        raw=message([('附件.zip',b'zip'),('错误.pdf',b'not a pdf')],body='请下载发票 https://example.test/file')
        result=self.scan(FakeIMAP({1:('27-Oct-2026 12:00:00 +0800',raw)}))
        self.assertFalse(result['complete']);self.assertEqual(len(result['files']),0)
        self.assertEqual(len(result['pending']),3)

    def test_connection_lists_chinese_folders_and_163_identifies_client(self):
        client=FakeIMAP({})
        with patch('mail_service.imaplib.IMAP4_SSL',return_value=client):
            result=test_connection('163','test@163.com','TEST-ONLY')
        self.assertEqual([f['name'] for f in result['folders']],['INBOX','已发送'])
        self.assertTrue(any(c[0]=='ID' for c in client.calls))

    def test_auth_failure_does_not_echo_secret(self):
        client=FakeIMAP({})
        client.login=lambda *args:(_ for _ in ()).throw(imaplib.IMAP4.error('server echoed TEST-ONLY-SECRET'))
        with self.assertRaises(MailError) as error:self.scan(client)
        self.assertNotIn('TEST-ONLY-SECRET',str(error.exception))

    def test_forwarded_email_pdf_is_included(self):
        inner=EmailMessage();inner['Subject']='发票';inner.set_content('附件')
        inner.add_attachment(PDF,maintype='application',subtype='pdf',filename='转发票据.pdf')
        outer=EmailMessage();outer.set_content('转发');outer.add_attachment(inner)
        result=self.scan(FakeIMAP({1:('27-Oct-2026 12:00:00 +0800',outer.as_bytes())}))
        self.assertEqual(len(result['files']),1)
        self.assertEqual(result['files'][0]['filename'],'转发票据.pdf')

    def test_malformed_mime_is_not_silently_complete(self):
        raw=b'Content-Type: multipart/mixed; boundary="missing"\r\nSubject: broken\r\n\r\nno boundary'
        result=self.scan(FakeIMAP({1:('27-Oct-2026 12:00:00 +0800',raw)}))
        self.assertFalse(result['complete']);self.assertTrue(result['pending'])

    def test_background_job_reports_without_exposing_credentials(self):
        client=FakeIMAP({1:('27-Oct-2026 12:00:00 +0800',message([('票据.pdf',PDF)]))})
        manager=MailJobManager(self.root)
        with patch('mail_service.imaplib.IMAP4_SSL',return_value=client):
            job=manager.start(provider='qq',account='test@qq.com',authorization_code='TEST-ONLY-SECRET',
              start_date='2026-10-27',end_date='2026-10-27',folders=['INBOX'])
            deadline=time.monotonic()+3
            while manager.status(job['jobId'])['state']=='running' and time.monotonic()<deadline:time.sleep(.01)
            result=manager.status(job['jobId'])
        self.assertEqual(result['state'],'done')
        self.assertNotIn('TEST-ONLY-SECRET',json.dumps(result))

    def test_invalid_date_and_folder_input_are_rejected_before_network(self):
        with self.assertRaises(MailError):date_window('2026-10-28','2026-10-27')
        with self.assertRaises(MailError):
            scan_mail('qq','test@qq.com','secret','2026-10-27','2026-10-27',['INBOX\r\nEXPUNGE'],self.root)

if __name__=='__main__':unittest.main()
