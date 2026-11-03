"""仅支持已核实的17win公开发票短链接；不执行页面脚本或读取登录凭据。"""
import re
from html import unescape
from urllib.parse import urlsplit
from urllib.request import Request, HTTPRedirectHandler, build_opener, HTTPSHandler
import ssl

ALLOWED_HOSTS={'t.17win.com','servu-invoice.oss-cn-hangzhou.aliyuncs.com'}

def validate_url(url):
    parsed=urlsplit(url)
    if parsed.scheme!='https' or parsed.hostname not in ALLOWED_HOSTS or parsed.username or parsed.password or parsed.port not in (None,443):
        raise ValueError('发票下载跳转目标不在支持范围')
    return url

def invoice_links(text):
    result=[]
    for value in re.findall(r'https://[^\s<>"\x27]+',unescape(text)):
        value=value.rstrip('。，,;；)）')
        parsed=urlsplit(value)
        if parsed.hostname=='t.17win.com' and value not in result:
            try:validate_url(value)
            except ValueError:continue
            result.append(value)
    return result[:3]

class InvoiceRedirects(HTTPRedirectHandler):
    def redirect_request(self,req,fp,code,msg,headers,newurl):
        validate_url(newurl)
        return super().redirect_request(req,fp,code,msg,headers,newurl)

def download_invoice_pdf(url,max_bytes=25*1024*1024):
    validate_url(url)
    if urlsplit(url).hostname!='t.17win.com':raise ValueError('仅接受17win短链接')
    opener=build_opener(InvoiceRedirects(),HTTPSHandler(context=ssl.create_default_context()))
    with opener.open(Request(url,headers={'User-Agent':'TravelExpenseAssistant/0.1.14'}),timeout=20) as response:
        validate_url(response.geturl())
        size=response.headers.get('Content-Length')
        if size and int(size)>max_bytes:raise ValueError('发票文件超过体积限制')
        data=response.read(max_bytes+1)
    if len(data)>max_bytes:raise ValueError('发票文件超过体积限制')
    if b'%PDF-' not in data[:1024]:raise ValueError('链接返回的内容不是PDF，可能已失效或需要人工验证')
    return data
