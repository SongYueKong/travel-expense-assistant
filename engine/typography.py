"""Windows 系统字体及 PDF 中英文混排，不修改原始票据内的字体。"""
from dataclasses import dataclass
from html import escape
import os
from pathlib import Path
from functools import lru_cache
from reportlab.pdfbase import pdfmetrics
from reportlab.pdfbase.ttfonts import TTFont
from reportlab.pdfbase.cidfonts import UnicodeCIDFont

@dataclass(frozen=True)
class ReportFonts:
    latin: str
    chinese: str
    latin_bold: str
    chinese_bold: str

@lru_cache(maxsize=1)
def report_fonts():
    directory=Path(os.environ.get('WINDIR','C:/Windows'))/'Fonts'
    def register(name,filename,fallback,index=0):
        path=directory/filename
        if not path.is_file():return fallback
        pdfmetrics.registerFont(TTFont(name,str(path),subfontIndex=index))
        return name
    if 'STSong-Light' not in pdfmetrics.getRegisteredFontNames():
        pdfmetrics.registerFont(UnicodeCIDFont('STSong-Light'))
    latin=register('TravelSegoeUI','segoeui.ttf','Helvetica')
    latin_bold=register('TravelSegoeUIBold','segoeuib.ttf','Helvetica-Bold')
    chinese=register('TravelYaHeiUI','msyh.ttc','STSong-Light',index=1)
    chinese_bold=register('TravelYaHeiUIBold','msyhbd.ttc',chinese,index=1)
    return ReportFonts(latin,chinese,latin_bold,chinese_bold)

def mixed_text(value,bold=False):
    """按字形覆盖选择字体；避免将英文和金额也交给中文字体绘制。"""
    fonts=report_fonts()
    latin=fonts.latin_bold if bold else fonts.latin
    chinese=fonts.chinese_bold if bold else fonts.chinese
    cmap=getattr(pdfmetrics.getFont(latin).face,'charToGlyph',None)
    segments=[];current=None;characters=[]
    for char in str(value):
        family=latin if (ord(char) in cmap if cmap is not None else ord(char)<128) else chinese
        if current is not None and family!=current:
            segments.append(f'<font name="{current}">{escape("".join(characters))}</font>');characters=[]
        current=family;characters.append(char)
    if characters:segments.append(f'<font name="{current}">{escape("".join(characters))}</font>')
    return ''.join(segments)
