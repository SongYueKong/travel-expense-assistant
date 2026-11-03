"""将已组装页面的可见内容等比例放入统一纸张，保留页序与原文件。"""
from pypdf import PdfWriter, Transformation
from pypdf.generic import RectangleObject


def uniform_pages(source, page_size):
    writer = PdfWriter()
    width, height = page_size
    for page in source.pages:
        page.transfer_rotation_to_content()
        media, crop = page.mediabox, page.cropbox
        left, bottom = max(float(media.left), float(crop.left)), max(float(media.bottom), float(crop.bottom))
        right, top = min(float(media.right), float(crop.right)), min(float(media.top), float(crop.top))
        visible_width, visible_height = right-left, top-bottom
        if visible_width <= 0 or visible_height <= 0:
            raise ValueError('PDF 可见页面范围无效')
        page.cropbox = RectangleObject([left, bottom, right, top])
        scale = min(width/visible_width, height/visible_height)
        x, y = (width-visible_width*scale)/2, (height-visible_height*scale)/2
        target = writer.add_blank_page(width, height)
        target.merge_transformed_page(page, Transformation(ctm=(scale, 0, 0, scale, x-left*scale, y-bottom*scale)))
    return writer
