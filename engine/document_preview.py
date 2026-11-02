"""只读票据预览，按内容哈希缓存单页图片；不改写原 PDF。"""
import hashlib
from io import BytesIO
import math
import os
from pathlib import Path
import tempfile

from pypdf import PdfReader
from documents import parse_pdf


def preview_pdf(path: str, preview_dir: str, page_index: int = 0) -> dict:
    import pypdfium2 as pdfium

    source = Path(path).resolve(strict=True)
    if source.suffix.lower() != '.pdf':
        raise ValueError('票据预览仅支持 PDF')
    if type(page_index) is not int or page_index < 0:
        raise ValueError('预览页码无效')
    data = source.read_bytes()
    digest = hashlib.sha256(data).hexdigest()
    reader = PdfReader(BytesIO(data))
    if reader.is_encrypted:
        raise ValueError('请先提供未加密 PDF')
    if page_index >= len(reader.pages):
        raise ValueError('预览页码超出范围')
    directory = Path(preview_dir).resolve()
    directory.mkdir(parents=True, exist_ok=True)
    target = directory / f'{digest}-preview-v1-{page_index}.png'
    pdf = pdfium.PdfDocument(data)
    try:
        page = pdf[page_index]
        try:
            width, height = page.get_size()
            if not all(math.isfinite(v) and v > 0 for v in (width, height)):
                raise ValueError('PDF 页面尺寸无效')
            if not target.is_file():
                bitmap = page.render(scale=min(2, 1600 / max(width, height)))
                temporary = None
                try:
                    with tempfile.NamedTemporaryFile(dir=directory, suffix='.png', delete=False) as file:
                        temporary = Path(file.name)
                    with bitmap.to_pil() as image:
                        image.save(temporary, format='PNG')
                    os.replace(temporary, target)
                finally:
                    bitmap.close()
                    if temporary is not None:
                        temporary.unlink(missing_ok=True)
        finally:
            page.close()
    finally:
        pdf.close()
    text = '\n'.join(page.extract_text() or '' for page in reader.pages)
    return dict(path=str(target), pageIndex=page_index, pages=len(reader.pages),
                text=text, document=parse_pdf(text))
