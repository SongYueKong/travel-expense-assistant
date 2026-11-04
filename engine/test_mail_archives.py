from io import BytesIO
from pathlib import Path
import struct
import tempfile
import unittest
from unittest.mock import patch
import zipfile
from mail_archives import read_zip_pdfs, member_name
from mail_service import MailCache, MAIL_PARSE_VERSION, scan_mail
from test_mail_service import FakeIMAP, message, PDF


def zipped(entries, compression=zipfile.ZIP_DEFLATED):
    result=BytesIO()
    with zipfile.ZipFile(result,'w',compression=compression) as archive:
        for name,data in entries:
            archive.writestr(name,data)
    return result.getvalue()


def encrypted_zip():
    result=bytearray(zipped([('private.pdf',PDF)]))
    for offset in [result.find(b'PK\x03\x04')+6,result.find(b'PK\x01\x02')+8]:
        flags=struct.unpack_from('<H',result,offset)[0]
        struct.pack_into('<H',result,offset,flags|1)
    return bytes(result)


class ArchiveMailTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.root=Path(self.temp.name)
    def tearDown(self):
        self.temp.cleanup()
    def scan(self,client):
        with patch('mail_service.imaplib.IMAP4_SSL',return_value=client):
            return scan_mail('qq','test@qq.com','TEST-ONLY-SECRET','2026-10-27','2026-10-27',['INBOX'],self.root)

    def test_four_ticket_archives_import_pdfs_without_spurious_link_pending(self):
        raw=message([(f'rail-{i}.zip',zipped([(f'票据-{i}.pdf',PDF+str(i).encode()),
                    ('invoice.xml',b'<xml/>'),('invoice.ofd',b'other format')])) for i in range(4)],
                    subject='Fw:网上购票系统-电子发票通知',body='邮件服务链接 https://example.test/help')
        result=self.scan(FakeIMAP({1:('27-Oct-2026 12:00:00 +0800',raw)}))
        self.assertEqual(result['downloaded'],4)
        self.assertEqual(len(result['files']),4)
        self.assertEqual(result['pending'],[])
        self.assertTrue(result['complete'])
        self.assertTrue(all(item['archiveFilename'].endswith('.zip') for item in result['files']))

    def test_same_message_pdf_suppresses_non_pdf_archive_notes_regardless_of_part_order(self):
        other=('invoice.ofd',zipped([('OFD.xml',b'<ofd/>')]))
        for case_index,order in enumerate([[other,('ticket.pdf',PDF)],[('ticket.pdf',PDF),other],
                      [('invoice-only.zip',zipped([('invoice.xml',b'xml')])),('ticket.zip',zipped([('ticket.pdf',PDF)]))]]):
            with self.subTest(order=[name for name,_ in order]):
                raw=message(order)
                result=self.scan(FakeIMAP({1:('27-Oct-2026 12:00:00 +0800',raw)},validity=str(case_index)))
                self.assertEqual(len(result['files']),1)
                self.assertEqual(result['pending'],[])
                self.assertTrue(result['complete'])

    def test_pdf_in_another_message_cannot_clear_missing_pdf_note(self):
        messages={1:('27-Oct-2026 12:00:00 +0800',message([('ticket.pdf',PDF)])),
                  2:('27-Oct-2026 12:00:00 +0800',message([('invoice.ofd',zipped([('OFD.xml',b'ofd')]))]))}
        result=self.scan(FakeIMAP(messages))
        self.assertEqual(len(result['files']),1)
        self.assertFalse(result['complete'])
        self.assertEqual(len(result['pending']),1)
        self.assertEqual(result['pending'][0]['code'],'archive_no_pdf')
        self.assertEqual(result['pending'][0]['uid'],'2')

    def test_downloaded_pdf_also_satisfies_same_message_non_pdf_archive(self):
        raw=message([('invoice.ofd',zipped([('OFD.xml',b'ofd')]))],subject='电子发票',body='下载发票 https://t.17win.com/TEST123')
        with patch('mail_service.download_invoice_pdf',return_value=PDF):
            result=self.scan(FakeIMAP({1:('27-Oct-2026 12:00:00 +0800',raw)}))
        self.assertEqual(len(result['files']),1)
        self.assertEqual(result['pending'],[])
        self.assertTrue(result['complete'])

    def test_members_keep_unique_sources_and_repeat_scan_reuses_cache(self):
        raw=message([('tickets.ZIP',zipped([('子目录/发票.PDF',PDF),('other/ticket.pdf',PDF+b'2')]))])
        messages={1:('27-Oct-2026 12:00:00 +0800',raw)}
        first=self.scan(FakeIMAP(messages))
        self.assertEqual({p['filename'] for p in first['files']},{'发票.PDF','ticket.pdf'})
        self.assertEqual(len({p['partIndex'] for p in first['files']}),2)
        self.assertTrue(any(p['archiveMember']=='子目录/发票.PDF' for p in first['files']))
        client=FakeIMAP(messages);second=self.scan(client)
        self.assertEqual(len(client.bodies),0)
        self.assertEqual(second['duplicates'],2)
        self.assertTrue(second['complete'])

    def test_duplicate_direct_pdf_and_archive_traversal_member_stay_in_material_store(self):
        raw=message([('tickets.zip',zipped([('../../escaped.pdf',PDF)])),('direct.pdf',PDF)])
        result=self.scan(FakeIMAP({1:('27-Oct-2026 12:00:00 +0800',raw)}))
        self.assertEqual(len(result['files']),1)
        item=result['files'][0]
        self.assertEqual(item['filename'],'escaped.pdf')
        self.assertEqual(Path(item['path']).parent,self.root/'materials')
        self.assertFalse((self.root.parent/'escaped.pdf').exists())
        self.assertEqual(len(item['additionalSources']),1)
        self.assertEqual(result['duplicates'],1)

    def test_encrypted_broken_or_fake_pdf_leave_specific_pending_while_other_files_import(self):
        for name,data,reason in [('encrypted.zip',encrypted_zip(),'加密'),('broken.zip',b'not a zip','无法读取'),
                                  ('fake.zip',zipped([('fake.pdf',b'not a PDF')]),'内容无法识别')]:
            with self.subTest(name=name):
                raw=message([(name,data),('valid.pdf',PDF)])
                result=self.scan(FakeIMAP({1:('27-Oct-2026 12:00:00 +0800',raw)},validity=name))
                self.assertEqual(len(result['files']),1)
                self.assertFalse(result['complete'])
                self.assertEqual(len(result['pending']),1)
                self.assertIn(reason,result['pending'][0]['reason'])
                self.assertIn(name,result['pending'][0]['reason'])

    def test_unsupported_rar_and_7z_stay_pending(self):
        for extension in ['rar','7z']:
            raw=message([(f'attachment.{extension}',b'archive')])
            result=self.scan(FakeIMAP({1:('27-Oct-2026 12:00:00 +0800',raw)},validity=extension))
            self.assertFalse(result['complete'])
            self.assertIn('RAR、7z',result['pending'][0]['reason'])


class ArchiveReaderTests(unittest.TestCase):
    def test_limits_reject_oversized_archives_members_counts_and_expansion(self):
        data=zipped([('a.pdf',PDF),('b.pdf',PDF+b'2')])
        self.assertEqual(read_zip_pdfs(data,len(data)-1)[0],[])
        with patch('mail_archives.MAX_ZIP_ENTRIES',1):
            files,issues=read_zip_pdfs(data,1024)
            self.assertEqual(files,[])
            self.assertIn('数量',issues[0]['reason'])
        with patch('mail_archives.MAX_ZIP_EXPANDED_BYTES',10):
            files,issues=read_zip_pdfs(data,1024)
            self.assertEqual(files,[])
            self.assertIn('总大小',issues[0]['reason'])
        big=zipped([('large.pdf',PDF+b'A'*4096)])
        self.assertLess(len(big),500)
        files,issues=read_zip_pdfs(big,500)
        self.assertEqual(files,[])
        self.assertIn('单个 PDF',issues[0]['reason'])

    def test_crc_damage_does_not_suppress_other_valid_member(self):
        data=bytearray(zipped([('bad.pdf',PDF),('good.pdf',PDF+b' good')],zipfile.ZIP_STORED))
        with zipfile.ZipFile(BytesIO(data)) as archive:
            info=archive.infolist()[0]
            data[info.header_offset+30+len(info.filename.encode())+len(info.extra)+10]^=1
        files,issues=read_zip_pdfs(bytes(data),1024*1024)
        self.assertEqual([p['filename'] for p in files],['good.pdf'])
        self.assertEqual(len(issues),1)
        self.assertIn('读取失败',issues[0]['reason'])

    def test_nested_no_pdf_and_links_remain_explanatory_pending(self):
        files,issues=read_zip_pdfs(zipped([('nested.zip',b'zip'),('ticket.pdf',PDF)]),1024*1024)
        self.assertEqual(len(files),1)
        self.assertIn('嵌套',issues[0]['reason'])
        files,issues=read_zip_pdfs(zipped([('invoice.xml',b'xml')]),1024*1024)
        self.assertEqual(files,[])
        self.assertIn('未找到 PDF',issues[0]['reason'])
        link=zipfile.ZipInfo('link.pdf');link.create_system=3;link.external_attr=0o120777<<16
        files,issues=read_zip_pdfs(zipped([(link,b'elsewhere.pdf')]),1024*1024)
        self.assertEqual(files,[])
        self.assertIn('链接',issues[0]['reason'])

    def test_gbk_name_is_decoded_only_for_display(self):
        text='铁路电子发票.pdf'
        info=zipfile.ZipInfo(text.encode('gbk').decode('cp437'))
        self.assertEqual(member_name(info),text)
        info=zipfile.ZipInfo('发票.pdf');info.flag_bits=0x800
        self.assertEqual(member_name(info),'发票.pdf')

    def test_old_parser_cache_is_invalidated_for_archive_retry(self):
        with tempfile.TemporaryDirectory() as temp:
            cache=MailCache(Path(temp))
            try:
                cache.save('old',{'parserVersion':MAIL_PARSE_VERSION-1,'files':[],
                           'pending':[{'reason':'压缩附件需手动解压后补充'}]})
                self.assertIsNone(cache.load('old'))
            finally:
                cache.db.close()
