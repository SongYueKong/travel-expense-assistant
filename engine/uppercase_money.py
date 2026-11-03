"""将整数分转成人民币大写，全程不使用浮点数。"""
DIGITS = '零壹贰叁肆伍陆柒捌玖'
SMALL_UNITS = ('', '拾', '佰', '仟')
LARGE_UNITS = ('', '万', '亿', '兆', '京')


def _four_digits(value):
    parts = []
    pending_zero = False
    for power in range(3, -1, -1):
        digit = value // (10 ** power) % 10
        if digit:
            if pending_zero:
                parts.append('零')
            parts.append(DIGITS[digit] + SMALL_UNITS[power])
            pending_zero = False
        elif parts:
            pending_zero = True
    return ''.join(parts)


def uppercase_money(cents):
    if type(cents) is not int or cents < 0:
        raise ValueError('人民币大写金额必须为非负整数分')
    yuan, fraction = divmod(cents, 100)
    groups = []
    remaining = yuan
    while remaining:
        remaining, group = divmod(remaining, 10000)
        groups.append(group)
    if len(groups) > len(LARGE_UNITS):
        raise ValueError('金额超出人民币大写支持范围')
    parts = []
    pending_zero = False
    for index in range(len(groups) - 1, -1, -1):
        group = groups[index]
        if not group:
            pending_zero = bool(parts)
            continue
        if parts and (pending_zero or group < 1000):
            parts.append('零')
        parts.append(_four_digits(group) + LARGE_UNITS[index])
        pending_zero = False
    result = (''.join(parts) or '零') + '元'
    if not fraction:
        return result + '整'
    jiao, fen = divmod(fraction, 10)
    if jiao:
        result += DIGITS[jiao] + '角'
    elif yuan:
        result += '零'
    if fen:
        result += DIGITS[fen] + '分'
    return result
