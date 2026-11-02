import argparse
import hashlib
import json
from pathlib import Path
import zipfile
parser=argparse.ArgumentParser();parser.add_argument('--package',required=True);parser.add_argument('--output',required=True)
args=parser.parse_args();package=Path(args.package).resolve();output=Path(args.output).resolve()
if output.exists():raise RuntimeError('压缩包已存在，不覆盖旧版本')
files={p.relative_to(package).as_posix():hashlib.sha256(p.read_bytes()).hexdigest() for p in package.rglob('*') if p.is_file() and '__pycache__' not in p.parts and p.name!='files.sha256.json'}
(package/'files.sha256.json').write_text(json.dumps(files,ensure_ascii=False,indent=2),encoding='utf-8')
with zipfile.ZipFile(output,'x',compression=zipfile.ZIP_DEFLATED,compresslevel=6) as archive:
    for name in [*files,'files.sha256.json']:archive.write(package/name,f'{package.name}/{name}')
digest=hashlib.sha256(output.read_bytes()).hexdigest()
output.with_suffix(output.suffix+'.sha256').write_text(f'{digest}  {output.name}\n',encoding='utf-8')
print(json.dumps({'zip':str(output),'bytes':output.stat().st_size,'sha256':digest},ensure_ascii=False))
