"""仅通过 Windows 当前用户的凭据管理器保存邮箱授权码，不写入项目文件。"""
import ctypes
from ctypes import wintypes
import sys
from mail_service import credentials


class CredentialStoreError(RuntimeError):
    pass


class _Credential(ctypes.Structure):
    _fields_ = [
        ('Flags', wintypes.DWORD), ('Type', wintypes.DWORD),
        ('TargetName', wintypes.LPWSTR), ('Comment', wintypes.LPWSTR),
        ('LastWritten', wintypes.FILETIME), ('CredentialBlobSize', wintypes.DWORD),
        ('CredentialBlob', ctypes.POINTER(ctypes.c_ubyte)), ('Persist', wintypes.DWORD),
        ('AttributeCount', wintypes.DWORD), ('Attributes', ctypes.c_void_p),
        ('TargetAlias', wintypes.LPWSTR), ('UserName', wintypes.LPWSTR),
    ]


class WindowsCredentialVault:
    def __init__(self):
        if sys.platform != 'win32':
            raise CredentialStoreError('当前系统不支持 Windows 本地凭据管理器')
        self.api = ctypes.WinDLL('Advapi32.dll', use_last_error=True)
        self.api.CredWriteW.argtypes = [ctypes.POINTER(_Credential), wintypes.DWORD]
        self.api.CredWriteW.restype = wintypes.BOOL
        self.api.CredReadW.argtypes = [wintypes.LPCWSTR, wintypes.DWORD, wintypes.DWORD,
                                      ctypes.POINTER(ctypes.POINTER(_Credential))]
        self.api.CredReadW.restype = wintypes.BOOL
        self.api.CredDeleteW.argtypes = [wintypes.LPCWSTR, wintypes.DWORD, wintypes.DWORD]
        self.api.CredDeleteW.restype = wintypes.BOOL
        self.api.CredFree.argtypes = [ctypes.c_void_p]
        self.api.CredFree.restype = None

    def _error(self, operation):
        # 错误仅包含操作和系统错误码，不拼接账号、请求或授权码。
        return CredentialStoreError(f'Windows 凭据{operation}失败（错误码 {ctypes.get_last_error()}）')

    def write(self, target, account, secret):
        data = secret.encode('utf-16-le')
        blob = (ctypes.c_ubyte * len(data)).from_buffer_copy(data)
        credential = _Credential()
        credential.Type = 1  # CRED_TYPE_GENERIC
        credential.TargetName = target
        credential.Comment = '差旅报账助手邮箱授权码'
        credential.UserName = account
        credential.CredentialBlobSize = len(data)
        credential.CredentialBlob = ctypes.cast(blob, ctypes.POINTER(ctypes.c_ubyte))
        credential.Persist = 2  # CRED_PERSIST_LOCAL_MACHINE：当前用户在本机跨登录保留。
        try:
            if not self.api.CredWriteW(ctypes.byref(credential), 0):
                raise self._error('保存')
        finally:
            ctypes.memset(ctypes.addressof(blob), 0, len(data))

    def read(self, target):
        pointer = ctypes.POINTER(_Credential)()
        if not self.api.CredReadW(target, 1, 0, ctypes.byref(pointer)):
            if ctypes.get_last_error() == 1168:  # ERROR_NOT_FOUND
                return None
            raise self._error('读取')
        try:
            value = pointer.contents
            try:
                return ctypes.string_at(value.CredentialBlob, value.CredentialBlobSize).decode('utf-16-le')
            except UnicodeError:
                raise CredentialStoreError('本地授权码格式异常，请删除后重新保存') from None
        finally:
            if pointer.contents.CredentialBlobSize:
                ctypes.memset(pointer.contents.CredentialBlob, 0, pointer.contents.CredentialBlobSize)
            self.api.CredFree(pointer)

    def delete(self, target):
        if self.api.CredDeleteW(target, 1, 0):
            return True
        if ctypes.get_last_error() == 1168:
            return False
        raise self._error('删除')


class MailCredentialStore:
    def __init__(self, vault=None, namespace='TravelReimbursementAssistant/imap'):
        self.vault = vault if vault is not None else WindowsCredentialVault()
        self.namespace = namespace

    def _identity(self, provider, account):
        if not isinstance(account, str):
            raise ValueError('请填写完整邮箱地址')
        if any(ord(c) < 33 or ord(c) > 126 for c in account.strip()):
            raise ValueError('邮箱地址包含无效字符')
        account = credentials(provider, account, 'credential-lookup')
        return account, f'{self.namespace}/{provider}/{account}'

    def get(self, provider, account):
        _, target = self._identity(provider, account)
        secret = self.vault.read(target)
        return {'found': False} if secret is None else {'found': True, 'authorization_code': secret}

    def save(self, provider, account, authorization_code):
        account, target = self._identity(provider, account)
        if not isinstance(authorization_code, str):
            raise ValueError('请填写邮箱客户端授权码')
        secret = authorization_code.strip()
        credentials(provider, account, secret)
        try:
            size = len(secret.encode('utf-16-le'))
        except UnicodeError:
            raise ValueError('授权码包含无效字符') from None
        if size > 2560:
            raise ValueError('授权码长度超过本地凭据存储限制')
        self.vault.write(target, account, secret)
        return {'saved': True}

    def delete(self, provider, account):
        _, target = self._identity(provider, account)
        return {'deleted': self.vault.delete(target)}


_store = None


def credential_store():
    global _store
    if _store is None:
        _store = MailCredentialStore()
    return _store
