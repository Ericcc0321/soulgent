"""transcript.assistant_paths(): over-long lines are skipped without being materialized, scans have a byte budget, the path set is capped."""
import json
import os
import tempfile
import tracemalloc
import unittest
from unittest import mock

from api import transcript


def _asst(text):
    return json.dumps({"type": "assistant", "message": {"role": "assistant",
                                                       "content": [{"type": "text", "text": text}]}}).encode() + b"\n"


class AssistantPathsBudgetTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.path = os.path.join(self.tmp.name, "s.jsonl")
        transcript._asst_cache.clear()

    def write(self, *chunks):
        with open(self.path, "wb") as f:
            for c in chunks:
                f.write(c)

    def test_huge_line_skipped_with_bounded_memory(self):
        huge = _asst("a" * (36 * 2**20))
        self.write(_asst("see /private/tmp/g/before.png"), huge, _asst("then /private/tmp/g/after.pdf"))
        tracemalloc.start()
        try:
            got = transcript.assistant_paths(self.path)
            peak = tracemalloc.get_traced_memory()[1]
        finally:
            tracemalloc.stop()
        self.assertEqual(got, {"/private/tmp/g/before.png", "/private/tmp/g/after.pdf"})
        self.assertLess(peak, 16 * 2**20)

    def test_byte_budget_resumes_next_call(self):
        self.write(*[_asst("f /private/tmp/g/f%d.png" % i) for i in range(10)])
        one = len(_asst("f /private/tmp/g/f0.png"))
        with mock.patch.object(transcript, "_ASST_SCAN_BYTES", one * 3):
            first = transcript.assistant_paths(self.path)
            self.assertLess(len(first), 10)
            self.assertGreaterEqual(len(first), 1)
            for _ in range(10):
                last = transcript.assistant_paths(self.path)
        self.assertEqual(last, {"/private/tmp/g/f%d.png" % i for i in range(10)})

    def test_path_set_capped(self):
        self.write(*[_asst("f /private/tmp/g/f%d.png" % i) for i in range(20)])
        with mock.patch.object(transcript, "_ASST_PATHS_CAP", 5):
            got = transcript.assistant_paths(self.path)
            again = transcript.assistant_paths(self.path)
        self.assertEqual(len(got), 5)
        self.assertEqual(len(again), 5)


if __name__ == "__main__":
    unittest.main()
