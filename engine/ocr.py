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
from payment_amounts import (amount_value, compact, field_rows, choose_amount,
                             retry_source, evidence, source_key)


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
            text = text.replace('年', '-').replace('月', '-').replace('日', '')
            match = re.search(r'(20\d{2})-(\d{1,2})-(\d{1,2})[T ]?(\d{2}):(\d{2})(?::(\d{2}))?', text)
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


def recognize_image(path: str) -> dict:
    if os.name != 'nt': return dict(available=False, reason='当前平台暂无本地 OCR 适配器')
    data = _run_ocr(path)
    if data.get('available') is False: return data
    parsed = enrich_ocr(data)
    if 'paymentCandidate' in parsed or not supported_expense(data): return parsed
    # 根据实付字段或账单主金额证据定位补识别区域，不依赖屏幕位置。
    row = retry_source(data)
    if row is None: return parsed
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
                parsed = enrich_ocr(data)
                if 'paymentCandidate' not in parsed and payment_profile(data) == 'wechat':
                    # 中文 OCR 对细小小数点可能连成 t；再用灰度阈值图验证，绝不替换字符。
                    pad = max(12, round(row['height']*.6))
                    bounds = (max(0, int(row['x'])-pad), max(0, int(row['y'])-pad),
                              min(image.width, int(row['x']+row['width'])+pad),
                              min(image.height, int(row['y']+row['height'])+pad))
                    crop = image.crop(bounds).convert('L').point(lambda pixel: 255 if pixel > 200 else 0)
                    crop.save(crop_path)
                    retry = _run_ocr(crop_path)
                    if retry.get('available') is not False:
                        attempts.append(dict(bounds=list(bounds), scale=1, preprocessing='threshold-200', lines=retry['lines']))
        return enrich_ocr(data)
    except (OSError, ValueError, subprocess.SubprocessError):
        # 补识别失败仍保留原文和已识别的时间等字段，交由人工核对。
        return parsed


def payment_profile(data):
    text = compact(data['text'])
    if ('收支详情' in text and all(field_rows(data, name) for name in
            ['交易时间', '交易金额', '记账金额', '记账币种']) and
            {compact(row['text']) for row in field_rows(data, '记账币种')} == {'人民币'}):
        return 'bank'
    if (field_rows(data, '当前状态') and
            (field_rows(data, '支付时间') or field_rows(data, '转账时间')) and
            (field_rows(data, '交易单号') or field_rows(data, '转账单号'))):
        return 'wechat'
    return 'alipay' if '账单详情' in text else None


def partial_refund(data):
    """同一微信原支付页中状态和退款记录明确一致才计算净额；重复展示不重复扣减。"""
    if payment_profile(data) != 'wechat':
        return None
    values = []
    for name in ['当前状态', '退款记录']:
        amounts = set()
        for row in field_rows(data, name):
            match = re.fullmatch(r'已退款[（(]?[¥￥]?(\d+)[.·](\d{2})[）)]?[〉>]?', compact(row['text']))
            if match:
                amounts.add(int(match[1])*100 + int(match[2]))
        if len(amounts) != 1:
            return None
        values.append(amounts.pop())
    return values[0] if values[0] > 0 and len(set(values)) == 1 else None


def supported_expense(data):
    text = compact(data['text'])
    profile = payment_profile(data)
    if profile == 'bank':
        # 转账详情必须有明确支出方向，余额和正向入账不能充作支付。
        return bank_amount(data) is not None and any(
            r['role'] == 'header' and re.match(r'^[-−一]\d', compact(r['source']['text']))
            for r in evidence(data))
    if any(s in text for s in ['退款成功', '已退款', '退款到账']):
        return profile == 'wechat' and partial_refund(data) is not None
    success = ('支付成功', '交易成功', '扣款成功', '付款成功')
    states = [compact(row['text']) for name in ('当前状态', '交易状态') for row in field_rows(data, name)]
    if states:
        # 明确状态优先于广告/说明中的“支付成功”等字样，冲突状态不自动采纳。
        return len(set(states)) == 1 and re.fullmatch(r'(?:已|自动)?(?:支付|交易|扣款|付款)成功', states[0]) is not None
    has_banner = any(re.fullmatch(r'(?:已|自动)?(?:支付|交易|扣款|付款)成功',
                                 compact(row['text']).lstrip('•●·✓√✔.．')) for row in data['lines'])
    # 兼容仅有聚合原文状态的旧 OCR 记录；已有行文字时不把否定句或广告当成功横幅。
    if not any(any(word in compact(row['text']) for word in success) for row in data['lines']):
        has_banner = re.search(r'(?<![未不无])(?:支付|交易|扣款|付款)成功', text) is not None
    return (has_banner and (profile == 'alipay' or any(field_rows(data, name) for name in
                ['支付时间', '付款时间', '交易时间', '转账时间', '收款方全称', '收款单位'])))



def bank_amount(data):
    amounts = []
    sources = []
    for name in ['交易金额', '记账金额']:
        rows = field_rows(data, name)
        values = {amount_value(row['text'], decimal_comma=True) for row in rows}
        if len(values) != 1 or None in values:
            return None
        amounts.append(values.pop())
        sources.extend(rows)
    if len(set(amounts)) != 1:
        return None
    return amounts[0], sources[0]


def payment_transaction(data):
    values = set()
    labels = [('支付宝交易号', 'alipay'), ('微信支付交易单号', 'wechat'),
              ('交易单号', 'transaction'), ('交易号', 'transaction'), ('转账单号', 'wechat')]
    for label in data['lines']:
        label_compact = re.sub(r'\s+', '', unicodedata.normalize('NFKC', label['text']))
        matched = next(((text, kind) for text, kind in labels if label_compact.startswith(text)), None)
        if not matched:
            continue
        text, kind = matched
        candidates = [label_compact[len(text):].lstrip(':：')]
        for row in data['lines']:
            if row['x'] > label['x'] + 50 and abs(row['y'] - label['y']) <= max(row['height'], label['height']) * .75:
                value = re.sub(r'\s+', '', unicodedata.normalize('NFKC', row['text']))
                if text == '转账单号' and re.fullmatch(r'\d+', value):
                    # 微信转账单号可能折成两行，不能仅用前半截判重。
                    continuation = [other for other in data['lines']
                                    if 0 < other['y'] - row['y'] <= row['height'] * 2.2
                                    and abs(other['x'] - row['x']) <= row['height']
                                    and re.fullmatch(r'\d+', compact(other['text']))]
                    if len(continuation) > 1:
                        continue
                    if continuation:
                        value += compact(continuation[0]['text'])
                candidates.append(value)
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
    data.pop('paymentCandidate', None)
    data.pop('refundCandidate', None)
    supported = supported_expense(data)
    profile = payment_profile(data)
    compact_text = compact(data['text'])
    refund = any(s in compact_text for s in ['退款成功', '已退款', '退款到账'])
    partial = partial_refund(data)
    if refund and partial is None: supported=False
    analysis_data = data
    retry = data.get('paymentAmountRetry')
    if supported and retry and profile != 'bank':
        attempts = retry['attempts']
        values = {amount_value(line['text']) for attempt in attempts for line in attempt['lines']}
        consistent = (len(attempts) == 2 and all(len(attempt['lines']) == 1 for attempt in attempts)
                      and len(values) == 1 and None not in values)
        if profile == 'wechat' and len(attempts) == 3:
            valid = [amount_value(attempt['lines'][0]['text']) for attempt in attempts
                     if len(attempt['lines']) == 1 and amount_value(attempt['lines'][0]['text']) is not None]
            consistent = len(valid) >= 2 and len(values - {None}) == 1
        original = retry_source(data)
        if consistent and original is not None and original == retry['originalSource']:
            retry_text = next(line['text'] for attempt in attempts for line in attempt['lines']
                              if amount_value(line['text']) is not None)
            analysis_data = dict(data, lines=[dict(row, retryText=retry_text, recognition='amount-region')
                                if source_key(row) == source_key(original) else row for row in data['lines']])
    decision = choose_amount(analysis_data, supported, bank=profile == 'bank', refund_cents=partial)
    data['amountRecognitionVersion'] = 2
    data['amountCandidates'] = decision['candidates']
    data['amountDecision'] = dict(status=decision['status'], reason=decision['reason'])
    transaction = payment_transaction(data) if supported else None
    if transaction:
        data['transactionIdKind'], data['paymentTransactionId'] = transaction
    category = 'local' if any(label in compact_text for label in ['滴滴','高德打车','高德地图','先乘车后付款']) else ('intercity' if '中国铁路' in compact_text else ('hotel' if '酒店' in compact_text else None))
    if category is None and any(word in compact_text for word in ['出租车', '出租汽车', '计程车', '的士']): category = 'local'
    data.update(category=category, platform=('gaode' if '高德' in compact_text else 'didi') if category=='local' else ('rail' if category=='intercity' else None), direction='refund' if refund and partial is None else 'expense')
    # 仅从对应字段行取时间，避免状态栏时钟或另一行订单时间混入。
    for label, field in [('支付时间', 'paymentDateTime'), ('付款时间', 'paymentDateTime'), ('转账时间', 'paymentDateTime'), ('交易时间', 'paymentDateTime'), ('乘车时间', 'rideDateTime'), ('上车时间', 'rideDateTime')]:
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
    selected = decision['selected']
    if selected:
        value, line = selected['cents'], selected['source']
        data['payeeName'] = payment_payee(data)
        if partial is not None:
            if selected['role'] == 'net':
                gross = {r['cents'] for r in decision['candidates'] if r['role'] == 'header'}
                if gross != {value + partial}:
                    data['amountDecision'] = dict(status='needsReview', reason='净支付与原支付、退款记录不一致，请核对')
                    return dict(data, available=True)
                gross_value = value + partial
            else:
                if not compact(line['text']).startswith(('-', '−', '一')) or partial >= value:
                    data['amountDecision'] = dict(status='needsReview', reason='退款未能与原支出金额核验，请核对')
                    return dict(data, available=True)
                gross_value = value
                value -= partial
            data['refundCandidate'] = dict(cents=partial, grossCents=gross_value, reason='当前状态与退款记录金额一致')
        data['paymentCandidate'] = dict(cents=value, source=line, confidence='high',
                reason='原支付金额扣除已退款金额' if partial is not None else
                       '账单金额区域补识别' if line.get('recognition') == 'amount-region' else decision['reason'])
        discount = payment_discount(data)
        if discount: data['discountCandidate'] = discount
    return dict(data, available=True)
