"""纸质出租车票粘贴页：横向A4，每页一行四个固定尺寸框。"""
from reportlab.lib.pagesizes import A4, landscape
from reportlab.lib.units import mm
from reportlab.pdfgen import canvas
from typography import report_fonts


def build_taxi_pages(entries, output):
    width, height = landscape(A4)
    c = canvas.Canvas(str(output), pagesize=(width, height))
    fonts = report_fonts()
    gap, margin = 3*mm, 10*mm
    box_width = (width-2*margin-3*gap)/4
    for offset in range(0, len(entries), 4):
        c.setFont(fonts.chinese_bold, 13)
        c.drawString(margin, height-12*mm, '出租车纸票粘贴页')
        for index, entry in enumerate(entries[offset:offset+4]):
            x = margin+index*(box_width+gap)
            c.setFont(fonts.latin_bold, 14)
            c.drawString(x, height-23*mm, entry['number'])
            c.setFont(fonts.chinese, 8)
            c.drawRightString(x+box_width, height-23*mm, '粘贴对应纸票')
            c.setLineWidth(.6)
            c.rect(x, 16*mm, box_width, height-43*mm)
        c.showPage()
    c.save()
