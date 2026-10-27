import os
import tempfile
import unittest

from api import files


class RootsTest(unittest.TestCase):
    def setUp(self):  # temp dir simulates host root and container root pointing at the same place
        self.tmp = tempfile.TemporaryDirectory()
        root = self.tmp.name
        os.makedirs(root + "/host/tmp/soulgent")
        self._w(root + "/host/tmp/soulgent/a.png", b"x")
        os.makedirs(root + "/secret")
        self._w(root + "/secret/.env", b"k")
        os.symlink(root + "/secret/.env", root + "/host/tmp/soulgent/link.png")
        self.roots = files.Roots.from_spec("/private/tmp=%s/host/tmp:%s/cp=%s/host/cp" % (root, root, root))

    @staticmethod
    def _w(path, data):
        with open(path, "wb") as f:
            f.write(data)

    def tearDown(self):
        self.tmp.cleanup()

    def test_tmp_alias(self):
        self.assertEqual(self.roots.to_container("/tmp/soulgent/a.png"), self.tmp.name + "/host/tmp/soulgent/a.png")

    def test_escape_all_404(self):
        for p in ("/private/tmp/../secret/.env", "/private/tmpx/a.png", "/private/tmp/soulgent/link.png", "/Users/demo/.env", "relative/a.png", ""):
            self.assertIsNone(self.roots.resolve(p), p)

    def test_resolve_ok(self):
        self.assertTrue(self.roots.resolve("/tmp/soulgent/a.png").endswith("/host/tmp/soulgent/a.png"))

    def test_empty_spec_no_roots(self):
        r = files.Roots.from_spec("")
        self.assertIsNone(r.to_container("/tmp/soulgent/a.png"))
        self.assertIsNone(r.resolve("/tmp/soulgent/a.png"))

    def test_leading_empty_item_skipped(self):
        # compose writes "${FILE_ROOTS:-}:<uploads>"; when .env does not set FILE_ROOTS the first entry is empty and only the uploads root remains
        r = files.Roots.from_spec(":/data/x/uploads=/uploads")
        self.assertEqual(r.pairs, [("/data/x/uploads", "/uploads")])

    def test_tilde_expands(self):
        r = files.Roots.from_spec("/Users/demo=%s/host/tmp" % self.tmp.name, home="/Users/demo")
        self.assertEqual(r.to_container("~/x/a.png"), self.tmp.name + "/host/tmp/x/a.png")
        self.assertEqual(r.to_container("~"), self.tmp.name + "/host/tmp")

    def test_tilde_uses_host_home_not_process_home(self):
        # explicit home differs from the process HOME
        root = self.tmp.name
        os.makedirs(root + "/host/home/Desktop")
        self._w(root + "/host/home/Desktop/x.pdf", b"x")
        r = files.Roots.from_spec("/Users/zz=%s/host/home" % root, home="/Users/zz")
        self.assertNotEqual(os.path.expanduser("~"), "/Users/zz")  # process HOME differs from the explicit home
        self.assertTrue(r.resolve("~/Desktop/x.pdf").endswith("/host/home/Desktop/x.pdf"))

    def test_tilde_env_and_other_user(self):
        r = files.Roots.from_spec("/Users/demo=%s/host/tmp" % self.tmp.name, home="/Users/demo")
        self.assertIsNone(r.to_container("~root/x.png"))
        self.assertIsNone(r.to_container("~demo/x.png"))

    def test_symlink_inside_root_to_env_blocked(self):
        root = self.tmp.name
        self._w(root + "/host/tmp/soulgent/.env", b"k")
        os.symlink(root + "/host/tmp/soulgent/.env", root + "/host/tmp/soulgent/in.png")
        self.assertIsNone(self.roots.resolve("/tmp/soulgent/in.png"))

    def test_non_str_no_raise(self):
        self.assertIsNone(self.roots.resolve(None))
        self.assertIsNone(self.roots.to_container(None))


class ClassifyTest(unittest.TestCase):
    def test_kinds(self):
        self.assertEqual(files.classify("A.PNG"), "image")
        self.assertEqual(files.classify("r.docx"), "doc")
        self.assertIsNone(files.classify("x.py"))
        self.assertIsNone(files.classify("x.json"))
        self.assertEqual(files.classify("x.json", in_link=True), "data")
        self.assertEqual(files.classify("t.csv"), "data")  # per the design: csv is classified as data (in-app reader page, truncated at 2MB)
        self.assertEqual(files.classify("t.xlsx"), "sheet")

    def test_content_type(self):
        self.assertEqual(files.content_type("a.PNG"), "image/png")
        self.assertEqual(files.content_type("a.pdf"), "application/pdf")
        self.assertEqual(files.content_type("a.unknown"), "application/octet-stream")


class FindPathsTest(unittest.TestCase):
    def test_text_and_md(self):
        t = "看 /tmp/soulgent/faces3.png 和 ![脸](/Users/demo/projects/a/b.webp)，报错在 /Users/demo/x/app.py:12，日志 /tmp/a.log"
        self.assertEqual(files.find_paths(t), [("/tmp/soulgent/faces3.png", "text"), ("/Users/demo/projects/a/b.webp", "md")])

    def test_dedupe_and_tilde(self):
        self.assertEqual(files.find_paths("~/Desktop/x.pdf 再看 ~/Desktop/x.pdf"), [("~/Desktop/x.pdf", "text")])

    def test_cjk_adjacent(self):
        self.assertEqual(files.find_paths("看/tmp/x.png的内容"), [("/tmp/x.png", "text")])
        r = files.find_paths("在/Users/demo/projects/a/报告.docx里")
        self.assertEqual(r, [("/Users/demo/projects/a/报告.docx", "text")])
        self.assertEqual(files.find_paths("看~/Desktop/x.pdf吧"), [("~/Desktop/x.pdf", "text")])
        self.assertEqual(files.find_paths("/Users/demo/x/app.py:12 /tmp/a.log"), [])

    def test_json_only_in_link(self):
        self.assertEqual(files.find_paths("见 /tmp/a.json"), [])
        self.assertEqual(files.find_paths("[数据](/tmp/a.json)"), [("/tmp/a.json", "md")])

    def test_empty(self):
        self.assertEqual(files.find_paths(""), [])
        self.assertEqual(files.find_paths(None), [])


class OpenTargetsTest(unittest.TestCase):
    def test_forms(self):
        self.assertEqual(files.open_targets('open "/tmp/soulgent/faces3.png"'), ["/tmp/soulgent/faces3.png"])
        self.assertEqual(files.open_targets("open -a Preview /tmp/a.png /tmp/b.pdf"), ["/tmp/a.png", "/tmp/b.pdf"])
        self.assertEqual(files.open_targets("ls /tmp && open http://x"), [])
        self.assertEqual(files.open_targets('cd /x && open "/tmp/报告 v2.docx"'), ["/tmp/报告 v2.docx"])

    def test_all_segments(self):
        self.assertEqual(files.open_targets("open /tmp/a.png && echo ok"), ["/tmp/a.png"])
        self.assertEqual(files.open_targets("open /tmp/x.png; sleep 1"), ["/tmp/x.png"])
        self.assertEqual(files.open_targets("open /tmp/a.png /tmp/a.png\nopen /tmp/b.pdf"), ["/tmp/a.png", "/tmp/b.pdf"])
        self.assertEqual(files.open_targets("echo 1 | open /tmp/c.png || open /tmp/d.png"), ["/tmp/c.png", "/tmp/d.png"])

    def test_background_and_redirect(self):
        self.assertEqual(files.open_targets("open /tmp/a.png &"), ["/tmp/a.png"])
        self.assertEqual(files.open_targets("open /tmp/a.png > /tmp/out.png"), ["/tmp/a.png"])
        self.assertEqual(files.open_targets("open /tmp/a.png 2> /tmp/err.png"), ["/tmp/a.png"])
        self.assertEqual(files.open_targets("open /tmp/a.png >/tmp/o.png 2>&1"), ["/tmp/a.png"])

    def test_robust(self):
        self.assertEqual(files.open_targets('open "unterminated'), [])
        self.assertEqual(files.open_targets(""), [])
        self.assertEqual(files.open_targets("echo hi"), [])


class TokenTest(unittest.TestCase):
    def test_roundtrip_and_expiry(self):
        s = files.file_secret("k")
        tok = files.sign("/uploads/a.pdf", 1000, s)
        self.assertEqual(files.verify(tok, s, 999), "/uploads/a.pdf")
        self.assertIsNone(files.verify(tok, s, 1001))
        self.assertIsNone(files.verify(tok + "x", s, 1))

    def test_bad_tokens(self):
        s = files.file_secret("k")
        for t in ("", "a.b", "a.b.c", "!!.1.zz", None):
            self.assertIsNone(files.verify(t, s, 1), t)
        self.assertIsNone(files.verify(files.sign("/a.pdf", 1000, s), files.file_secret("other"), 1))

    def test_limits(self):
        self.assertEqual((files.IMG_MAX, files.DOC_MAX, files.THUMB_SKIP), (30 * 2**20, 80 * 2**20, 12 * 2**20))


if __name__ == "__main__":
    unittest.main()
