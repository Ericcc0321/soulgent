"""Claude Code transcript format adapter: version-tagged fixtures must read cleanly, structural breaks must raise formatWarn."""
import os
import unittest

from api import cc_format, transcript

FIX = os.path.join(os.path.dirname(os.path.abspath(__file__)), "fixtures")
CC = os.path.join(FIX, "cc")
BROKEN = os.path.join(FIX, "cc-broken")


def fixture_files(root):
    for ver in sorted(os.listdir(root)):
        d = os.path.join(root, ver)
        for name in sorted(os.listdir(d)):
            if name.endswith(".jsonl"):
                yield ver, name, os.path.join(d, name)


class FixtureTest(unittest.TestCase):
    def test_fixture_dirs_exist(self):
        self.assertTrue(list(fixture_files(CC)))

    def test_known_versions_read_without_warning(self):
        for ver, name, path in fixture_files(CC):
            with self.subTest(version=ver, file=name):
                page = transcript.read_page(path, None, side=name.startswith("subagent"))
                self.assertNotIn("formatWarn", page)
                self.assertTrue(page["items"])

    def test_main_session_shapes(self):
        for ver, name, path in fixture_files(CC):
            if name != "session.jsonl":
                continue
            with self.subTest(version=ver):
                items = transcript.read_page(path, None, closed=True)["items"]
                roles = [it["role"] for it in items]
                self.assertEqual(roles, ["user", "assistant", "tool", "tool", "notice", "user", "assistant"])
                self.assertEqual(items[4]["code"], "apiError")
                self.assertNotIn("Read the notes for dave.", [it.get("text") for it in items])  # sidechain hidden

    def test_broken_sample_warns_with_version(self):
        for ver, name, path in fixture_files(BROKEN):
            with self.subTest(version=ver, file=name):
                warn = transcript.read_page(path, None).get("formatWarn")
                self.assertIsInstance(warn, str)
                self.assertIn("2 line(s)", warn)
                self.assertIn("Claude Code %s" % ver, warn)
                self.assertLessEqual(len(warn), cc_format.MAX_WARN)


class CheckLineTest(unittest.TestCase):
    def test_metadata_lines_never_count(self):
        for obj in ({"type": "brand-new-metadata", "x": 1}, {"type": "attachment"}, [], "x", None):
            self.assertIsNone(cc_format.check_line(obj))

    def test_new_version_alone_is_fine(self):
        obj = {"type": "user", "version": "9.9.9", "message": {"role": "user", "content": "hi"}}
        self.assertIsNone(cc_format.check_line(obj))

    def test_structural_failures(self):
        cases = [
            {"type": "human", "message": {"content": "hi"}},
            {"type": "user", "message": "hi"},
            {"type": "user", "message": {"role": "user"}},
            {"type": "assistant", "message": {"content": "plain"}},
            {"type": "user", "message": {"content": 5}},
            {"type": "assistant", "message": {"content": [{"text": "no type"}]}},
        ]
        for obj in cases:
            with self.subTest(obj=obj):
                self.assertIsInstance(cc_format.check_line(obj), str)

    def test_format_warn_text(self):
        self.assertIsNone(cc_format.format_warn([]))
        self.assertEqual(cc_format.format_warn([("x", "")]), "1 line(s) not understood, e.g. x")

    def test_convert_without_bad_list_unchanged(self):
        self.assertEqual(transcript._convert(b'{"type":"human","message":{"content":"hi"}}'), [])

    def test_cc_format_does_not_import_transcript(self):
        with open(cc_format.__file__, encoding="utf-8") as f:
            src = f.read()
        self.assertNotIn("import transcript", src)
        self.assertNotIn("from api import transcript", src)


if __name__ == "__main__":
    unittest.main()
