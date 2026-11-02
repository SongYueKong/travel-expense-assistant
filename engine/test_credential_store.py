import unittest
from unittest.mock import patch
from credential_store import MailCredentialStore
from worker import dispatch


class MemoryVault:
    def __init__(self):
        self.values = {}

    def read(self, target):
        return self.values.get(target)

    def write(self, target, account, secret):
        self.values[target] = secret

    def delete(self, target):
        return self.values.pop(target, None) is not None


class CredentialTests(unittest.TestCase):
    def setUp(self):
        self.vault = MemoryVault()
        self.store = MailCredentialStore(self.vault)

    def test_save_normalizes_identity_and_reply_does_not_contain_secret(self):
        secret = 'TEST-ONLY-CODE'
        result = self.store.save('qq', ' Test@QQ.COM ', secret)
        self.assertEqual(result, {'saved': True})
        self.assertNotIn(secret, str(result))
        self.assertEqual(self.store.get('qq', 'test@qq.com'),
                         {'found': True, 'authorization_code': secret})

    def test_accounts_and_providers_are_isolated(self):
        self.store.save('qq', 'one@qq.com', 'FIRST')
        self.store.save('qq', 'two@qq.com', 'SECOND')
        self.store.save('163', 'one@163.com', 'THIRD')
        self.assertEqual(self.store.get('qq', 'one@qq.com')['authorization_code'], 'FIRST')
        self.assertEqual(self.store.get('qq', 'two@qq.com')['authorization_code'], 'SECOND')
        self.assertEqual(self.store.get('163', 'one@163.com')['authorization_code'], 'THIRD')
        self.assertEqual(self.store.get('qq', 'absent@qq.com'), {'found': False})

    def test_update_and_idempotent_delete_only_affect_selected_account(self):
        self.store.save('qq', 'one@qq.com', 'OLD')
        self.store.save('qq', 'two@qq.com', 'RETAIN')
        self.store.save('qq', 'one@qq.com', 'NEW')
        self.assertEqual(self.store.get('qq', 'one@qq.com')['authorization_code'], 'NEW')
        self.assertEqual(self.store.delete('qq', 'one@qq.com'), {'deleted': True})
        self.assertEqual(self.store.delete('qq', 'one@qq.com'), {'deleted': False})
        self.assertEqual(self.store.get('qq', 'two@qq.com')['authorization_code'], 'RETAIN')

    def test_invalid_identity_cannot_read_or_write_other_targets(self):
        for provider, account in [('qq', 'test@163.com'), ('other', 'test@qq.com'), ('qq', ''), ('qq', 'invalid\x00name@qq.com')]:
            with self.subTest(provider=provider, account=account):
                for operation in [self.store.get, self.store.delete]:
                    with self.assertRaises(ValueError): operation(provider, account)
                with self.assertRaises(ValueError): self.store.save(provider, account, 'SECRET')
        self.assertEqual(self.vault.values, {})

    def test_invalid_secret_never_reaches_native_storage_or_error_text(self):
        for secret in ['DO-NOT-ECHO\x00TOKEN', 'DO-NOT-ECHO\nTOKEN', 'x' * 1281, '\ud800', '']:
            with self.subTest(length=len(secret)):
                with self.assertRaises(ValueError) as error:
                    self.store.save('qq', 'test@qq.com', secret)
                if secret: self.assertNotIn(secret, str(error.exception))
        self.assertEqual(self.vault.values, {})

    def test_worker_dispatch_uses_vault_and_save_reply_is_secret_free(self):
        identity = {'provider': 'qq', 'account': 'test@qq.com'}
        with patch('worker.credential_store', return_value=self.store):
            self.assertEqual(dispatch('mail.credential.save', {**identity, 'authorization_code': 'SYNTHETIC-CODE'}), {'saved': True})
            self.assertEqual(dispatch('mail.credential.get', identity)['authorization_code'], 'SYNTHETIC-CODE')
            self.assertEqual(dispatch('mail.credential.delete', identity), {'deleted': True})
            self.assertEqual(dispatch('mail.credential.get', identity), {'found': False})


if __name__ == '__main__':
    unittest.main()
