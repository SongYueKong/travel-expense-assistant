"""无交易单号的滴滴账单：完整交易字段加字段图像证据；不凭金额或整图相似度判重。"""
import base64
from datetime import datetime
import re
import unicodedata
from PIL import Image, ImageOps


def compact(text):
    return re.sub(r'\s+', '', unicodedata.normalize('NFKC', text))


def value_row(data, label_text):
    values = []
    for label in data.get('lines', []):
        text = compact(label['text'])
        if text != label_text:
            continue
        for row in data['lines']:
            distance = abs(row['y'] - label['y'])
            if row['x'] > label['x'] + 50 and distance <= min(row['height'], label['height']) * .75:
                values.append((distance, compact(row['text']), row))
    if not values:
        return None
    closest = [v for v in values if v[0] == min(v[0] for v in values)]
    return closest[0] if len({v[1] for v in closest}) == 1 else None


def bitmap_signature(image, data, row):
    sx, sy = image.width / data['width'], image.height / data['height']
    box = (max(0, round((row['x'] - 5) * sx)), max(0, round((row['y'] - 5) * sy)),
           round(image.width * .975), min(image.height, round((row['y'] + row['height'] + 5) * sy)))
    if box[2] <= box[0] or box[3] <= box[1]:
        raise ValueError('字段范围无效')
    pixels = image.crop(box).convert('L').resize((384, 32), Image.Resampling.LANCZOS)
    # 只存小尺寸黑白证据，不改变原图；压缩噪声的少量差异由客户端逐字段校验。
    bits = [int(v < 160) for v in pixels.tobytes()]
    packed = bytes(sum(bits[i + j] << (7-j) for j in range(8)) for i in range(0, len(bits), 8))
    return dict(bits=base64.b64encode(packed).decode('ascii'), ink=sum(bits))


def payment_content_evidence(path, data):
    if (not data or data.get('platform') != 'didi' or data.get('direction') != 'expense'
            or data.get('paymentTransactionId') or not data.get('paymentCandidate')):
        return None
    fields = {}
    for field in ['paymentDateTime', 'rideDateTime']:
        value, source = data.get(field), data.get(field + 'Source')
        if not value or not source:
            return None
        raw = compact(source['text']).replace('一', '-').replace('−', '-')
        if not re.search(r'20\d{2}-\d{2}-\d{2}.*\d{2}:\d{2}:\d{2}', raw):
            return None  # 缺少秒不能拿分钟近似值判重。
        fields[field] = source
    try:
        if datetime.fromisoformat(data['rideDateTime']) > datetime.fromisoformat(data['paymentDateTime']):
            return None
    except (ValueError, TypeError):
        return None
    description, method = value_row(data, '商品说明'), value_row(data, '付款方式')
    if not description or not method or '滴滴' not in description[1] or len(description[1]) < 12:
        return None
    facts = dict(platform='didi', cents=data['paymentCandidate']['cents'],
                 paid=data['paymentDateTime'], ride=data['rideDateTime'],
                 description=description[1], method=method[1])
    fields.update(amount=data['paymentCandidate']['source'], description=description[2], method=method[2])
    order = value_row(data, '订单金额')
    if order:
        facts['orderAmount'] = order[1]
        fields['orderAmount'] = order[2]
    try:
        with Image.open(path) as original:
            image = ImageOps.exif_transpose(original).convert('RGB')
            rows = {name: bitmap_signature(image, data, row) for name, row in fields.items()}
            top = min(r['y'] for r in fields.values()) - 50
            bottom = max(r['y'] + r['height'] for r in fields.values()) + 50
            body = image.crop((0, max(0, int(top * image.height/data['height'])), image.width,
                               min(image.height, int(bottom * image.height/data['height']))))
            preview = body.convert('L').resize((32, 64), Image.Resampling.LANCZOS).tobytes()
        if any(r['ink'] < 30 for r in rows.values()):
            return None
        return dict(version=1, facts=facts, rows=rows,
                    body=base64.b64encode(preview).decode('ascii'))
    except (OSError, ValueError, KeyError):
        return None
