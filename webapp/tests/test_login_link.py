"""tools/login-link.py: prints https://<host>:8443/#k=<key> for an account, reading keys from .env like the server does."""
import os
import subprocess
import sys
import tempfile
import unittest
from urllib.parse import quote

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TOOL = os.path.join(ROOT, "tools", "login-link.py")
ADMIN = "admin-key-0123456789abcdef"
GUEST = "guest+key/0123456789&abcdef"
G2 = "second-guest-key-0123456789"


class LoginLinkTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.env = os.path.join(self.tmp.name, ".env")
        with open(self.env, "w", encoding="utf-8") as f:
            f.write("# comment\nWEBAPP_KEY=%s\nSITE_IP=192.168.1.10\nGUEST_KEY=\"%s\"\nGUEST_SESSION=Web-x\n"
                    "GUEST2_ID=bob\nGUEST2_KEY=%s\n" % (ADMIN, GUEST, G2))

    def run_tool(self, *args):
        return subprocess.run([sys.executable, "-I", TOOL, "--env", self.env, "--no-qr"] + list(args),
                              capture_output=True, text=True, timeout=30)

    def test_admin_default_uses_site_ip(self):
        r = self.run_tool()
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(r.stdout, "https://192.168.1.10:8443/#k=%s\n" % ADMIN)

    def test_guest_key_is_encoded_into_the_fragment(self):
        r = self.run_tool("guest", "--host", "soulgent.example")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(r.stdout.strip(), "https://soulgent.example:8443/#k=%s" % quote(GUEST, safe=""))
        self.assertNotIn("?", r.stdout)
        r = self.run_tool("bob")
        self.assertEqual(r.stdout.strip(), "https://192.168.1.10:8443/#k=%s" % G2)

    def test_unknown_account_lists_names_without_keys(self):
        r = self.run_tool("nobody")
        self.assertEqual(r.returncode, 2)
        self.assertEqual(r.stdout, "")
        self.assertIn("admin, guest, bob", r.stderr)
        for k in (ADMIN, GUEST, G2):
            self.assertNotIn(k, r.stderr)

    def test_missing_admin_key_fails(self):
        with open(self.env, "w", encoding="utf-8") as f:
            f.write("WEBAPP_KEY=short\nSITE_IP=1.2.3.4\n")
        r = self.run_tool()
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual(r.stdout, "")

    def test_writes_nothing(self):
        before = sorted(os.listdir(self.tmp.name))
        self.run_tool("guest")
        self.assertEqual(sorted(os.listdir(self.tmp.name)), before)


if __name__ == "__main__":
    unittest.main()
