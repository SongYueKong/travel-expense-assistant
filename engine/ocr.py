"""平台 OCR 适配器：提取金额、类别及字段时间，交由匹配规则核对。"""
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unicodedata
from datetime import date, datetime
from hotel_identity import payment_payee
from PIL import Image, ImageOps


def labelled_timestamp(data, label_text):
    labels = [line for line in data['lines'] if re.sub(r'\s+', '', line['text']).startswith(label_text)]
    values = []
    for label in labels:
        adjacent = sorted((line for line in data['lines'] if line is label or line['x'] > label['x'] + 50),
                          key=lambda line: abs(line['y'] - label['y']))
        for line in adjacent:
            if abs(line['y'] - label['y']) > max(label['height'], line['height']) * 1.5:
                continue
            text = unicodedata.normalize('NFKC', line['text'])
            text = re.sub(r'\s+', '', text).replace('一', '-').replace('−', '-').replace('：', ':')
            match = re.search(r'(20\d{2})-(\d{2})-(\d{2})[T ]?(\d{2}):(\d{2})(?::(\d{2}))?', text)
            if match:
                try:
                    timestamp = datetime(*[int(v or 0) for v in match.groups()]).isoformat(timespec='seconds') + '+08:00'
                except ValueError:
                    continue
                values.append((abs(line['y'] - label['y']), timestamp, line))
    if not values:
        return None
    distance = min(v[0] for v in values)
    closest = [v for v in values if v[0] == distance]
    if len({v[1] for v in closest}) != 1:
        return None
    return closest[0]

def _run_ocr(path: str) -> dict:
    script = Path(__file__).with_name('windows_ocr.ps1')
    flags = getattr(subprocess, 'CREATE_NO_WINDOW', 0)
    result = subprocess.run(['powershell.exe','-NoProfile','-File',str(script),'-ImagePath',str(Path(path).resolve())],
                            capture_output=True, text=True, encoding='utf-8-sig', timeout=45,
                            creationflags=flags)
    if result.returncode: return dict(available=False, reason='本地 OCR 不可用，请手工录入')
    data = json.loads(result.stdout)
    return data


def amount_value(text):
    value = re.sub(r'\s+', '', unicodedata.normalize('NFKC', text)).replace('¥', '').replace('￥', '')
    match = re.fullmatch(r'[-−一]?(\d+)[.·](\d{2})', value)
    return int(match[1])*100 + int(match[2]) if match else None


def recognize_image(path: str) -> dict:
    if os.name != 'nt': return dict(available=False, reason='当前平台暂无本地 OCR 适配器')
    data = _run_ocr(path)
    if data.get('available') is False: return data
    parsed = enrich_ocr(data)
    if 'paymentCandidate' in parsed or not supported_expense(data): return parsed
    # 只重识别顶部大号金额行；不将 & 等不确定字符直接替换为数字。
    rows = [row for row in data['lines'] if data['height']*.12 < row['y'] < data['height']*.35
            and row['height'] >= data['height']*.018 and row.get('width', 0) > 0
            and re.fullmatch(r'[\d\s¥￥−一&.,·ＯOIl|–—-]+', unicodedata.normalize('NFKC', row['text']))
            and len(re.findall(r'\d', row['text'])) >= 3]
    if not rows: return parsed
    largest = max(row['height'] for row in rows)
    rows = [row for row in rows if row['height'] == largest]
    if len(rows) != 1: return parsed
    row = rows[0]
    try:
        with Image.open(path) as source:
            image = ImageOps.exif_transpose(source)
            attempts = []
            with tempfile.TemporaryDirectory(prefix='travel-amount-') as temporary:
                crop_path = str(Path(temporary)/'amount.png')
                for margin, scale in [(.6, 1), (1, 2)]:
                    pad = max(12, round(row['height']*margin))
                    bounds = (max(0, int(row['x'])-pad), max(0, int(row['y'])-pad),
                              min(image.width, int(row['x']+row['width'])+pad),
                              min(image.height, int(row['y']+row['height'])+pad))
                    crop = image.crop(bounds)
                    crop = crop.resize((crop.width*scale, crop.height*scale))
                    crop.save(crop_path)
                    retry = _run_ocr(crop_path)
                    if retry.get('available') is False: return parsed
                    attempts.append(dict(bounds=list(bounds), scale=scale, lines=retry['lines']))
        data['paymentAmountRetry'] = dict(attempts=attempts, originalSource=row)
        return enrich_ocr(data)
    except (OSError, ValueError, subprocess.SubprocessError):
        # 补识别失败仍保留原文和已识别的时间等字段，交由人工核对。
        return parsed


def supported_expense(data):
    text = re.sub(r'\s+', '', data['text'])
    return ('账单详情' in text and any(s in text for s in ['支付成功', '扣款成功', '交易成功'])
            and not any(s in text for s in ['退款成功', '已退款', '退款到账']))


def payment_transaction(data):
    values = set()
    labels = [('支付宝交易号', 'alipay'), ('微信支付交易单号', 'wechat'),
              ('交易单号', 'transaction'), ('交易号', 'transaction')]
    for label in data['lines']:
        compact = re.sub(r'\s+', '', unicodedata.normalize('NFKC', label['text']))
        matched = next(((text, kind) for text, kind in labels if compact.startswith(text)), None)
        if not matched:
            continue
        text, kind = matched
        candidates = [compact[len(text):].lstrip(':：')]
        for row in data['lines']:
            if row['x'] > label['x'] + 50 and abs(row['y'] - label['y']) <= max(row['height'], label['height']) * .75:
                candidates.append(re.sub(r'\s+', '', unicodedata.normalize('NFKC', row['text'])))
        for value in candidates:
            # 不从商户订单号、截断号、星号掩码或混合说明文字猜测交易身份。
            if re.fullmatch(r'[0-9A-Za-z]{16,64}', value) and any(c.isdigit() for c in value):
                values.add((kind, value))
    return next(iter(values)) if len(values) == 1 else None

def payment_discount(data):
    """只读取明确优惠字段的负数，不把顶部支出、退款或广告当优惠。"""
    labels=r'(?:优惠合计|总优惠|优惠金额|商家优惠|商户优惠|平台优惠|优惠券|立减|红包抵扣|优惠)'
    found=[]
    for label in data['lines']:
        text=unicodedata.normalize('NFKC',label['text'])
        text=re.sub(r'\s+','',text).replace('−','-').replace('－','-')
        match=re.match('^('+labels+')[：:]?',text)
        if not match:continue
        values=[text[match.end():]]
        if not values[0]:
            values=[re.sub(r'\s+','',unicodedata.normalize('NFKC',row['text'])).replace('−','-')
                    for row in data['lines'] if row['x']>label['x']+50 and
                    abs(row['y']-label['y'])<=max(row['height'],label['height'])*.75]
        amounts=set()
        for value in values:
            amount=re.fullmatch(r'-[¥￥]?(\d+)[.·](\d{2})(?:元)?',value)
            if amount:amounts.add(int(amount[1])*100+int(amount[2]))
        if len(amounts)==1:found.append((match[1],amounts.pop(),label))
        elif len(amounts)>1:return None
    totals=[item for item in found if item[0] in ['优惠合计','总优惠','优惠','优惠金额']]
    entries=totals or found
    if not entries or (totals and len({item[1] for item in totals})!=1):return None
    # 相同标签多次出现时无法确认是否重复展示，不叠加猜测。
    if not totals and len({item[0] for item in entries})!=len(entries):return None
    cents=entries[0][1] if totals else sum(item[1] for item in entries)
    return {'cents':cents,'sources':[item[2] for item in entries],'reason':'明确优惠字段中的负金额'} if cents>0 else None


def enrich_ocr(data: dict) -> dict:
    data = dict(data)
    for field in ['paymentDateTime', 'rideDateTime']:
        data.pop(field, None)
        data.pop(field + 'Source', None)
    data.pop('paymentTransactionId', None)
    data.pop('transactionIdKind', None)
    data.pop('discountCandidate', None)
    data.pop('payeeName', None)
    # 支付宝账单适配：顶部大号纯数字金额为实付候选，订单金额等明细单独保留在原文。
    candidates = []
    for line in data['lines']:
        amount = amount_value(line['text'])
        if amount is not None and data['height']*.12 < line['y'] < data['height']*.35:
            candidates.append((line['height'], amount, line))
    compact_text = re.sub(r'\s+', '',data['text'])
    supported = '账单详情' in compact_text and any(s in compact_text for s in ['支付成功','扣款成功','交易成功'])
    refund = any(s in compact_text for s in ['退款成功','已退款','退款到账'])
    if refund: supported=False
    retry = data.get('paymentAmountRetry')
    if supported and not candidates and retry:
        attempts = retry['attempts']
        values = {amount_value(line['text']) for attempt in attempts for line in attempt['lines']}
        # 整个裁剪区域必须只含一个合法金额，不接受多个数字行或混杂说明。
        if len(attempts) == 2 and all(attempt['lines'] for attempt in attempts) and len(values) == 1 and None not in values:
            source = dict(retry['originalSource'], retryText=attempts[0]['lines'][0]['text'],
                          recognition='amount-region')
            candidates.append((source['height'], values.pop(), source))
    transaction = payment_transaction(data) if supported else None
    if transaction:
        data['transactionIdKind'], data['paymentTransactionId'] = transaction
    category = 'local' if any(label in compact_text for label in ['滴滴','高德打车','高德地图']) else ('intercity' if '中国铁路' in compact_text else ('hotel' if '酒店' in compact_text else None))
    if category is None and any(word in compact_text for word in ['出租车', '出租汽车', '计程车', '的士']): category = 'local'
    data.update(category=category, platform=('gaode' if '高德' in compact_text else 'didi') if category=='local' else ('rail' if category=='intercity' else None), direction='refund' if refund else 'expense')
    # 仅从对应字段行取时间，避免状态栏时钟或另一行订单时间混入。
    for label, field in [('支付时间', 'paymentDateTime'), ('乘车时间', 'rideDateTime'), ('上车时间', 'rideDateTime')]:
        value = labelled_timestamp(data, label)
        if value is not None and field not in data:
            data[field] = value[1]
            data[field + 'Source'] = value[2]
    if data.get('paymentDateTime'):
        data['paymentDate'] = data['paymentDateTime'][:10]
    labels=[line for line in data['lines'] if re.sub(r'\s+','',line['text'])=='支付时间']
    if labels:
        label=labels[0]
        adjacent=sorted((line for line in data['lines'] if line['x']>label['x']+50),key=lambda l:abs(l['y']-label['y']))
        for line in adjacent:
            if abs(line['y']-label['y'])>max(label['height'],line['height'])*1.5: continue
            match=re.search(r'(20\d{2})[-一](\d{2})[-一](\d{2})',unicodedata.normalize('NFKC',line['text']).replace(' ',''))
            if match:
                try: data['paymentDate']=date(*map(int,match.groups())).isoformat()
                except ValueError: pass
                break
    if supported and candidates:
        data['payeeName']=payment_payee(data)
        _, value, line = max(candidates,key=lambda entry:entry[0])
        data['paymentCandidate'] = {'cents':value, 'source':line,
                                    'reason':'账单金额区域补识别' if line.get('recognition') == 'amount-region' else '账单顶部大号实付金额候选'}
        discount=payment_discount(data)
        if discount:data['discountCandidate']=discount
    return dict(data, available=True)
