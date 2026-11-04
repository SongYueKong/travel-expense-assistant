"""出租车纸票页：每页一行三框，框尺寸与支付截图网格相同。"""
from reportlab.lib.pagesizes import A4, landscape
from reportlab.lib.units import mm
from reportlab.pdfgen import canvas
from reportlab.pdfbase.pdfmetrics import stringWidth
from typography import report_fonts
from payment_pages import (payment_cell_size, resolve_payment_layout,
                           PAYMENT_LEFT_MARGIN, PAYMENT_MARGIN, PAYMENT_GAP)


def build_taxi_pages(entries, output, layout=None, draft=False):
    size,_,_ = resolve_payment_layout(layout)
    # 统一页面开启时直接采用目标纸张，避免后续缩放破坏与截图格子的等大关系。
    width,height = size if (layout or {}).get('uniformPages',False) else landscape(A4)
    box_width,box_height = payment_cell_size(layout,draft)
    header = 7*mm if draft else 0
    if (3*box_width+2*PAYMENT_GAP > width-PAYMENT_LEFT_MARGIN-PAYMENT_MARGIN+.01 or
            box_height > height-2*PAYMENT_MARGIN-header+.01):
        raise ValueError('当前支付截图格子过大，A4 页面无法放置一行三个等大出租车票框；请在支付截图排版中增加行数或列数后导出')
    for entry in entries:
        if type(entry.get('invoiceCents')) is not int or entry['invoiceCents'] < 0:
            raise ValueError('出租车票缺少有效的票面金额，请重新核验该记录后导出')
    c = canvas.Canvas(str(output), pagesize=(width,height))
    fonts = report_fonts()
    y = height-PAYMENT_MARGIN-header-box_height
    for offset in range(0,len(entries),3):
        if draft:
            c.setFont(fonts.latin,9)
            c.drawString(PAYMENT_LEFT_MARGIN,height-PAYMENT_MARGIN-4*mm,'PREVIEW - REVIEW REQUIRED')
        for index,entry in enumerate(entries[offset:offset+3]):
            x = PAYMENT_LEFT_MARGIN+index*(box_width+PAYMENT_GAP)
            c.setLineWidth(.6)
            c.rect(x,y,box_width,box_height)
            title = '出租车纸票粘贴区'
            title_size = min(9,9*(box_width-4*mm)/max(1,stringWidth(title,fonts.chinese,9)))
            c.setFont(fonts.chinese,title_size)
            c.drawString(x+2*mm,y+box_height-5*mm,title)
            amount = entry['invoiceCents']
            label = f'{entry["number"]}   ¥{amount//100:,}.{amount%100:02d}'
            font_size = min(14,14*(box_width-4*mm)/max(1,stringWidth(label,fonts.latin_bold,14)))
            c.setFont(fonts.latin_bold,font_size)
            c.drawCentredString(x+box_width/2,y+2*mm,label)
        c.showPage()
    c.save()
