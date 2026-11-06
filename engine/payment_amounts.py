"""支付金额的语义证据与决策。坐标只比较字段间关系，不使用屏幕位置比例。"""
import re
from statistics import median
import unicodedata


PAID_LABELS = ('实际支付金额', '实际付款金额', '实付金额', '实际支付', '实际付款',
               '支付金额', '付款金额', '实付款', '实付', '扣款金额')
NET_LABELS = ('实际支出', '净支付金额', '净支付', '支付净额')
GROSS_LABELS = ('订单金额', '商品金额', '应付金额', '原支付金额')
DISCOUNT_LABELS = ('优惠合计', '总优惠', '优惠金额', '商家优惠', '商户优惠',
                   '平台优惠', '优惠券', '立减', '红包抵扣', '优惠')
REFUND_LABELS = ('退款金额', '已退款', '退款记录')
BALANCE_LABELS = ('账户余额', '可用余额', '余额')
FIELD_ROLES = {**dict.fromkeys(PAID_LABELS, 'paid'), **dict.fromkeys(NET_LABELS, 'net'),
               **dict.fromkeys(GROSS_LABELS, 'order'), **dict.fromkeys(DISCOUNT_LABELS, 'discount'),
               **dict.fromkeys(REFUND_LABELS, 'refund'), **dict.fromkeys(BALANCE_LABELS, 'balance'),
               '交易金额': 'transaction', '记账金额': 'booked'}
DETAIL_LABELS = ('当前状态', '交易状态', '支付时间', '付款时间', '转账时间', '交易时间',
                 '付款方式', '支付方式', '商品说明', '商户全称', '收款方全称',
                 '订单号', '交易单号', '转账单号', '交易号', '订单金额', '退款记录')
SUCCESS = ('支付成功', '交易成功', '扣款成功', '付款成功')


def compact(value):
    return re.sub(r'\s+', '', unicodedata.normalize('NFKC', value))


def amount_value(text, decimal_comma=False):
    text = compact(text)
    match = re.fullmatch(r'[-−一]?[¥￥]?(\d{1,3}(?:,\d{3})+|\d+)[.·](\d{2})(?:元)?', text)
    if not match and decimal_comma:
        match = re.fullmatch(r'[-−一]?[¥￥]?(\d+),(\d{2})(?:元)?', text)
    if match:
        return int(match[1].replace(',', ''))*100 + int(match[2])
    # 整数须有币种单位；裸整数可能是订单号、积分或里程。
    match = re.fullmatch(r'[-−一]?(?:[¥￥](\d+)(?:元)?|(\d+)元)', text)
    return int(match[1] or match[2])*100 if match else None


def field_rows(data, name):
    result = []
    lines = data.get('lines', [])
    for label in lines:
        text = compact(label['text'])
        if not text.startswith(name):
            continue
        suffix = text[len(name):].lstrip(':：')
        if suffix:
            result.append(dict(label, text=suffix))
            continue
        height = max(label.get('height', 1), 1)
        edge = label['x'] + label.get('width', height*1.5)
        right = [row for row in lines if row is not label and
                 row['x'] >= edge-height*.3 and
                 abs(row['y']+row['height']/2-label['y']-height/2) <= min(row['height'], height)*.75]
        if right:
            # 同一行有多个值时保留冲突，不能随意选择金额。
            result.extend(right)
            continue
        # 支持值换到标签下方；仅取最近行，且不跨过另一个字段。
        next_field = min((r['y'] for r in lines if r is not label and
                          r['y'] > label['y']+height*.7 and abs(r['x']-label['x']) <= height and
                          re.search(r'[\u4e00-\u9fff]', compact(r['text']).replace('元', ''))), default=float('inf'))
        below = [row for row in lines if row is not label and row['y'] < next_field and
                 height*.7 < row['y']-label['y'] <= height*2.5 and
                 abs(row['x']-label['x']) <= height and
                 not re.search(r'[\u4e00-\u9fff]', compact(row['text']).replace('元', ''))]
        if below:
            nearest = min(row['y'] for row in below)
            result.extend(row for row in below if row['y'] == nearest)
    return result


def source_key(row):
    return tuple(row.get(k, 0) for k in ('x', 'y', 'width', 'height'))


def fuzzy_amount(text):
    return (3 <= len(re.findall(r'\d', text)) <= 12 and
            re.search(r'[.·,¥￥&t°℃GgBbＯOIl|]', text) is not None and
            re.fullmatch(r'[\d\s¥￥−一&.,·ＯOIl|t℃°CGgBb–—-]+', unicodedata.normalize('NFKC', text)) is not None)


def evidence(data):
    """每个数字携带用途及原文位置。无法定位用途的数字不会自动成为实付。"""
    items = []
    bound = set()
    for name in sorted(FIELD_ROLES, key=len, reverse=True):
        for row in field_rows(data, name):
            # 长标签先匹配，防止“实付金额”又被当成“实付”的值。
            key = source_key(row)
            if key in bound:
                continue
            text = row.get('retryText', row['text'])
            if FIELD_ROLES[name] == 'refund':
                match = re.fullmatch(r'(?:已退款)?[（(]?([¥￥]?\d+[.·]\d{2})[）)]?[〉>]?', compact(text))
                if match: text = match[1]
            value = amount_value(text, decimal_comma=name in ('交易金额', '记账金额'))
            if value is None and not fuzzy_amount(row['text']):
                continue
            bound.add(key)
            items.append(dict(cents=value, role=FIELD_ROLES[name], label=name, source=row,
                              reason='由“'+name+'”字段定位', confidence='high'))
    lines = data.get('lines', [])
    details = [r for r in lines if compact(r['text']).rstrip(':：') in DETAIL_LABELS]
    body_height = median([r['height'] for r in details]) if details else None
    first_detail = min((r['y'] for r in details), default=float('inf'))
    status = [r for r in lines if any(s in compact(r['text']) for s in SUCCESS)]
    for row in lines:
        if source_key(row) in bound:
            continue
        value = amount_value(row.get('retryText', row['text']))
        if value is None and not fuzzy_amount(row['text']):
            continue
        # 标题金额通过“位于明细之前”及字号/支出符号判断，而非固定屏幕区域。
        negative = compact(row['text']).startswith(('-', '−', '一'))
        prominent = body_height is not None and row['height'] >= body_height*1.25
        nearby_status = any(abs(r['y']-row['y']) <= max(r['height'], row['height'])*3 for r in status)
        header = row['y'] < first_detail and (prominent or (negative and (nearby_status or not details)))
        role = 'header' if header else 'unknown'
        items.append(dict(cents=value, role=role, label='账单主金额' if header else '含义待核对',
                          source=row, reason='金额位于交易明细之前，结合字号和支出符号判断' if header else '未定位到明确金额字段',
                          confidence='medium' if header else 'low'))
    return items


def choose_amount(data, supported, bank=False, refund_cents=None):
    items = evidence(data)
    selected = None
    reason = '没有足够证据确认实际支付金额'
    if not supported:
        reason = '支付状态或支出方向尚未确认'
    elif bank:
        transaction = [r for r in items if r['role'] == 'transaction']
        booked = [r for r in items if r['role'] == 'booked']
        values = {r['cents'] for r in transaction+booked}
        if transaction and booked and len(values) == 1 and None not in values:
            selected = transaction[0]
            reason = '人民币交易金额与记账金额一致'
        else:
            reason = '交易金额与记账金额不一致或未识别'
    else:
        paid = [r for r in items if r['role'] in ('paid', 'net')]
        headers = [r for r in items if r['role'] == 'header']
        primary = paid or headers
        values = {r['cents'] for r in primary}
        if len(values) == 1 and None not in values:
            selected = primary[0]
            reason = '明确实付字段' if paid else '账单主金额与支付状态相互印证'
            header_values = {r['cents'] for r in headers if r['cents'] is not None}
            # 净支付可以和原支付不同，由上层结合明确退款记录核验。
            if paid and header_values and header_values != values and not (
                    all(r['role'] == 'net' for r in paid) and refund_cents is not None and
                    header_values == {selected['cents'] + refund_cents}):
                selected = None
                reason = '实付字段与账单主金额冲突，请核对'
        elif primary:
            reason = '存在多个或未识别的实付候选，请核对'
        if selected:
            # 有明确订单/优惠时核验金额关系，不从订单额或优惠反推未知实付。
            orders = {r['cents'] for r in items if r['role'] == 'order'}
            discounts = {r['cents'] for r in items if r['role'] == 'discount' and r['label'] in ('优惠合计', '总优惠', '优惠金额', '优惠')}
            if not discounts:
                components = [r for r in items if r['role'] == 'discount']
                if components and len({r['label'] for r in components}) == len(components) and all(r['cents'] is not None for r in components):
                    discounts = {sum(r['cents'] for r in components)}
            if len(orders) == 1 and None not in orders:
                order = next(iter(orders))
                if selected['cents'] > order or (len(discounts) == 1 and None not in discounts and
                                                order-next(iter(discounts)) != selected['cents']):
                    selected = None
                    reason = '实付、订单金额和优惠之间的关系不一致，请核对'
    return dict(candidates=items, selected=selected, reason=reason,
                status='recognized' if selected else 'needsReview')


def retry_source(data):
    items = evidence(data)
    primary = [r for r in items if r['role'] in ('paid', 'net')]
    if not primary:
        primary = [r for r in items if r['role'] == 'header']
    unresolved = [r for r in primary if r['cents'] is None and r['source'].get('width', 0) > 0]
    return unresolved[0]['source'] if len(primary) == 1 and len(unresolved) == 1 else None
