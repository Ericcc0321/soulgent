"""The helper copies the window-switch lineage file that SOULGENT_LINEAGE points to into data/lineage.jsonl (the api only mounts data/)."""
import os
import tempfile
import unittest
from unittest import mock

from helper import orca_stats


class LineageSyncTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.src = os.path.join(self.tmp.name, "window-lineage.jsonl")
        self.dst = os.path.join(self.tmp.name, "data", "lineage.jsonl")

    def test_copies_when_changed_and_removes_when_gone(self):
        cache = {}
        with open(self.src, "w") as f:
            f.write('{"a":1}\n')
        meta = orca_stats.sync_lineage(self.src, self.dst, cache)
        self.assertEqual(open(self.dst).read(), '{"a":1}\n')
        self.assertEqual(meta["size"], 8)
        with open(self.src, "a") as f:
            f.write('{"b":2}\n')
        orca_stats.sync_lineage(self.src, self.dst, cache)
        self.assertEqual(open(self.dst).read(), '{"a":1}\n{"b":2}\n')
        os.unlink(self.src)
        self.assertIsNone(orca_stats.sync_lineage(self.src, self.dst, cache))
        self.assertFalse(os.path.exists(self.dst))

    def test_big_file_keeps_tail_whole_lines(self):
        with open(self.src, "w") as f:
            for i in range(100):
                f.write('{"n":%03d}\n' % i)
        with mock.patch.object(orca_stats, "LINEAGE_MAX", 100):
            meta = orca_stats.sync_lineage(self.src, self.dst, {})
        text = open(self.dst).read()
        self.assertTrue(meta["truncated"])
        self.assertTrue(text.endswith('{"n":099}\n'))
        self.assertTrue(text.startswith('{"n":'))
        self.assertLessEqual(len(text), 100)


if __name__ == "__main__":
    unittest.main()
