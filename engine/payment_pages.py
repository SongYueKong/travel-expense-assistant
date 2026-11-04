"""可配置的 A4 支付截图网格，尾页保持相同格子尺寸。"""
from PIL import Image, ImageOps
from reportlab.pdfgen import canvas
from reportlab.lib.pagesizes import A4, landscape
from reportlab.lib.units import mm
from reportlab.pdfbase.pdfmetrics import stringWidth
from typography import report_fonts


def resolve_payment_layout(layout=None):
    if layout is None:
        layout = {'orientation': 'landscape', 'rows': 2, 'columns': 4}
    if not isinstance(layout, dict):
        raise ValueError('支付截图排版设置必须为对象')
    orientation, rows, columns = (layout.get(key) for key in ('orientation', 'rows', 'columns'))
    if (orientation not in ('landscape', 'portrait') or
            type(rows) is not int or not 1 <= rows <= 8 or
            type(columns) is not int or not 1 <= columns <= 8):
        raise ValueError('支付截图排版须指定 A4 方向，行数和列数均须为 1～8')
    return (landscape(A4) if orientation == 'landscape' else A4), rows, columns


def build_payment_pages(pictures, destination, draft=False, layout=None):
    (width, height), rows, columns = resolve_payment_layout(layout)
    page = canvas.Canvas(str(destination), pagesize=(width, height))
    # 预留打印安全边距和编号高度，不裁剪截图内容。
    margin, gap, label_height = 6*mm, 2.5*mm, 7*mm
    header = 7*mm if draft else 0
    per_page = rows * columns
    for offset in range(0, len(pictures), per_page):
        if offset:
            page.showPage()
        batch = pictures[offset:offset+per_page]
        cell_w = (width-2*margin-(columns-1)*gap)/columns
        cell_h = (height-2*margin-header-(rows-1)*gap)/rows
        if draft:
            page.setFont(report_fonts().latin, 9)
            page.drawString(margin, height-margin-4*mm, 'PREVIEW - REVIEW REQUIRED')
        for index, picture in enumerate(batch):
            row, column = divmod(index, columns)
            left = margin+column*(cell_w+gap)
            bottom = height-margin-header-(row+1)*cell_h-row*gap
            with Image.open(picture['path']) as original:
                image = ImageOps.exif_transpose(original).convert('RGB')
                scale = min(cell_w/image.width, (cell_h-label_height)/image.height)
                w, h = image.width*scale, image.height*scale
                x = left+(cell_w-w)/2
                y = bottom+label_height+(cell_h-label_height-h)/2
                page.drawInlineImage(image, x, y, w, h)
            label = picture['number']
            related = picture.get('relatedInvoiceNumbers', [])
            if related:
                references = ', '.join(related) if len(related) <= 2 else related[0]+'..'+related[-1]
                label += ' -> '+references
            font = report_fonts().latin_bold
            font_size = min(14, 14*cell_w/max(1, stringWidth(label, font, 14)))
            page.setFont(font, font_size)
            page.drawCentredString(left+cell_w/2, y-5*mm, label)
    page.save()
