"""High risk: the debug proxy must verify TLS properly (loading this deployment's Caddy root certificate); it must never disable verification while still sending the admin key."""
import importlib.util
import os
import ssl
import sys
import tempfile
import unittest
from unittest import mock

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PATH = os.path.join(ROOT, "tools", "dev_proxy.py")


def load():
    spec = importlib.util.spec_from_file_location("dev_proxy_t", PATH)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)  # only defines functions, no network access at import time
    return mod


class DevProxyTest(unittest.TestCase):
    def test_no_unverified_context(self):
        with open(PATH, encoding="utf-8") as f:
            src = f.read()
        self.assertNotIn("_create_unverified_context", src)
        self.assertNotIn("CERT_NONE", src)

    def test_context_verifies_with_given_ca(self):
        mod = load()
        ca = os.path.join(ROOT, "tests", "fixtures", "dev_proxy_ca.pem")
        ctx = mod.make_context(ca)
        self.assertEqual(ctx.verify_mode, ssl.CERT_REQUIRED)
        self.assertTrue(ctx.check_hostname)
        self.assertEqual(len(ctx.get_ca_certs()), 1)

    def test_missing_ca_refuses(self):
        mod = load()
        with self.assertRaises(SystemExit):
            mod.make_context(os.path.join(tempfile.gettempdir(), "no-such-ca-%d.crt" % os.getpid()))
        with mock.patch.dict(os.environ, {"DEV_CA": ""}, clear=False):
            with self.assertRaises(SystemExit):
                mod.make_context(None)


if __name__ == "__main__":
    unittest.main()
