"""国内常用邮箱只读 IMAP 导入。授权码只用于内存连接，不进入缓存或结果。"""
from __future__ import annotations
import base64
import copy
from datetime import date, datetime, time, timedelta, timezone
from email import policy
from email.parser import BytesParser
import hashlib
import imaplib
import json
from pathlib import Path
import re
import sqlite3
import ssl
import tempfile
import threading
import uuid

PROVIDERS={'qq':('QQ 邮箱','imap.qq.com',{'qq.com','foxmail.com'}),
           '163':('163 邮箱','imap.163.com',{'163.com'}),
           '126':('126 邮箱','imap.126.com',{'126.com'}),
           'yeah':('网易 yeah 邮箱','imap.yeah.net',{'yeah.net'}),
           '139':('移动139邮箱','imap.139.com',{'139.com'}),
           'sina':('新浪邮箱','imap.sina.com',{'sina.com'}),
           'sina_cn':('新浪邮箱','imap.sina.cn',{'sina.cn'}),
           'aliyun':('阿里个人邮箱','imap.aliyun.com',{'aliyun.com'})}
NETEASE={'163','126','yeah'}
MONTHS=['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec']
MAX_MESSAGE_BYTES=50*1024*1024
MAX_ATTACHMENT_BYTES=25*1024*1024

class MailError(ValueError): pass

def credentials(provider,account,authorization_code):
    account=account.strip().lower()
    if provider not in PROVIDERS: raise MailError('请选择支持的邮箱服务商')
    if len(account)>254 or not account.isascii() or not re.fullmatch(r'[^\s@\r\n]+@[^\s@\r\n]+',account) or account.rsplit('@',1)[-1] not in PROVIDERS[provider][2]:
        raise MailError('邮箱地址与所选服务商不符，请填写完整的个人邮箱地址')
    if not authorization_code or any(c in authorization_code for c in '\r\n\x00'):
        raise MailError('请填写邮箱客户端授权码')
    return account

def open_connection(provider,account,authorization_code):
    account=credentials(provider,account,authorization_code)
    client=None
    try:
        client=imaplib.IMAP4_SSL(PROVIDERS[provider][1],993,ssl_context=ssl.create_default_context(),timeout=20)
        client.debug=0
        typ,_=client.login(account,authorization_code)
        if typ!='OK': raise MailError('邮箱登录失败，请检查授权码和 IMAP 服务')
        if provider in NETEASE or b'ID' in client.capabilities:
            contact=account.replace('\\','\\\\').replace('"','\\"')
            typ,_=client.xatom('ID',f'("name" "TravelAssistant" "version" "0.2.0" "vendor" "TravelAssistant" "contact" "{contact}")')
            if provider in NETEASE and typ!='OK': raise MailError('网易邮箱未接受客户端标识，请检查 IMAP 服务和授权状态')
        return client
    except Exception as error:
        if client is not None:
            try: client.logout()
            except Exception: pass
        if isinstance(error,MailError): raise
        if isinstance(error,imaplib.IMAP4.error):
            raise MailError('邮箱认证或协议访问失败，请检查 IMAP 服务及该邮箱要求的客户端授权凭据') from None
        raise MailError('无法建立安全的邮箱连接，请检查网络、代理和 993 端口后重试') from None

def decode_mailbox(value):
    def replace(match):
        token=match[1]
        if not token:return '&'
        try:return base64.b64decode(token.replace(',','/')+'='*((-len(token))%4)).decode('utf-16-be')
        except (ValueError,UnicodeError):return match[0]
    return re.sub(r'&([A-Za-z0-9+,]*)-',replace,value)

def quote_mailbox(value):
    if not value or any(c in value for c in '\r\n\x00') or not value.isascii():
        raise MailError('请选择连接测试返回的邮件文件夹')
    return '"'+value.replace('\\','\\\\').replace('"','\\"')+'"'

def test_connection(provider,account,authorization_code):
    client=open_connection(provider,account,authorization_code)
    try:
        typ,rows=client.list()
        if typ!='OK':raise MailError('已登录，但无法列出邮件文件夹')
        folders=[]
        for raw in rows or []:
            if not isinstance(raw,bytes):continue
            match=re.match(rb'^\((.*?)\)\s+(?:"[^"]*"|NIL)\s+(.+)$',raw)
            if not match or b'\\noselect' in match[1].lower():continue
            mailbox=match[2].decode('ascii',errors='strict')
            if mailbox.startswith('"') and mailbox.endswith('"'):
                mailbox=re.sub(r'\\(.)',r'\1',mailbox[1:-1])
            folders.append({'mailbox':mailbox,'name':decode_mailbox(mailbox)})
        if not folders:folders=[{'mailbox':'INBOX','name':'INBOX'}]
        return {'connected':True,'provider':PROVIDERS[provider][0],'account':account.strip().lower(),'folders':folders}
    finally:
        try:client.logout()
        except Exception:pass

def date_window(start_date,end_date):
    try:start,end=date.fromisoformat(start_date),date.fromisoformat(end_date)
    except (ValueError,TypeError):raise MailError('日期格式应为 YYYY-MM-DD') from None
    if end<start:raise MailError('结束日期不能早于开始日期')
    zone=timezone(timedelta(hours=8))
    return datetime.combine(start,time.min,zone),datetime.combine(end+timedelta(days=1),time.min,zone)

def imap_date(value):return f'{value.day:02d}-{MONTHS[value.month-1]}-{value.year}'

def internal_date(header):
    match=re.search(rb'INTERNALDATE "(\d{1,2})-([A-Za-z]{3})-(\d{4}) (\d{2}):(\d{2}):(\d{2}) ([+-])(\d{2})(\d{2})"',header)
    if not match:raise MailError('邮件缺少可用的接收时间，已保留为失败项')
    day,month,year,hour,minute,second,sign,zh,zm=[p.decode('ascii') for p in match.groups()]
    offset=(int(zh)*60+int(zm))*(1 if sign=='+' else -1)
    try:return datetime(int(year),MONTHS.index(month.title())+1,int(day),int(hour),int(minute),int(second),tzinfo=timezone(timedelta(minutes=offset)))
    except ValueError:raise MailError('邮件接收时间无法解析') from None

class MailCache:
    def __init__(self,root):
        self.root=Path(root);self.root.mkdir(parents=True,exist_ok=True)
        self.materials=self.root/'materials';self.materials.mkdir(exist_ok=True)
        self.db=sqlite3.connect(self.root/'mail-cache.sqlite')
        self.db.execute('CREATE TABLE IF NOT EXISTS messages (cache_key TEXT PRIMARY KEY, body TEXT NOT NULL)')

    def load(self,key):
        row=self.db.execute('SELECT body FROM messages WHERE cache_key=?',(key,)).fetchone()
        if not row:return None
        result=json.loads(row[0])
        for item in result['files']:
            path=Path(item['path'])
            if not path.is_file() or hashlib.sha256(path.read_bytes()).hexdigest()!=item['hash']:return None
        return result

    def save(self,key,result):
        self.db.execute('INSERT OR REPLACE INTO messages VALUES(?,?)',(key,json.dumps(result,ensure_ascii=False)))
        self.db.commit()

    def store_pdf(self,data):
        digest=hashlib.sha256(data).hexdigest();path=self.materials/(digest+'.pdf')
        duplicate=path.is_file() and hashlib.sha256(path.read_bytes()).hexdigest()==digest
        if not duplicate:
            with tempfile.NamedTemporaryFile(dir=self.materials,suffix='.part',delete=False) as temporary:
                temporary.write(data);staged=Path(temporary.name)
            staged.replace(path)
        return digest,str(path),duplicate

def extract_message(raw,source,cache):
    message=BytesParser(policy=policy.default).parsebytes(raw)
    origin={**source,'subject':str(message.get('Subject',''))[:500],
            'sender':str(message.get('From',''))[:500],'messageId':str(message.get('Message-ID',''))[:500]}
    files=[];pending=[];has_links=False;has_invoice_words=bool(re.search('发票|行程单|报销',origin['subject']))
    if message.defects:pending.append({'reason':'邮件附件结构不完整，请检查原邮件并补充 PDF',**origin})
    for index,part in enumerate(message.walk()):
        if part.is_multipart():continue
        filename=str(part.get_filename() or '')
        data=part.get_payload(decode=True) or b''
        if filename.lower().endswith(('.zip','.rar','.7z')):
            pending.append({'reason':'压缩附件需手动解压后补充','filename':filename,**origin});continue
        is_pdf=b'%PDF-' in data[:1024]
        if is_pdf or filename.lower().endswith('.pdf') or part.get_content_type()=='application/pdf':
            if not is_pdf:
                pending.append({'reason':'标为 PDF 的附件内容无法识别','filename':filename,**origin});continue
            if len(data)>MAX_ATTACHMENT_BYTES:
                pending.append({'reason':'PDF 附件超过 25 MB，请手动补充','filename':filename,**origin});continue
            digest,path,duplicate=cache.store_pdf(data)
            files.append({'path':path,'hash':digest,'filename':filename or f'attachment-{index}.pdf',
                          'partIndex':index,'duplicate':duplicate,**origin})
        elif part.get_content_type() in ('text/plain','text/html'):
            try:text=data[:200000].decode(part.get_content_charset() or 'utf-8',errors='replace')
            except LookupError:text=data[:200000].decode('utf-8',errors='replace')
            has_links=has_links or bool(re.search(r'https?://',text))
            has_invoice_words=has_invoice_words or bool(re.search('发票|行程单|报销',text))
    if not files and has_links and has_invoice_words:
        pending.append({'reason':'邮件含下载链接，请打开原邮件下载 PDF 后补充',**origin})
    return {'files':files,'pending':pending,'subject':origin['subject']}

def scan_mail(provider,account,authorization_code,start_date,end_date,folders,storage_root,
              cancel=None,progress=None):
    start,end=date_window(start_date,end_date)
    account=credentials(provider,account,authorization_code)
    if not isinstance(folders,list) or not folders or len(folders)>30:raise MailError('请选择 1 至 30 个邮件文件夹')
    for folder in folders:quote_mailbox(folder)
    cancel=cancel or threading.Event()
    state={'state':'running','candidateMessages':0,'scannedMessages':0,'inRangeMessages':0,
           'downloaded':0,'duplicates':0,'cachedMessages':0,'files':[], 'pending':[], 'failures':[],
           'account':account,'startDate':start_date,'endDate':end_date,'folder':'','currentUid':'','complete':False}
    def emit():
        if progress:progress(copy.deepcopy(state))
    client=open_connection(provider,account,authorization_code)
    cache=None
    unique_files={}
    try:
        cache=MailCache(storage_root)
        for folder in dict.fromkeys(folders):
            if cancel.is_set():break
            state['folder']=decode_mailbox(folder);emit()
            try:
                typ,_=client.select(quote_mailbox(folder),readonly=True)
                if typ!='OK':raise MailError('文件夹无法以只读方式打开')
                _,validity=client.response('UIDVALIDITY')
                validity_value=(validity[0].decode('ascii') if validity and validity[0] else 'session-'+uuid.uuid4().hex)
                typ,data=client.uid('SEARCH',None,'SINCE',imap_date(start.date()-timedelta(days=1)),
                                    'BEFORE',imap_date(end.date()+timedelta(days=1)))
                if typ!='OK':raise MailError('邮件日期搜索失败')
                uids=(data[0] or b'').split()
                state['candidateMessages']+=len(uids)
                if len(uids)>20000:raise MailError('候选邮件超过 20000 封，请缩小时间区间分批获取')
            except Exception:
                state['failures'].append({'folder':decode_mailbox(folder),'reason':'无法扫描该文件夹，请检查权限或缩小日期区间'});emit();continue
            for uid in uids:
                if cancel.is_set():break
                uid_text=uid.decode('ascii');state['currentUid']=uid_text
                try:
                    typ,metadata=client.uid('FETCH',uid,'(INTERNALDATE RFC822.SIZE)')
                    if typ!='OK':raise MailError('邮件元信息读取失败')
                    header=b' '.join(item[0] if isinstance(item,tuple) else item for item in metadata if isinstance(item,(bytes,tuple)))
                    received=internal_date(header)
                    state['scannedMessages']+=1
                    if not start<=received<end:emit();continue
                    state['inRangeMessages']+=1
                    size=re.search(rb'RFC822.SIZE (\d+)',header)
                    if not size or int(size[1])>MAX_MESSAGE_BYTES:raise MailError('邮件体积未知或超过 50 MB，请从原邮件手动补充')
                    key=json.dumps([account,folder,validity_value,uid_text])
                    result=cache.load(key)
                    if result is not None:
                        state['cachedMessages']+=1
                        for item in result['files']:item['duplicate']=True
                    else:
                        if cancel.is_set():break
                        typ,body=client.uid('FETCH',uid,'(BODY.PEEK[] INTERNALDATE)')
                        if typ!='OK':raise MailError('邮件内容读取失败，下次获取会重试')
                        raw=next((item[1] for item in body if isinstance(item,tuple)),None)
                        if not isinstance(raw,bytes):raise MailError('邮件内容不完整，下次获取会重试')
                        if len(raw)>MAX_MESSAGE_BYTES:raise MailError('邮件超过体积限制，请从原邮件补充')
                        source={'account':account,'folder':folder,'uidValidity':validity_value,
                                'uid':uid_text,'receivedAt':received.isoformat()}
                        result=extract_message(raw,source,cache)
                        cache.save(key,result)
                    for item in result['files']:
                        state['duplicates' if item['duplicate'] else 'downloaded']+=1
                        if item['hash'] not in unique_files:
                            unique_files[item['hash']]=copy.deepcopy(item)
                            state['files'].append(unique_files[item['hash']])
                        else:
                            unique_files[item['hash']].setdefault('additionalSources',[]).append(item)
                    state['pending'].extend(result['pending'])
                except Exception as error:
                    reason=str(error) if isinstance(error,MailError) else '读取失败或连接中断，已完成附件保留，下次可重试'
                    state['failures'].append({'folder':decode_mailbox(folder),'uid':uid_text,'reason':reason})
                    if isinstance(error,(OSError,imaplib.IMAP4.abort)):
                        emit();break
                emit()
        state['state']='cancelled' if cancel.is_set() else 'done'
        state['complete']=state['state']=='done' and not state['failures'] and not state['pending']
        state['currentUid']='';emit()
        return state
    finally:
        if cache is not None:cache.db.close()
        try:client.logout()
        except Exception:pass

class MailJobManager:
    def __init__(self,storage_root):
        self.storage_root=storage_root;self.lock=threading.Lock();self.jobs={}

    def start(self,**params):
        date_window(params.get('start_date'),params.get('end_date'))
        credentials(params.get('provider'),params.get('account',''),params.get('authorization_code',''))
        with self.lock:
            if any(j['result']['state']=='running' for j in self.jobs.values()):raise MailError('已有邮箱获取任务正在运行')
            if len(self.jobs)>10:
                for key in list(self.jobs)[:-5]:self.jobs.pop(key)
            job_id=uuid.uuid4().hex;cancel=threading.Event()
            self.jobs[job_id]={'cancel':cancel,'result':{'state':'running','files':[],'pending':[],'failures':[]}}
        def update(result):
            with self.lock:self.jobs[job_id]['result']=result
        def work():
            try:scan_mail(**params,storage_root=self.storage_root,cancel=cancel,progress=update)
            except Exception as error:
                with self.lock:
                    result=self.jobs[job_id]['result'];result['state']='error'
                    result['error']=str(error) if isinstance(error,MailError) else '邮箱获取失败，请检查设置后重试'
        threading.Thread(target=work,daemon=True,name='mail-import').start()
        return {'jobId':job_id}

    def status(self,job_id):
        with self.lock:
            if job_id not in self.jobs:raise MailError('邮箱任务不存在，请重新获取')
            return copy.deepcopy(self.jobs[job_id]['result'])

    def cancel(self,job_id):
        with self.lock:
            if job_id not in self.jobs:raise MailError('邮箱任务不存在')
            self.jobs[job_id]['cancel'].set()
        return self.status(job_id)
