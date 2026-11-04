"""说明图片单独排在A4页面，保留完整画面和方向，不改写原件。"""
from PIL import Image, ImageOps
from reportlab.lib.pagesizes import A4, landscape
from reportlab.lib.units import mm
from reportlab.lib.utils import ImageReader
from reportlab.pdfgen import canvas
from typography import report_fonts


def build_statement_image(path, output, label):
    with Image.open(path) as original:
        image = ImageOps.exif_transpose(original).convert('RGBA')
        white = Image.new('RGBA', image.size, 'white')
        white.alpha_composite(image)
        image = white.convert('RGB')
    width, height = landscape(A4) if image.width > image.height else A4
    margin = 12*mm
    scale = min((width-2*margin)/image.width, (height-2*margin)/image.height)
    w, h = image.width*scale, image.height*scale
    c = canvas.Canvas(str(output), pagesize=(width, height))
    c.setFont(report_fonts().latin_bold, 14)
    c.drawString(5*mm, height-7*mm, label)
    c.drawImage(ImageReader(image), (width-w)/2, (height-h)/2, width=w, height=h)
    c.save()
