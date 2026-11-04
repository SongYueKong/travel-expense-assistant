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


# 截图网格与纸票粘贴框共用物理尺寸，避免两处参数逐渐不一致。
PAYMENT_LEFT_MARGIN = 20*mm
PAYMENT_MARGIN = 6*mm
PAYMENT_GAP = 2.5*mm
PAYMENT_LABEL_HEIGHT = 7*mm


def payment_cell_size(layout=None, draft=False):
    (width,height),rows,columns = resolve_payment_layout(layout)
    header = 7*mm if draft else 0
    return ((width-PAYMENT_LEFT_MARGIN-PAYMENT_MARGIN-(columns-1)*PAYMENT_GAP)/columns,
            (height-2*PAYMENT_MARGIN-header-(rows-1)*PAYMENT_GAP)/rows)


def build_payment_pages(pictures, destination, draft=False, layout=None):
    (width, height), rows, columns = resolve_payment_layout(layout)
    page = canvas.Canvas(str(destination), pagesize=(width, height))
    # 左侧预留20mm排版边距，其余方向保留打印安全边距；不裁剪截图。
    left_margin, margin, gap, label_height = PAYMENT_LEFT_MARGIN, PAYMENT_MARGIN, PAYMENT_GAP, PAYMENT_LABEL_HEIGHT
    cell_w, cell_h = payment_cell_size(layout, draft)
    header = 7*mm if draft else 0
    per_page = rows * columns
    for offset in range(0, len(pictures), per_page):
        if offset:
            page.showPage()
        batch = pictures[offset:offset+per_page]
        if draft:
            page.setFont(report_fonts().latin, 9)
            page.drawString(left_margin, height-margin-4*mm, 'PREVIEW - REVIEW REQUIRED')
        for index, picture in enumerate(batch):
            row, column = divmod(index, columns)
            left = left_margin+column*(cell_w+gap)
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
