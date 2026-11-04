"""只读读取 ZIP 中的 PDF；不使用归档路径写文件，不执行附件或递归解压。"""
from io import BytesIO
from pathlib import PurePosixPath
import stat
import zipfile

MAX_ZIP_ENTRIES = 200
MAX_ZIP_EXPANDED_BYTES = 50 * 1024 * 1024


def member_name(info):
    name = info.filename
    # 未设置 UTF-8 标志的国内 ZIP 常采用 GBK；仅修复用于显示的名字。
    if not info.flag_bits & 0x800:
        try:
            name = name.encode('cp437').decode('gb18030')
        except (UnicodeError, LookupError):
            pass
    return name


def read_zip_pdfs(data, max_pdf_bytes):
    files, issues = [], []
    if len(data) > max_pdf_bytes:
        return [], [{'reason': 'ZIP 附件超过 25 MB，请手动解压后补充 PDF'}]
    try:
        with zipfile.ZipFile(BytesIO(data)) as archive:
            members = archive.infolist()
            if len(members) > MAX_ZIP_ENTRIES:
                return [], [{'reason': 'ZIP 内文件数量超过 200 个，请手动筛选 PDF 后补充'}]
            if sum(item.file_size for item in members) > MAX_ZIP_EXPANDED_BYTES:
                return [], [{'reason': 'ZIP 解压后总大小超过 50 MB，请手动筛选 PDF 后补充'}]
            for index, info in enumerate(members):
                if info.is_dir():
                    continue
                name = member_name(info)
                filename = PurePosixPath(name.replace('\\', '/')).name
                source = {'archiveMember': name, 'archiveMemberIndex': index}
                if filename.lower().endswith(('.zip', '.rar', '.7z')):
                    issues.append({'reason': 'ZIP 中含嵌套压缩包，请手动解压其中的 PDF 后补充', **source})
                    continue
                if not filename.lower().endswith('.pdf'):
                    continue
                if stat.S_ISLNK(info.external_attr >> 16):
                    issues.append({'reason': 'ZIP 中的 PDF 条目是链接，需提供实际 PDF 文件', **source})
                    continue
                if info.flag_bits & 1:
                    issues.append({'reason': 'ZIP 中的 PDF 已加密，请手动输入解压密码后补充 PDF', **source})
                    continue
                if info.file_size > max_pdf_bytes:
                    issues.append({'reason': 'ZIP 中的单个 PDF 超过 25 MB，请手动补充', **source})
                    continue
                try:
                    with archive.open(info) as stream:
                        content = stream.read(max_pdf_bytes + 1)
                    if len(content) > max_pdf_bytes:
                        issues.append({'reason': 'ZIP 中的单个 PDF 超过 25 MB，请手动补充', **source})
                    elif b'%PDF-' not in content[:1024]:
                        issues.append({'reason': 'ZIP 中标为 PDF 的文件内容无法识别，请核验原附件', **source})
                    else:
                        files.append({'data': content, 'filename': filename, **source})
                except Exception:
                    # 不回显底层异常，避免邮件或文件内容进入错误提示。
                    issues.append({'reason': 'ZIP 中的 PDF 读取失败，可能损坏或压缩方式暂不支持，请手动补充', **source})
    except Exception:
        issues.append({'reason': 'ZIP 附件无法读取，可能已损坏或压缩格式暂不支持，请手动解压后补充 PDF'})
    if not files and not issues:
        issues.append({'code': 'archive_no_pdf', 'reason': 'ZIP 内未找到 PDF，需从原邮件取得 PDF 后补充（OFD、XML 和图片不作为 PDF 导入）'})
    return files, issues
