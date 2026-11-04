"""结构化字段候选；原始文字始终保留，字段未经人工复核。"""
from datetime import date, datetime
import re
import unicodedata

def cents(value: str) -> int:
    parts=value.replace(',', '').split('.')
    return int(parts[0])*100+int(parts[1].ljust(2,'0'))

def labelled_issue_date(text: str):
    """只采纳开票日期标签后的明确日期，排除入住日期等其他字段。"""
    values = set()
    for match in re.finditer(r'开票日期\s*[:：]?\s*(20\d{2})年(\d{1,2})月(\d{1,2})日',
                             unicodedata.normalize('NFKC', text)):
        try:
            values.add(date(*map(int, match.groups())).isoformat())
        except ValueError:
            return None
    return next(iter(values)) if len(values) == 1 else None


def parse_pdf(text: str, *, layout_text: str | None = None, source_name: str = '') -> dict:
    normalized=unicodedata.normalize('NFKC',text)
    compact=re.sub(r'\s+','',normalized)
    result=dict(type='unknown', needsReview=True)
    if '行程单' in compact and ('高德' in compact or 'AMAPITINERARY' in compact.upper()):
        total=re.search(r'合计([\d,]+\.\d{2})元',compact)
        count=re.search(r'共计?(\d+)(?:单|笔)行程',compact)
        starts=list(re.finditer(r'(?m)^[ \t]*(\d+)\s+([\u3400-\u9fffA-Za-z0-9·()（） \t\r\n-]{1,80}?)\s+(20\d{2}-\d{2}-\d{2})\s+(\d{2}\s*:\s*\d{2})(?=\s|$)',normalized))
        trips=[]
        for index,header in enumerate(starts):
            segment=normalized[header.end():starts[index+1].start() if index+1<len(starts) else len(normalized)]
            amounts=list(re.finditer(r'(?<![\d.])([\d,]+\.\d{2})\s*元',segment))
            if len(amounts)!=1:continue
            try:datetime.strptime(header[3]+' '+header[4],'%Y-%m-%d %H:%M')
            except ValueError:continue
            names=header[2].rsplit(None,1)
            trips.append(dict(index=int(header[1]), date=header[3], time=header[4],
                vehicleType=re.sub(r'\s+','',names[-1]),
                serviceProvider=re.sub(r'\s+','',names[0]) if len(names)>1 else None,
                cents=cents(amounts[0][1]),source=header[0]+segment[:amounts[0].end()]))
        result.update(type='itinerary',category='local',platform='gaode',
            totalCents=cents(total[1]) if total else None,expectedCount=int(count[1]) if count else None,
            trips=trips,complete=bool(count and total and int(count[1])>0 and len(trips)==int(count[1])
                and all(t['index']==i for i,t in enumerate(trips,1)) and sum(t['cents'] for t in trips)==cents(total[1])))
        return result
    if '行程单' in compact and ('滴滴' in compact or 'DIDITRAVEL' in compact):
        result.update(type='itinerary', category='local', platform='didi')
        total=re.search(r'合计([\d,]+\.\d{2})元',compact)
        count=re.search(r'共(\d+)笔行程',compact)
        year=re.search(r'(20\d{2})-\d{2}-\d{2}',normalized)
        # 按“序号 + 车型 + 日期 + 时间”定位，车型允许跨行，避免车型白名单漏掉甄选等服务。
        starts=list(re.finditer(r'(?m)^[ \t]*(\d+)\s+([\u3400-\u9fffA-Za-z·()（） \t\r\n-]{1,40}?)\s+(\d{2}-\d{2})\s+(\d{2}\s*:\s*\d{2})(?=\s|$)',normalized))
        trips=[]
        for index,header in enumerate(starts):
            segment=normalized[header.end():starts[index+1].start() if index+1<len(starts) else len(normalized)]
            amount=re.search(r'(\d+(?:\.\d+)?)\s+(\d+\.\d{2})\b',segment)
            if not amount: continue
            trips.append(dict(index=int(header[1]),date=f'{year[1]}-{header[3]}' if year else None,
              time=re.sub(r'\s+','',header[4]),vehicleType=re.sub(r'\s+','',header[2]),
              cents=cents(amount[2]),source=header[0]+segment[:amount.end()]))
        result.update(totalCents=cents(total[1]) if total else None, expectedCount=int(count[1]) if count else None,
          trips=trips, complete=bool(count and total and year and int(count[1])>0 and
            len(trips)==int(count[1]) and all(t['index']==i for i,t in enumerate(trips,1)) and
            sum(t['cents'] for t in trips)==cents(total[1])))
        return result
    if '发票' not in compact: return result
    result['type']='invoice'
    source_compact = re.sub(r'\s+', '', unicodedata.normalize('NFKC', source_name))
    # 部分滴滴发票仅有英文 logo；文件名只在票面有相关服务项目时辅助分类。
    platform_service_fee = ('信息技术服务费' in compact or
                            bool(re.search(r'信息技[^\r\n]{0,100}\r?\n\s*术服务费', normalized)))
    service_item = platform_service_fee or bool(re.search(r'客运服务|旅客运输服务', compact))
    didi_brand = ('滴滴' in compact or
                  bool(re.search(r'(?<![A-Za-z0-9])didi(?![A-Za-z0-9])', normalized, re.I)) or
                  ('滴滴' in source_compact and service_item))
    result['category']='intercity' if '铁路电子客票' in compact else ('hotel' if '住宿费' in compact else ('local' if didi_brand else None))
    result['platform']='didi' if didi_brand and result['category']=='local' else ('rail' if '铁路电子客票' in compact else None)
    if result['platform']=='didi' and platform_service_fee:
        result['expenseKind']='platformServiceFee'
    context = compact + source_compact
    if result['category'] is None and any(label in context for label in ['高德打车','高德地图']) and any(label in compact for label in ['客运服务','旅客运输服务']):
        result.update(category='local',platform='gaode')
    if result['category'] is None and re.search(r'代订机票|航空旅客运输|航空运输服务',compact):
        result.update(category='intercity',platform='air')
    identifiers=list(dict.fromkeys(re.findall(r'(?<!\d)\d{20}(?!\d)',normalized)))
    direct=re.search(r'发票号码\s*[:：]?\s*(\d{20})',normalized)
    result['number']=direct[1] if direct else (identifiers[0] if len(identifiers)==1 else None)
    values=[]
    for m in re.finditer(r'[¥￥]\s*([\d,]+\.\d{2})|([\d,]+\.\d{2})\s*[¥￥]',normalized):
        values.append((cents(m[1] or m[2]),m.group()))
    if values and '红字' not in compact:
        value,source=max(values,key=lambda item:item[0])
        result.update(totalCents=value,amountSource=source,amountMethod='currency-total-candidate')
    issued = labelled_issue_date(layout_text) if layout_text is not None else labelled_issue_date(normalized)
    if issued:
        result['issueDate'] = issued
        result['issueDateMethod'] = 'layout-labelled' if layout_text is not None else 'labelled'
    elif '开票日期' in normalized:
        dates=list(dict.fromkeys(re.findall(r'(20\d{2})年(\d{1,2})月(\d{1,2})日',normalized)))
        if len(dates)==1:
            try: result['issueDate']=date(*map(int,dates[0])).isoformat()
            except ValueError: pass
    travel=re.search(r'(20\d{2})年(\d{1,2})月(\d{1,2})日\s*\d{2}:\d{2}开',normalized)
    if travel: result['expenseDate']=date(*map(int,travel.groups())).isoformat()
    return result
