"""在自带 Python 内离线检查依赖、引擎、PDF、OCR 与 Flutter/SQLite 启动。"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

def main():
    parser=argparse.ArgumentParser();parser.add_argument('--package',default=str(Path(__file__).resolve().parent));parser.add_argument('--report',required=True)
    args=parser.parse_args();package=Path(args.package).resolve();report=Path(args.report)
    if Path(sys.prefix).resolve()!=package/'runtime/python':raise RuntimeError('未使用压缩包内Python')
    if any(not Path(path).resolve().is_relative_to(package) for path in sys.path):raise RuntimeError('Python引用了程序包之外的搜索路径')
    sys.path.insert(0,str(package/'engine'))
    import ssl,imaplib,ctypes
    from PIL import Image,ImageDraw,ImageFont
    from reportlab.pdfgen import canvas
    from pypdf import PdfReader
    from worker import export_pdf,inspect_file
    from document_preview import preview_pdf
    results={'python':sys.version.split()[0],'isolatedPython':True,'ssl':ssl.OPENSSL_VERSION}
    license_text=(package/'LICENSE').read_text(encoding='utf-8')
    source_reference=(package/'SOURCE_CODE.txt').read_text(encoding='utf-8')
    assert 'GNU GENERAL PUBLIC LICENSE' in license_text and 'Version 3, 29 June 2007' in license_text
    version=json.loads((package/'version.json').read_text(encoding='utf-8'))['version']
    assert f'https://github.com/SongYueKong/travel-expense-assistant/tree/v{version}' in source_reference
    assert (package/'THIRD_PARTY_NOTICES.md').is_file()
    results['gplLicenseAndSourceReference']=True
    with tempfile.TemporaryDirectory(prefix='travel-portable-check-',dir=report.parent) as temporary:
        temp=Path(temporary)
        pdf=temp/'invoice.pdf';c=canvas.Canvas(str(pdf));c.drawString(40,700,'PORTABLE TEST INVOICE');c.save()
        image=temp/'payment.png';im=Image.new('RGB',(1000,2200),'white');draw=ImageDraw.Draw(im)
        fontfile=Path(os.environ.get('WINDIR','C:/Windows'))/'Fonts/msyh.ttc'
        font=ImageFont.truetype(str(fontfile),48) if fontfile.exists() else ImageFont.load_default()
        draw.text((100,150),'账单详情',fill='black',font=font);draw.text((300,550),'-100.00',fill='black',font=font);draw.text((250,750),'交易成功',fill='black',font=font);im.save(image)
        output=temp/'export.pdf';export_pdf({'invoices':[{'number':'001','path':str(pdf)}],'pictures':[{'number':'001','path':str(image)}]},str(output))
        assert len(PdfReader(output).pages)==2
        preview=preview_pdf(str(output),str(temp/'previews'));assert Path(preview['path']).is_file()
        results['pdfExportAndPreview']=True
        # 验证发布包内的最新排版参数，避免只检查默认横向网格。
        configured=temp/'portrait-grid.pdf'
        export_pdf({'invoices':[{'number':'001','path':str(pdf)}],
                    'pictures':[{'number':f'001-{i+1:02d}','path':str(image)} for i in range(7)],
                    'paymentLayout':{'orientation':'portrait','rows':3,'columns':2}},str(configured))
        configured_pages=PdfReader(configured).pages
        assert len(configured_pages)==3
        for page in configured_pages[1:]:
            assert abs(float(page.mediabox.width)-210*72/25.4)<0.01
            assert abs(float(page.mediabox.height)-297*72/25.4)<0.01
        assert '001-07' in configured_pages[-1].extract_text()
        results['configurablePaymentLayout']=True
        inspected=inspect_file(str(image),str(temp/'materials'));results['ocrAvailable']=inspected.get('ocrAvailable',False);results['ocrReason']=inspected.get('ocrReason')
        env=dict(os.environ);env['TRAVEL_ASSISTANT_DATA_DIR']=str(temp/'GUI 数据自检');env['PYTHONHOME']='Z:/NO_PYTHON';env['PYTHONPATH']='Z:/NO_PYTHON'
        windir=env.get('WINDIR','C:/Windows');env['PATH']=f'{windir}/System32;{windir};{windir}/System32/WindowsPowerShell/v1.0'
        process=subprocess.run([str(package/'差旅报账助手.exe'),'--portable-self-test'],cwd=temp,env=env,timeout=90,capture_output=True,creationflags=getattr(subprocess,'CREATE_NO_WINDOW',0))
        gui=Path(env['TRAVEL_ASSISTANT_DATA_DIR'])/'self-test.txt'
        if process.returncode!=0 or not gui.exists() or not gui.read_text(encoding='utf-8').startswith('OK'):raise RuntimeError(f'客户端启动自检失败：{process.returncode}，{gui.read_text(encoding="utf-8") if gui.exists() else "没有报告"}')
        results['flutterEngineAndSQLite']=True
    report.write_text(json.dumps(results,ensure_ascii=False,indent=2),encoding='utf-8');print(json.dumps(results,ensure_ascii=False))

if __name__=='__main__':main()
