"""本地 JSON Lines 处理进程；只处理材料，不计算报销金额。"""
from __future__ import annotations
import hashlib
import json
import os
from pathlib import Path
import re
import sys
import tempfile
from PIL import Image, ImageOps
from pypdf import PdfReader, PdfWriter, Transformation
from pypdf.generic import RectangleObject
from reportlab.pdfgen import canvas
from reportlab.lib.units import mm
from ocr import recognize_image, enrich_ocr
from documents import parse_pdf
from payment_content import payment_content_evidence
from summary_page import build_summary_pdf
from typography import report_fonts
from document_preview import preview_pdf
from payment_pages import build_payment_pages, resolve_payment_layout
from uniform_pages import uniform_pages
from taxi_pages import build_taxi_pages
from statement_page import build_statement_image
from hotel_identity import invoice_seller
from credential_store import credential_store
from mail_service import MailJobManager, test_connection

MAIL_JOBS=MailJobManager(Path(os.environ.get('TRAVEL_ASSISTANT_DATA_DIR',str(Path(__file__).resolve().parents[1])))/'.local'/'mail')


def image_identity(path: str, ocr: dict | None = None) -> dict:
    if Path(path).suffix.lower() not in {'.png', '.jpg', '.jpeg'}:
        raise ValueError('仅支持支付截图图像')
    with Image.open(path) as image:
        pixels = ImageOps.exif_transpose(image).convert('RGBA')
        digest = hashlib.sha256(f'{pixels.width}x{pixels.height}:RGBA:'.encode() + pixels.tobytes()).hexdigest()
    result = dict(imagePixelHash=digest, paymentIdentityVersion=2)
    if ocr and 'lines' in ocr:
        parsed = enrich_ocr(ocr)
        for key in ['paymentTransactionId', 'transactionIdKind']:
            if key in parsed: result[key] = parsed[key]
        evidence = payment_content_evidence(path, parsed)
        if evidence is not None: result['paymentContentEvidence'] = evidence
    return result

def inspect_file(path: str, material_dir: str, source_name: str | None = None, purpose: str | None = None) -> dict:
    source = Path(path).resolve(strict=True)
    suffix = source.suffix.lower()
    allowed = {'.pdf', '.png', '.jpg', '.jpeg', '.bmp', '.webp'} if purpose == 'statement' else {'.pdf', '.png', '.jpg', '.jpeg'}
    if suffix not in allowed:
        raise ValueError('仅支持 PDF、PNG、JPG 和 JPEG')
    digest = hashlib.sha256(source.read_bytes()).hexdigest()
    target = Path(material_dir).resolve() / (digest + suffix)
    target.parent.mkdir(parents=True, exist_ok=True)
    if not target.exists():
        # 内容寻址副本不受原目录后续移动影响。
        with tempfile.NamedTemporaryFile(dir=target.parent, delete=False) as tmp:
            tmp.write(source.read_bytes()); temporary = Path(tmp.name)
        os.replace(temporary, target)
    result = dict(hash=digest, path=str(target), name=source.name, text='',
                  needsReview=True, ocrAvailable=False)
    if suffix == '.pdf':
        reader = PdfReader(target)
        result.update(pages=len(reader.pages), text='\n'.join(p.extract_text() or '' for p in reader.pages))
        result['needsOcr'] = not result['text'].strip()
        result['document'] = parse_pdf(result['text'], source_name=source_name or source.name)
        if result['document']['type'] == 'invoice' and not result['document'].get('issueDate'):
            # 普通提取顺序可能先列所有标签再列数值，酒店备注还会出现入住日期。
            # 用保留版面的文字重新读取开票日期标签，不从多日期中猜选一个。
            try:
                layout = '\n'.join(page.extract_text(extraction_mode='layout') or '' for page in reader.pages)
                result['document'] = parse_pdf(result['text'], layout_text=layout, source_name=source_name or source.name)
            except (ValueError, KeyError, TypeError):
                pass
        if result['document'].get('category')=='hotel':
            result['document']['sellerName']=invoice_seller(reader)
    else:
        with Image.open(target) as image:
            size = image.size
            image.verify()
        if purpose == 'statement':
            result.update(needsOcr=False, document={'type':'supportingDocument','format':'image'},
                          width=size[0],height=size[1])
            return result
        result['needsOcr'] = True
        recognized = recognize_image(str(target))
        result.update(image_identity(str(target), recognized if recognized.get('available') else None))
        result['ocrAvailable'] = recognized['available']
        if recognized['available']:
            result['ocr'] = recognized
            result['text'] = recognized['text']
            result['needsOcr'] = not recognized['text'].strip()
        else:
            result['ocrReason'] = recognized.get('reason')
    return result

def export_pdf(manifest: dict, output: str) -> dict:
    """编号、页序由客户端快照提供；此处只负责渲染。"""
    page_size, _, _ = resolve_payment_layout(manifest.get('paymentLayout'))
    uniform = (manifest.get('paymentLayout') or {}).get('uniformPages', False)
    if type(uniform) is not bool: raise ValueError('统一页面设置必须为布尔值')
    destination = Path(output).resolve()
    if destination.suffix.lower() != '.pdf': raise ValueError('输出必须为 PDF')
    destination.parent.mkdir(parents=True, exist_ok=True)
    invoices = manifest.get('invoices', [])
    pictures = manifest.get('pictures', [])
    if not invoices and not manifest.get('summary'): raise ValueError('至少需要一项费用')
    with tempfile.TemporaryDirectory(dir=destination.parent) as temp:
        writer = PdfWriter()
        if manifest.get('summary'):
            summary_file=Path(temp)/'summary.pdf'
            if uniform:
                build_summary_pdf(manifest,summary_file,page_size=page_size)
            else:
                build_summary_pdf(manifest,summary_file)
            writer.append(str(summary_file))
        for entry in invoices:
            if entry.get('paperTaxi'): continue
            # 每张发票后立刻追加对应行程单。
            paths = [entry['path'], *entry.get('itineraries', []), *entry.get('supportingDocuments', [])]
            for file in paths:
                if file in entry.get('supportingDocuments',[]) and Path(file).suffix.lower() in {'.png','.jpg','.jpeg','.bmp','.webp'}:
                    image_pdf = Path(temp)/f'statement-image-{len(writer.pages)}.pdf'
                    label = entry['number'] + ' / STATEMENT' + (' / PREVIEW - REVIEW REQUIRED' if manifest.get('draft') else '')
                    build_statement_image(file,image_pdf,label)
                    writer.append(str(image_pdf))
                    continue
                reader = PdfReader(file)
                if reader.is_encrypted: raise ValueError('请先提供未加密 PDF')
                for page in reader.pages:
                    page.transfer_rotation_to_content()
                    media,crop=page.mediabox,page.cropbox
                    left,bottom=max(float(media.left),float(crop.left)),max(float(media.bottom),float(crop.bottom))
                    right,top=min(float(media.right),float(crop.right)),min(float(media.top),float(crop.top))
                    width,height=right-left,top-bottom
                    if width<=0 or height<=0: raise ValueError('PDF 可见页面范围无效')
                    page.cropbox=RectangleObject([left,bottom,right,top])
                    # 在新增页边添加编号，不覆盖原票面。
                    expanded = writer.add_blank_page(width, height + 10*mm)
                    expanded.merge_transformed_page(page,Transformation().translate(-left,-bottom))
                    label_file = Path(temp)/'label.pdf'
                    c = canvas.Canvas(str(label_file), pagesize=(width, height+10*mm))
                    c.setFont(report_fonts().latin_bold, 14)
                    label=entry['number'] + (' / STATEMENT' if file in entry.get('supportingDocuments',[]) else '') + (' / PREVIEW - REVIEW REQUIRED' if manifest.get('draft') else '')
                    c.drawString(5*mm, height+3*mm, label)
                    c.save()
                    expanded.merge_page(PdfReader(label_file).pages[0])
        taxis = [entry for entry in invoices if entry.get('paperTaxi')]
        if taxis:
            taxi_file = Path(temp)/'taxi.pdf'
            # 兼容旧版客户端：票面金额也可从按编号对应的汇总明细取得。
            amounts = {row['number']:row.get('invoiceCents') for row in manifest.get('summary',[])}
            taxis = [{**entry,'invoiceCents':entry.get('invoiceCents',amounts.get(entry['number']))} for entry in taxis]
            build_taxi_pages(taxis, taxi_file, manifest.get('paymentLayout'), manifest.get('draft',False))
            writer.append(str(taxi_file))
        if pictures:
            grid_file = Path(temp)/'payments.pdf'
            build_payment_pages(pictures, grid_file, manifest.get('draft',False), manifest.get('paymentLayout'))
            writer.append(str(grid_file))
        staged = Path(temp)/'complete.pdf'
        if uniform:
            writer = uniform_pages(writer, page_size)
        writer.write(staged)
        pages = len(PdfReader(staged).pages)
        os.replace(staged, destination)
    return dict(path=str(destination), pages=pages, pictures=len(pictures))

def dispatch(method: str, params: dict):
    if method == 'ping': return dict(version='0.1.0', ocrEngine='windows-system-if-installed')
    if method == 'inspect': return inspect_file(**params)
    if method == 'image.identity': return image_identity(**params)
    if method == 'document.preview': return preview_pdf(**params)
    if method == 'export': return export_pdf(**params)
    if method == 'mail.test': return test_connection(**params)
    if method == 'mail.credential.get': return credential_store().get(**params)
    if method == 'mail.credential.save': return credential_store().save(**params)
    if method == 'mail.credential.delete': return credential_store().delete(**params)
    if method == 'mail.start': return MAIL_JOBS.start(**params)
    if method == 'mail.status': return MAIL_JOBS.status(**params)
    if method == 'mail.cancel': return MAIL_JOBS.cancel(**params)
    raise ValueError('未知处理方法')

def main():
    sys.stdin.reconfigure(encoding='utf-8')
    sys.stdout.reconfigure(encoding='utf-8')
    for line in sys.stdin:
        request = {}
        try:
            request = json.loads(line)
            result = dict(id=request['id'], result=dispatch(request['method'], request.get('params', {})))
        except Exception as error:
            result = dict(id=request.get('id'), error=dict(type=type(error).__name__, message=str(error)))
        print(json.dumps(result, ensure_ascii=False), flush=True)

if __name__ == '__main__': main()
