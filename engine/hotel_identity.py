"""只提取明确购销方／收款方字段，无法确定时交由人工核对。"""
import re
import unicodedata

def compact(value):return re.sub(r'\s+','',unicodedata.normalize('NFKC',value))

def invoice_seller(reader):
    names=set()
    for page in reader.pages:
        text=page.extract_text() or ''
        explicit=re.findall(r'销售方名称\s*[:：]\s*([^\n]+)',text)
        names.update(compact(v) for v in explicit if v.strip())
        fragments=[]
        def visit(text,cm,tm,font,size):
            if text.strip():fragments.append((compact(text),tm[4],tm[5]))
        page.extract_text(visitor_text=visit)
        # 数电发票购销方左右分栏，使用销售方区域的“名称”字段坐标。
        for label,x,y in fragments:
            if label not in ['销','销售方','销售方信息']:continue
            anchors=[(a,b,c) for a,b,c in fragments if a in ['名称:','名称：'] and x<b<x+65 and abs(c-y)<45]
            for _,ax,ay in anchors:
                values=[a for a,b,c in fragments if b>ax+10 and abs(c-ay)<3 and not a.startswith(('名称','统一社会','销售方'))]
                if len(values)==1:names.add(values[0])
    if not names:
        # 部分票据使用独立变换矩阵，tm坐标不能直接比较；版面文本保留购销方列。
        for page in reader.pages:
            try:
                layout = page.extract_text(extraction_mode='layout') or ''
            except (TypeError, ValueError, KeyError):
                continue
            for line in layout.splitlines():
                match = re.search(r'(?:销售方(?:信息)?|销)名称[:：](.+)$', compact(line))
                if match: names.add(match[1])
    return next(iter(names)) if len(names)==1 else None

def payment_payee(data):
    names=set()
    for label in data.get('lines',[]):
        text=compact(label['text'])
        match=re.match(r'^(?:收款方全称|收款单位|收款方|商户全称)[:：]?(.*)$',text)
        if not match:continue
        values=[match[1]] if match[1] else [compact(row['text']) for row in data['lines']
           if row['x']>label['x']+50 and abs(row['y']-label['y'])<=max(row['height'],label['height'])*.75]
        names.update(v for v in values if v and v not in ['收款方','付款方','收款方全称','商户全称'])
    return next(iter(names)) if len(names)==1 else None
