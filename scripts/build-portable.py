"""只收录程序白名单和已安装依赖，不收录工作区、凭据或样本。"""
import argparse
import hashlib
import importlib.metadata as metadata
import json
from pathlib import Path, PurePosixPath
import shutil
import sys
from packaging.requirements import Requirement

def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--root',required=True);parser.add_argument('--stage',required=True)
    parser.add_argument('--version',required=True);parser.add_argument('--redist',required=True)
    parser.add_argument('--release-directory')
    args=parser.parse_args();root=Path(args.root).resolve();stage=Path(args.stage).resolve()
    if stage.exists():raise RuntimeError('发布暂存目录已存在，不覆盖旧版本')
    release=Path(args.release_directory).resolve() if args.release_directory else root/'apps/desktop/build/windows/x64/runner/Release'
    for required in ['travel_assistant.exe','flutter_windows.dll','sqlite3.dll','data/icudtl.dat','data/app.so']:
        if not (release/required).is_file():raise RuntimeError(f'缺少Release发布文件：{required}')
    shutil.copytree(release,stage)
    (stage/'travel_assistant.exe').rename(stage/'差旅报账助手.exe')
    if (stage/'data/flutter_assets/kernel_blob.bin').exists():raise RuntimeError('不得发布 Debug 运行包')
    engine=stage/'engine';engine.mkdir()
    for path in (root/'engine').iterdir():
        if path.is_file() and ((path.suffix=='.py' and not path.name.startswith('test_')) or path.name in ['windows_ocr.ps1','requirements.txt']):
            shutil.copy2(path,engine/path.name)
    base=Path(sys.base_prefix);runtime=stage/'runtime/python';runtime.mkdir(parents=True)
    for path in base.iterdir():
        if path.is_file() and (path.suffix.lower()=='.dll' or path.name in ['python.exe','pythonw.exe','LICENSE.txt']):shutil.copy2(path,runtime/path.name)
    ignored=shutil.ignore_patterns('site-packages','__pycache__','test','tests','idlelib','tkinter','ensurepip','venv')
    shutil.copytree(base/'Lib',runtime/'Lib',ignore=ignored)
    shutil.copytree(base/'DLLs',runtime/'DLLs',ignore=shutil.ignore_patterns('__pycache__','*.pdb','*.lib','_tkinter.pyd','tcl*.dll','tk*.dll'))
    packages=runtime/'Lib/site-packages';packages.mkdir()
    versions={};pending=[]
    for line in (root/'engine/requirements.txt').read_text(encoding='utf-8').splitlines():
        line=line.split('#',1)[0].strip()
        if not line:continue
        requirement=Requirement(line)
        installed=metadata.version(requirement.name)
        if requirement.specifier and installed not in requirement.specifier:raise RuntimeError(f'依赖版本不符合要求：{line}，当前{installed}')
        if requirement.marker is None or requirement.marker.evaluate({'extra':''}):pending.append(requirement.name)
    while pending:
        name=pending.pop();dist=metadata.distribution(name);key=dist.metadata['Name']
        if key.lower().replace('_','-') in versions:continue
        versions[key.lower().replace('_','-')]=dist.version
        for dependency in dist.requires or []:
            requirement=Requirement(dependency)
            if requirement.marker is None or requirement.marker.evaluate({'extra':''}):pending.append(requirement.name)
        if not dist.files:raise RuntimeError(f'无法枚举依赖文件：{key}')
        for file in dist.files:
            relative=PurePosixPath(str(file).replace('\\','/'))
            if '..' in relative.parts or relative.is_absolute() or '__pycache__' in relative.parts or relative.suffix=='.pyc' or relative.name=='direct_url.json':continue
            source=Path(dist.locate_file(file));destination=packages.joinpath(*relative.parts)
            if source.is_file():destination.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(source,destination)
    # 固定搜索路径，禁止继承用户电脑的 Python 注册表、venv 和 PYTHONPATH。
    (runtime/f'python{sys.version_info.major}{sys.version_info.minor}._pth').write_text('.\nDLLs\nLib\nLib/site-packages\n../../engine\nimport site\n',encoding='utf-8')
    redist=Path(args.redist)
    if not (redist/'msvcp140.dll').exists():raise RuntimeError('缺少可再分发的 MSVC x64 运行库')
    for path in redist.glob('*.dll'):shutil.copy2(path,stage/path.name)
    shutil.copy2(root/'scripts/verify-portable.py',stage/'verify-portable.py')
    for name in ['LICENSE','THIRD_PARTY_NOTICES.md','SOURCE_CODE.txt']:
        shutil.copy2(root/name,stage/name)
    source_info=stage/'SOURCE_CODE.txt'
    source_info.write_text(source_info.read_text(encoding='utf-8').replace('0.1.11',args.version),encoding='utf-8')
    usage='''差旅报账助手（Windows 10 / 11，64位）

使用：完整解压到任意普通文件夹，双击“差旅报账助手.exe”。请勿在压缩包内直接运行，不要只复制exe。
无需安装Python、Flutter或开发工具。邮箱导入需要网络，并在邮箱网页版开启IMAP及配置客户端授权凭据。
支持QQ/Foxmail、163、126、yeah、139、新浪sina.com/sina.cn、阿里个人邮箱aliyun.com。

数据默认保存到当前Windows用户的：
%LOCALAPPDATA%\\TravelExpenseAssistant\\Workspace
每次差旅在其中“差旅记录”下独立成文件夹。界面右上角“数据位置”可查看或更换目录。
更换目录后完全退出重开生效；不会自动搬移旧数据。恢复已有数据时选择同时包含“差旅记录”和“.local”的父目录。
备份单次差旅时退出软件并复制整个对应文件夹。邮箱授权码由当前Windows用户凭据管理器保存，不随文件夹传给其他人。

升级：关闭旧程序，把新版压缩包解压到一个新的程序文件夹，再启动新版exe。
程序会使用原数据目录，差旅记录不会随程序替换。确认新版正常后，可删除旧“程序文件夹”；不要删除你的数据目录。
请勿同时运行多个版本操作同一数据目录。

截图OCR依赖Windows自带OCR及中文识别语言；缺少时可手工录入，或在Windows语言设置中安装中文OCR功能。
未使用代码签名；Windows可能显示来源提示。此为试用发布版，建议先用一条差旅核对导出效果。
此压缩包不含开发者的差旅记录、票据、邮箱账号或授权码。

开发者再次打包：在源代码目录运行 scripts/package-portable.ps1。输出版本压缩包与SHA256校验文件。
第三方许可见runtime/python/LICENSE.txt、各依赖.dist-info/licenses及data/flutter_assets/NOTICES.Z。
'''
    (stage/'使用说明.txt').write_text(usage,encoding='utf-8-sig')
    info={'version':args.version,'platform':'windows-x64','python':sys.version.split()[0],'dependencies':versions,
          'license':'GPL-3.0-only','source':f'https://github.com/SongYueKong/travel-expense-assistant/tree/v{args.version}'}
    (stage/'version.json').write_text(json.dumps(info,ensure_ascii=False,indent=2),encoding='utf-8')
    forbidden={'.local','差旅记录','.venv','示例数据','.git'}
    if any(p.name in forbidden for p in stage.rglob('*')):raise RuntimeError('发布目录含禁止收录的数据目录')
    if any(p.suffix.lower() in ['.sqlite','.jpg','.jpeg'] for p in stage.rglob('*')):raise RuntimeError('发布目录含疑似用户数据')
    print(json.dumps(info,ensure_ascii=False))

if __name__=='__main__':main()
