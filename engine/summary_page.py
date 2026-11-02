"""绘制客户端已计算好的费用汇总；不在排版层重新计算单项报销额。"""
from collections import defaultdict
from datetime import date
from reportlab.lib import colors
from reportlab.lib.pagesizes import A4
from reportlab.lib.styles import ParagraphStyle
from reportlab.lib.units import mm
from typography import report_fonts, mixed_text
from reportlab.platypus import SimpleDocTemplate, Paragraph, Spacer, Table, TableStyle

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

def build_summary_pdf(manifest, destination):
    grouped=validate_summary(manifest)
    fonts=report_fonts()
    font=fonts.latin
    body=ParagraphStyle('SummaryBody',fontName=font,fontSize=9.5,leading=15,textColor=colors.black,wordWrap='CJK')
    title=ParagraphStyle('SummaryTitle',parent=body,fontSize=20,leading=28,spaceAfter=10)
    note=ParagraphStyle('SummaryNote',parent=body,fontSize=9,leading=15,spaceAfter=5)
    cell=ParagraphStyle('SummaryCell',parent=body,fontSize=9,leading=13)
    def p(value,bold=False): return Paragraph(mixed_text(value,bold),cell)
    story=[Paragraph(mixed_text('差旅报账费用汇总',True),title)]
    if manifest.get('taskName'): story.append(Paragraph(mixed_text(manifest['taskName']),body));story.append(Spacer(1,5*mm))
    story.append(Paragraph(mixed_text(f"发票 {len(manifest['invoices'])} 张　支付截图 {len(manifest.get('pictures',[]))} 张　金额单位：元　匹配容差：{money(manifest.get('toleranceCents',100))} 元"),note))
    if manifest.get('draft'):
        story.append(Paragraph(mixed_text('待复核预览：以下金额依据当前匹配建议汇总，尚未完成人工确认。'),note))
    story.append(Spacer(1,4*mm))
    data=[[p(v,True) for v in ['费用类别','发票序号','费用说明','发票金额','支付净额','核算金额','对应支付编号']]]
    subtotal_indices=[]
    totals={r['category']:r for r in manifest['categoryTotals']}
    order=[key for key in CATEGORIES if key in grouped]+[key for key in grouped if key not in CATEGORIES]
    for key in order:
        category=CATEGORIES.get(key,'其他费用')
        for row in grouped[key]:
            allowance=row.get('kind')=='allowance'
            data.append([p(category),p('—' if allowance else row['number']),p(row.get('description') or category),
                         *[('—' if allowance and f!='reimbursementCents' else money(row[f])) for f in MONEY_FIELDS],p('—' if allowance else '、'.join(row.get('paymentNumbers',[])))])
        subtotal_indices.append(len(data))
        data.append([p(category+'小计',True),'','',*[('—' if key=='meal' and f!='reimbursementCents' else money(totals[key][f])) for f in MONEY_FIELDS],''])
    grand_index=len(data)
    data.append([p('费用总计',True),'','',*[money(manifest['grandTotals'][f]) for f in MONEY_FIELDS],''])
    table=Table(data,colWidths=[22*mm,18*mm,36*mm,23*mm,23*mm,23*mm,35*mm],repeatRows=1,hAlign='LEFT')
    commands=[('FONTNAME',(0,0),(-1,-1),font),('FONTSIZE',(0,0),(-1,-1),9.5),
      ('LEADING',(0,0),(-1,-1),14),('VALIGN',(0,0),(-1,-1),'MIDDLE'),
      ('GRID',(0,0),(-1,-1),0.4,colors.HexColor('#D9D9D9')),
      ('BACKGROUND',(0,0),(-1,0),colors.HexColor('#E8EEF3')),
      ('TOPPADDING',(0,0),(-1,-1),9),('BOTTOMPADDING',(0,0),(-1,-1),9),
      ('LEFTPADDING',(0,0),(-1,-1),5),('RIGHTPADDING',(0,0),(-1,-1),5),
      ('ALIGN',(3,1),(5,-1),'RIGHT')]
    for i in subtotal_indices:
        commands.extend([('SPAN',(0,i),(2,i)),('BACKGROUND',(0,i),(-1,i),colors.HexColor('#F5F6F8')),('FONTNAME',(3,i),(5,i),fonts.latin_bold)])
    commands.extend([('SPAN',(0,grand_index),(2,grand_index)),('BACKGROUND',(0,grand_index),(-1,grand_index),colors.HexColor('#E8EEF3')),('FONTNAME',(3,grand_index),(5,grand_index),fonts.latin_bold),('FONTSIZE',(3,grand_index),(5,grand_index),11)])
    table.setStyle(TableStyle(commands));story.append(table);story.append(Spacer(1,7*mm))
    story.append(Paragraph(mixed_text('核算口径：票据费用逐张比较发票与对应支付净额，取较小值后累加。伙食补助按含首尾日的出差天数乘以每日标准，另行计入费用总计。'),note))
    for row in grouped.get('meal',[]):
        story.append(Paragraph(mixed_text(f"伙食补助出差日期：{row['tripStartDate']} 至 {row['tripEndDate']}，共 {row['days']} 天，每日 {money(row['dailyRateCents'])} 元。"),note))
    story.append(Paragraph(mixed_text('发票序号与后续票据页一致。市内交通一票对应多笔支付时，使用主序号及支付子序号，行程单紧跟对应发票。'),note))
    SimpleDocTemplate(str(destination),pagesize=A4,leftMargin=15*mm,rightMargin=15*mm,
                      topMargin=18*mm,bottomMargin=18*mm).build(story)
