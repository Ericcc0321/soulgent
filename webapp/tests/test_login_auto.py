"""Login page auto-submit (#k= link) must not replace an already logged-in different identity."""
import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from tests import test_file_api as tfa  # noqa: E402
from tests import test_sec_medium as tsm  # noqa: E402

ADMIN_COOKIE, GUEST, GUEST_COOKIE = tfa.ADMIN_COOKIE, tfa.GUEST, tfa.GUEST_COOKIE


class LoginAutoTest(unittest.TestCase):
    setUp = tfa.FileApiTest.setUp
    _write = staticmethod(tfa.FileApiTest._write)
    call = tsm.MediumApiTest.call  # borrow only the request helper

    def test_auto_login_refuses_to_replace_other_identity(self):
        st, h, _ = self.call("POST", "/api/auth", ADMIN_COOKIE, {"key": GUEST, "auto": True})
        self.assertEqual(st, 409)
        self.assertNotIn("set-cookie", h)

    def test_manual_login_still_switches(self):
        st, h, _ = self.call("POST", "/api/auth", ADMIN_COOKIE, {"key": GUEST})
        self.assertEqual(st, 200)
        self.assertIn("set-cookie", h)

    def test_auto_login_without_cookie_or_same_identity_works(self):
        st, h, _ = self.call("POST", "/api/auth", None, {"key": GUEST, "auto": True})
        self.assertEqual(st, 200)
        self.assertIn("set-cookie", h)
        st, _, _ = self.call("POST", "/api/auth", GUEST_COOKIE, {"key": GUEST, "auto": True})
        self.assertEqual(st, 200)


if __name__ == "__main__":
    unittest.main()
