"""扫描发票 PDF 的本地 OCR 后备路径；金额只采纳明确价税合计/小写字段。"""
import re
import tempfile
from documents import parse_pdf
from ocr import _run_ocr
from payment_amounts import compact, amount_value, field_rows
from document_preview import preview_pdf


def parse_invoice_ocr(data, source_name=''):
    rows=data.get('lines',[])
    text='\n'.join(compact(row['text']) for row in rows)
    document=parse_pdf(text,source_name=source_name)
    totals=set()
    for row in rows:
        value=compact(row['text'])
        for match in re.finditer(r'(?:小写[)）]?[:：]?|价税合计[:：]?)[¥￥]?([\d,]+[.·]\d{2})(?!\d)',value):
            parsed=amount_value(match[1])
            if parsed is not None:totals.add(parsed)
    for label in ['(小写)','小写','价税合计']:
        for row in field_rows(data,label):
            if compact(row['text']).startswith(('-', '−', '一')):continue
            parsed=amount_value(row['text'])
            if parsed is not None:totals.add(parsed)
    # 不把商品金额、税额或任意最后一个数字当成价税合计。
    document['totalCents']=next(iter(totals)) if len(totals)==1 and document.get('type')=='invoice' else None
    numbers=set(re.findall(r'(?<!\d)\d{20}(?!\d)',text))
    if len(numbers)>1 or '红字' in text:
        document['totalCents']=None
    document.pop('amountSource',None)
    document.pop('amountMethod',None)
    if document['totalCents'] is not None:
        document.update(amountSource='价税合计／小写字段',amountMethod='ocr-labelled-total')
    document['recognitionMethod']='windows-local-ocr'
    return text,document


def recognize_invoice_pdf(path, source_name=''):
    with tempfile.TemporaryDirectory(prefix='travel-invoice-ocr-') as temp:
        preview=preview_pdf(path,temp)
        if preview['pages']!=1:
            return dict(available=False,reason='扫描 PDF 请按单张发票分别导入；多页材料可人工核对')
        raw=_run_ocr(preview['path'])
    if raw.get('available') is False:return raw
    text,document=parse_invoice_ocr(raw,source_name)
    return dict(available=True,text=text,document=document,lines=raw['lines'])
