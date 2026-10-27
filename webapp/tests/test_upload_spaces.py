"""Medium severity: when the repository path contains spaces, documents uploaded from the phone must be restorable as attachment cards in the chat.
The helper writes an upload path containing whitespace as a Markdown link "[saved-name](path)", which the api's files.find_paths recognises."""
import json
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from api import transcript  # noqa: E402
from helper import outbox  # noqa: E402

NAME = "20261025-101010-abc123-报价.pdf"


class UploadSpacesTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.up = os.path.join(self.tmp.name, "Phone App", "data", "uploads")
        os.makedirs(self.up)
        open(os.path.join(self.up, NAME), "wb").close()
        open(os.path.join(self.up, "20261025-101010-abc123-a.png"), "wb").close()

    def user_files(self, text):
        line = json.dumps({"type": "user", "timestamp": "2026-10-25T01:00:00Z",
                           "message": {"role": "user", "content": text}}, ensure_ascii=False)
        items = transcript._convert(line.encode("utf-8"))
        return [f for it in items for f in it.get("files") or []]

    def test_message_with_space_path_becomes_upload_card(self):
        parts = outbox.attach_parts({"type": "message", "text": "看看", "files": [NAME]}, self.up)
        text = "".join(parts)
        full = os.path.join(os.path.realpath(self.up), NAME)
        self.assertIn(full, text)  # the Agent still sees the full path
        fl = self.user_files(text)
        self.assertEqual([(f["name"], f["src"], f["path"]) for f in fl], [(NAME, "upload", full)])

    def test_file_request_and_no_text(self):
        for req in ({"type": "file", "file": NAME, "caption": ""}, {"type": "message", "files": [NAME]}):
            text = "".join(outbox.attach_parts(req, self.up))
            self.assertEqual([f["name"] for f in self.user_files(text)], [NAME], req)

    def test_plain_path_unchanged(self):
        self.assertEqual(outbox.upload_ref("/Users/a/webapp/data/uploads/x.pdf"), "/Users/a/webapp/data/uploads/x.pdf")
        self.assertEqual(outbox.upload_ref("/Users/a/Phone App/data/uploads/x.pdf"),
                         "[x.pdf](/Users/a/Phone App/data/uploads/x.pdf)")

    def test_images_still_pasted_as_paths(self):
        parts = outbox.attach_parts({"type": "message", "text": "", "files": ["20261025-101010-abc123-a.png"]}, self.up)
        self.assertTrue(parts[0].startswith(outbox.PASTE_START + "/"))
        self.assertNotIn("](", parts[0])


if __name__ == "__main__":
    unittest.main()
