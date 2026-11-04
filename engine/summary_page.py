"""绘制客户端已计算好的费用汇总；不在排版层重新计算单项报销额。"""
from collections import defaultdict
from datetime import date
from reportlab.lib import colors
from reportlab.lib.pagesizes import A4
from reportlab.lib.styles import ParagraphStyle
from reportlab.lib.units import mm
from typography import report_fonts, mixed_text
from reportlab.platypus import SimpleDocTemplate, Paragraph, Spacer, Table, TableStyle, KeepTogether
from uppercase_money import uppercase_money

CATEGORIES={'intercity':'城际交通','hotel':'酒店住宿','local':'市内交通','meal':'伙食补助费'}
MONEY_FIELDS=('invoiceCents','paymentCents','reimbursementCents')

def money(value):
    if type(value) is not int or value<0: raise ValueError('汇总金额必须为非负整数分')
    return f'{value//100:,}.{value%100:02d}'

def validate_summary(manifest):
    rows=manifest['summary']
    grouped=defaultdict(list)
    allowances=[]
    for row in rows:
        for field in MONEY_FIELDS: money(row[field])
        if row.get('kind')=='allowance':
            allowances.append(row)
            if row['category']!='meal' or row['invoiceCents'] or row['paymentCents'] or row.get('paymentNumbers'):
                raise ValueError('伙食补助不能包含发票或支付金额')
            days,rate=row.get('days'),row.get('dailyRateCents')
            if type(days) is not int or days<1 or type(rate) is not int or rate<0 or row['reimbursementCents']!=days*rate:
                raise ValueError('伙食补助金额与天数、标准不符')
            start,end=date.fromisoformat(row['tripStartDate']),date.fromisoformat(row['tripEndDate'])
            if not (2000<=start.year<=2100 and 2000<=end.year<=2100) or (end-start).days+1!=days:
                raise ValueError('伙食补助天数与出差日期不符')
        elif row['category']=='meal':
            raise ValueError('伙食补助明细类型无效')
        grouped[row['category']].append(row)
    if len(allowances)>1: raise ValueError('伙食补助重复')
    if len({r['number'] for r in rows})!=len(rows): raise ValueError('汇总发票编号重复')
    if {r['number'] for r in rows if r.get('kind')!='allowance'}!={i['number'] for i in manifest['invoices']}:
        raise ValueError('汇总明细与发票编号不一致')
    categories=manifest.get('categoryTotals',[])
    if len({r['category'] for r in categories})!=len(categories) or {r['category'] for r in categories}!=set(grouped):
        raise ValueError('分类小计不完整')
    for total in categories:
        for field in MONEY_FIELDS:
            if total[field]!=sum(r[field] for r in grouped[total['category']]): raise ValueError('分类小计与明细不符')
    for field in MONEY_FIELDS:
        if manifest.get('grandTotals',{}).get(field)!=sum(r[field] for r in rows): raise ValueError('总计与明细不符')
    return grouped

def summary_period(manifest):
    start, end = manifest.get('tripStartDate'), manifest.get('tripEndDate')
    if start is None and end is None:
        meal = next((row for row in manifest['summary'] if row.get('kind') == 'allowance'), None)
        if meal:
            start, end = meal['tripStartDate'], meal['tripEndDate']
        else:
            return None
    try:
        first, last = date.fromisoformat(start), date.fromisoformat(end)
    except (ValueError, TypeError):
        raise ValueError('出差日期无效，请检查差旅设置') from None
    if first > last or first.year < 2000 or last.year > 2100:
        raise ValueError('出差日期无效，请检查差旅设置')
    return start, end, (last-first).days+1


def claim_rows(manifest, grouped):
    period = summary_period(manifest)
    totals = {row['category']: row['reimbursementCents'] for row in manifest['categoryTotals']}
    rows = [
        ['城市间交通费', str(len(grouped.get('intercity', []))), '—', '—', totals.get('intercity', 0)],
        ['市内交通费', '—', '—', '—', totals.get('local', 0)],
        ['住宿费', '—', '1' if grouped.get('hotel') else '—',
         (str(period[2]) if period else '未设置') if grouped.get('hotel') else '—', totals.get('hotel', 0)],
    ]
    if grouped.get('meal'):
        rows.append(['伙食补助费', '—', '—', str(grouped['meal'][0]['days']), totals['meal']])
    for category in grouped:
        if category not in CATEGORIES:
            rows.append(['其他费用', '—', '—', '—', totals[category]])
    return rows


def build_summary_pdf(manifest, destination, page_size=A4):
    grouped = validate_summary(manifest)
    period = summary_period(manifest)
    fonts = report_fonts()
    width = page_size[0]-30*mm
    row_padding = 10 if page_size[0] > page_size[1] else 15
    ink, accent = colors.HexColor('#183B35'), colors.HexColor('#176B60')
    body = ParagraphStyle('ClaimBody', fontName=fonts.latin, fontSize=11, leading=18, wordWrap='CJK')
    title = ParagraphStyle('ClaimTitle', parent=body, fontSize=22, leading=32, spaceAfter=12, textColor=ink)
    note = ParagraphStyle('ClaimNote', parent=body, fontSize=10, leading=17, textColor=colors.HexColor('#53635F'))
    cell = ParagraphStyle('ClaimCell', parent=body, fontSize=11, leading=18)
    header = ParagraphStyle('ClaimHeader', parent=cell, textColor=colors.white, fontSize=10)
    amount = ParagraphStyle('ClaimAmount', parent=cell, alignment=2, fontSize=12)
    capital = ParagraphStyle('ClaimCapital', parent=body, fontSize=16, leading=26, textColor=ink)
    numeric = ParagraphStyle('ClaimNumeric', parent=body, fontSize=14, leading=23, textColor=ink)
    def p(value, bold=False, style=cell):
        return Paragraph(mixed_text(str(value), bold), style)
    story = [p('差旅报账费用汇总', True, title)]
    if manifest.get('taskName'):
        story.append(p(manifest['taskName'], style=body))
    if period:
        story.append(p(f'出差日期：{period[0]} 至 {period[1]}　共 {period[2]} 天', style=note))
    story.append(Spacer(1, 8*mm))
    if manifest.get('draft'):
        story.append(p('待复核预览', True, note))
    data = [[p(value, True, header) for value in ['费用类别', '单据数量', '人数', '天数', '申报金额（元）']]]
    for row in claim_rows(manifest, grouped):
        data.append([p(row[0], True), *[p(value) for value in row[1:4]], p(money(row[4]), True, amount)])
    table = Table(data, colWidths=[width*value/180 for value in [50,30,25,25,50]], repeatRows=1, hAlign='LEFT')
    table.setStyle(TableStyle([
        ('BACKGROUND', (0,0), (-1,0), accent),
        ('ROWBACKGROUNDS', (0,1), (-1,-1), [colors.white, colors.HexColor('#F3F7F6')]),
        ('LINEBELOW', (0,0), (-1,0), 1, accent),
        ('LINEBELOW', (0,1), (-1,-1), .45, colors.HexColor('#D8E3DF')),
        ('VALIGN', (0,0), (-1,-1), 'MIDDLE'),
        ('TOPPADDING', (0,0), (-1,-1), row_padding), ('BOTTOMPADDING', (0,0), (-1,-1), row_padding),
        ('LEFTPADDING', (0,0), (-1,-1), 10), ('RIGHTPADDING', (0,0), (-1,-1), 10),
    ]))
    story.extend([table, Spacer(1, 10*mm)])
    total = manifest['grandTotals']['reimbursementCents']
    card = Table([
        [p('申报金额合计', True, note)],
        [p('人民币大写：'+uppercase_money(total), True, capital)],
        [p('人民币小写：¥ '+money(total), style=numeric)],
    ], colWidths=[width], hAlign='LEFT')
    card.setStyle(TableStyle([
        ('BACKGROUND', (0,0), (-1,-1), colors.HexColor('#EAF3EF')),
        ('BOX', (0,0), (-1,-1), .6, colors.HexColor('#C6DDD2')),
        ('LEFTPADDING', (0,0), (-1,-1), 16), ('RIGHTPADDING', (0,0), (-1,-1), 16),
        ('TOPPADDING', (0,0), (-1,0), 14), ('BOTTOMPADDING', (0,-1), (-1,-1), 14),
        ('TOPPADDING', (0,1), (-1,-1), 5), ('BOTTOMPADDING', (0,0), (-1,-2), 5),
    ]))
    story.append(KeepTogether([card]))
    SimpleDocTemplate(str(destination), pagesize=page_size, leftMargin=15*mm, rightMargin=15*mm,
                      topMargin=18*mm, bottomMargin=18*mm).build(story)
