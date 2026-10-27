"""App icon badge: the server-side badge count matches the frontend tab-bar red dot (web/logic.js chatBadge), and push payloads carry badge."""
import json
import os
import shutil
import subprocess
import unittest

from api import notify as N

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

CASES = [
    [],
    [{"id": "1", "status": "waiting"}],
    [{"id": "1", "status": "waiting", "muted": True}, {"id": "2", "status": "idle", "unread": True, "muted": True}],
    [{"id": "1", "status": "idle", "unread": True, "manualUnread": True}],
    [{"id": "1", "status": "waiting", "rest": True}, {"id": "2", "status": "idle", "unread": True, "rest": True}],
    [{"id": "1", "status": "busy", "unread": True}, {"id": "2", "status": "busy"}, {"id": "3", "status": "idle"}],
    [{"id": "1", "status": "waiting", "unread": True}, {"id": "2", "status": "idle", "unread": True}, {"id": "3", "status": "err"}],
]


class BadgeCount(unittest.TestCase):
    def test_rules(self):
        self.assertEqual(N.badge_count([]), 0)
        self.assertEqual(N.badge_count(CASES[6]), 2)  # waiting+unread on the same session counts once
        self.assertEqual(N.badge_count(CASES[2]), 2)  # do-not-disturb sessions still count
        self.assertEqual(N.badge_count(CASES[3]), 1)  # manually marked unread still counts
        self.assertEqual(N.badge_count(CASES[4]), 0)  # rested sessions do not count
        self.assertEqual(N.badge_count(CASES[5]), 1)  # busy+unread counts as unread

    @unittest.skipUnless(shutil.which("node"), "node required")
    def test_matches_frontend(self):
        js = ("import('file://%s/web/logic.js').then(L=>{const c=JSON.parse(process.argv[1]);"
              "console.log(JSON.stringify(c.map(s=>L.chatBadge({sessions:s}))))})" % ROOT)
        out = subprocess.run(["node", "-e", js, json.dumps(CASES)], capture_output=True, text=True, check=True).stdout
        self.assertEqual(json.loads(out), [N.badge_count(c) for c in CASES])

    def test_with_badge_adds_to_every_action(self):
        acts = [{"kind": "show", "tag": "s-1"}, {"kind": "show", "tag": "mac-link"}]
        out = N.with_badge(acts, CASES[6])
        self.assertTrue(all(a["badge"] == 2 for a in out))
        self.assertNotIn("badge", acts[0])  # the original action is not modified

    def test_badge_reaches_payload(self):
        a = N.with_badge([{"kind": "show", "tag": "s-1", "title": "t", "body": "b"}], CASES[1])[0]
        self.assertEqual(N.localize(a, "hans")["badge"], 1)


if __name__ == "__main__":
    unittest.main()
