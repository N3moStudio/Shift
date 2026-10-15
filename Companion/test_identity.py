import json
import os
from pathlib import Path
import tempfile
import unittest
from companion import certificate
from identity import load_or_create, protect, unprotect


class IdentityTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.path = self.root / 'identity.dat'
        self.session = self.root / 'session'
        self.session.mkdir()

    def load(self, host='192.168.1.5', **kwargs):
        # Test persistence separately from Windows encryption, which is tested below.
        return load_or_create(self.path, host, self.session, certificate,
                              encode=lambda value: b'test:' + value,
                              decode=lambda value: value.removeprefix(b'test:'), **kwargs)

    def test_restart_preserves_token_and_certificate(self):
        first = self.load()
        certificate_bytes = first[1].read_bytes()
        second = self.load()
        self.assertFalse(first[4])
        self.assertTrue(second[4])
        self.assertEqual(first[0], second[0])
        self.assertEqual(first[3], second[3])
        self.assertEqual(certificate_bytes, second[1].read_bytes())

    def test_address_change_and_explicit_reset_rotate_both_secrets(self):
        previous = self.load()
        for current in (self.load('192.168.2.5'), self.load('192.168.2.5', reset=True)):
            self.assertFalse(current[4])
            self.assertNotEqual(previous[0], current[0])
            self.assertNotEqual(previous[3], current[3])
            previous = current

    def test_corruption_fails_closed_and_preserves_file(self):
        self.path.write_bytes(b'broken')
        with self.assertRaises(ValueError): self.load()
        self.assertEqual(self.path.read_bytes(), b'broken')

    def test_changed_port_requires_new_import(self):
        before = self.load()
        after = self.load(port=8766)
        self.assertFalse(after[4])
        self.assertNotEqual(before[0], after[0])

    def test_mismatched_certificate_key_is_rejected(self):
        self.load()
        record = json.loads(self.path.read_bytes().removeprefix(b'test:'))
        _, key, _ = certificate(self.session, '192.168.1.5')
        record['key'] = key.read_text()
        self.path.write_bytes(b'test:' + json.dumps(record).encode())
        with self.assertRaisesRegex(ValueError, 'does not match'): self.load()

    @unittest.skipUnless(os.name == 'nt', 'Windows account protection')
    def test_windows_account_encryption_round_trip(self):
        secret = b'test-only helper identity, never a real key'
        encrypted = protect(secret)
        self.assertNotIn(secret, encrypted)
        self.assertEqual(unprotect(encrypted), secret)


if __name__ == '__main__': unittest.main()
