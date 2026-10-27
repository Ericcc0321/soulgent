"""api/uploadlog.py: the upload log is re-read when the file changes (when another process modified uploads.json, the stale cache must not overwrite it)."""
import os
import tempfile
import unittest

from api.uploadlog import UploadLog


class ReloadTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.path = os.path.join(self.tmp.name, "uploads.json")

    def tearDown(self):
        self.tmp.cleanup()

    def test_other_instance_write_is_seen_and_kept(self):
        a, b = UploadLog(self.path), UploadLog(self.path)
        self.assertIsNone(b.get("x.pdf"))  # b first reads the (nonexistent) file into its cache
        a.add("x.pdf", "guest", "s1", size=3)
        self.assertEqual(b.get("x.pdf")["account"], "guest")  # the file changed, b re-reads it
        b.add("y.pdf", "admin", None, size=1)  # b writing to disk does not overwrite what a wrote
        c = UploadLog(self.path)
        self.assertEqual(c.owner("x.pdf"), "guest")
        self.assertEqual(c.owner("y.pdf"), "admin")


if __name__ == "__main__":
    unittest.main()
