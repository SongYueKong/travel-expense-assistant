"""使用独立随机测试条目验证 Windows 凭据持久化，结束后清除，仅使用合成授权码。"""
from pathlib import Path
import subprocess
import sys
import uuid

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'engine'))
from credential_store import MailCredentialStore


def synthetic_code(marker, updated=False):
    return f'TEST-ONLY-{marker}' + ('-updated' if updated else '')


def main():
    if len(sys.argv) > 1 and sys.argv[1] == '--read':
        marker = sys.argv[2]
        store = MailCredentialStore(namespace=f'TravelReimbursementAssistant/test/{marker}')
        assert store.get('qq', f'test-{marker}@qq.com')['authorization_code'] == synthetic_code(marker, True)
        print('PASS: new process retrieved synthetic credential')
        return
    marker = uuid.uuid4().hex
    store = MailCredentialStore(namespace=f'TravelReimbursementAssistant/test/{marker}')
    qq, netease = f'test-{marker}@qq.com', f'test-{marker}@163.com'
    try:
        assert store.get('qq', qq) == {'found': False}
        store.save('qq', qq, synthetic_code(marker))
        store.save('163', netease, 'TEST-ONLY-SECOND-ACCOUNT')
        assert store.get('qq', qq)['authorization_code'] == synthetic_code(marker)
        store.save('qq', qq, synthetic_code(marker, True))
        subprocess.run([sys.executable, str(Path(__file__).resolve()), '--read', marker], check=True)
        assert store.get('163', netease)['authorization_code'] == 'TEST-ONLY-SECOND-ACCOUNT'
        print('PASS: native Windows save, overwrite and account isolation')
    finally:
        store.delete('qq', qq)
        store.delete('163', netease)
    assert store.get('qq', qq) == {'found': False}
    assert store.get('163', netease) == {'found': False}
    print('PASS: synthetic credentials removed; no real mailbox was accessed')


if __name__ == '__main__':
    main()
