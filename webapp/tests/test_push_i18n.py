"""Push text is generated in the subscription language. On subscribing, the frontend sends its UI language (en / hans / hant), which is stored with the subscription; notify.localize uses it to build the title and fallback body;
old subscriptions without a language use Simplified Chinese (character for character as before). The Python template table matches the same-named keys in web/i18n.js verbatim."""
import json
import os
import re
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from api import notify as N, push  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def i18n_rows():
    """The "key": [en, hans, hant] lines of STR in web/i18n.js (one per line, JSON array)."""
    src = open(os.path.join(ROOT, "web", "i18n.js"), encoding="utf-8").read()
    out = {}
    for m in re.finditer(r'^  "([^"]+)": (\[.*\]),', src, re.M):
        try:
            out[m.group(1)] = json.loads(m.group(2))
        except ValueError:
            pass
    return out


def SUB(n, **kw):
    d = {"endpoint": "https://fcm.googleapis.com/%s" % n, "keys": {"p256dh": "P" + n, "auth": "A" + n}}
    d.update(kw)
    return d


class TableTest(unittest.TestCase):
    def test_b3_push_words(self):
        """Quota exhausted and unexpected exit (wording convention: a session-level disconnect is called "exited unexpectedly", not "disconnected")."""
        self.assertEqual(N.PUSH_TEXT["pushmsg.limit"], ("Limit reached", "额度用完", "額度用完"))
        self.assertEqual(N.PUSH_TEXT["pushmsg.lost"], ("Exited unexpectedly", "意外退出", "意外結束"))
        for ev in ("err", "limit", "lost", "stopped"):
            self.assertIn(ev, N.SESSION_EVS)

    def test_python_table_matches_i18n_js(self):
        rows = i18n_rows()
        for key, cols in N.PUSH_TEXT.items():
            self.assertIn(key, rows, key)
            self.assertEqual(list(cols), rows[key], key)

    def test_fallback_constants_are_hans_column(self):
        self.assertEqual(N.ptext("pushmsg.fbWait", "hans"), N.FALLBACK_WAIT)
        self.assertEqual(N.ptext("pushmsg.fbDone", "hans"), N.FALLBACK_DONE)


class LocalizeTest(unittest.TestCase):
    def act(self, ev="wait", fb=False, body="摘要原文"):
        return {"kind": "show", "tag": "s-a", "title": "Web-QS", "body": body, "text": body, "url": "/#s/a",
                "ev": ev, "name": "Web-QS", "fb": fb}

    def test_titles_per_lang(self):
        # the title is the session name (same in every language); the body is the message itself, no "[waiting]" label
        self.assertEqual(N.localize(self.act(), "en")["title"], "Web-QS")
        self.assertEqual(N.localize(dict(self.act(), emoji="🐳"), "en")["title"], "🐳 Web-QS")
        self.assertEqual(N.localize(self.act(), "en")["body"], "摘要原文")
        self.assertEqual(N.localize(self.act(), "hant")["body"], "摘要原文")
        self.assertEqual(N.localize(self.act("done"), "hant")["body"], "摘要原文")
        for old in (None, "", "fr", 3):
            self.assertEqual(N.localize(self.act(), old)["body"], "摘要原文", repr(old))

    def test_summary_body_not_translated_fallback_is(self):
        self.assertEqual(N.localize(self.act("done"), "en")["body"], "摘要原文")
        self.assertEqual(N.localize(self.act(fb=True, body=N.FALLBACK_WAIT), "en")["body"], "Waiting for your decision")
        self.assertEqual(N.localize(self.act("done", True, N.FALLBACK_DONE), "hant")["body"], "完成了")

    def test_internal_fields_stripped_recall_passthrough(self):
        out = N.localize(self.act(), "en")
        self.assertEqual(set(out), {"kind", "tag", "title", "body", "url"})
        self.assertEqual(N.localize(push.TEST_RECALL, "en"), push.TEST_RECALL)

    def test_test_push_per_lang(self):
        self.assertEqual(N.localize(push.TEST_SHOW, "en"),
                         {"kind": "show", "tag": "zbs-test", "title": "Soulgent test", "body": "This is a test notification", "url": "/"})
        self.assertEqual(N.localize(push.TEST_SHOW, "hant")["body"], "這是一則測試通知")
        self.assertEqual(N.localize(push.TEST_SHOW, None)["title"], "Soulgent 测试")

    def test_step_marks_fallback(self):
        st, _ = N.step(N.new_state(), [], 0, lambda s, k: "")
        sess = {"id": "a", "name": "QS", "status": "waiting", "since": 1}
        st, _ = N.step(st, [sess], 10, lambda s, k: N.FALLBACK_WAIT)
        _, acts = N.step(st, [sess], 14, lambda s, k: N.FALLBACK_WAIT)
        self.assertTrue(acts[0]["fb"])
        self.assertEqual(N.localize(acts[0], "en"), {"kind": "show", "tag": "s-a", "title": "🔥 QS",
                                                     "body": "Waiting for your decision", "url": "/#s/a",
                                                     "timestamp": 1000})

    def _done_act(self, body_fn):
        st, _ = N.step(N.new_state(), [], 0, lambda s, k: "")
        sess = {"id": "a", "name": "QS", "status": "idle", "since": 1, "unread": True}
        st, _ = N.step(st, [sess], 10, body_fn)
        _, acts = N.step(st, [sess], 30, body_fn)
        self.assertEqual(len(acts), 1)
        return acts[0]

    def test_fallback_by_type_not_text(self):
        """If the Agent really replied "干完了", that is the body, not the fallback: all three languages push that sentence as-is; only a real fallback is localized."""
        real = self._done_act(lambda s, k: "干完了")
        self.assertFalse(real["fb"])
        for lang in ("en", "hans", "hant"):
            self.assertEqual(N.localize(real, lang)["body"], "干完了", lang)
        fb = self._done_act(lambda s, k: N.done_body([]))
        self.assertTrue(fb["fb"])
        self.assertEqual({lang: N.localize(fb, lang)["body"] for lang in ("en", "hans", "hant")},
                         {"en": "Done", "hans": "干完了", "hant": "完成了"})
        self.assertEqual({lang: N.localize(fb, lang)["title"] for lang in ("en", "hans", "hant")},
                         {"en": "🔥 QS", "hans": "🔥 QS", "hant": "🔥 QS"})
        boom = self._done_act(lambda s, k: 1 / 0)  # a failing body_fn also counts as the fallback
        self.assertTrue(boom["fb"])
        self.assertEqual(N.localize(boom, "en")["body"], "Done")


class StoreTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.sent = []
        self.p = push.Push(os.path.join(self.tmp.name, "push.json"),
                           sender=lambda s, payload, k, sub: self.sent.append((s["endpoint"], payload)) or 201)

    def test_subscribe_stores_lang_and_send_follows_it(self):
        self.assertTrue(self.p.subscribe(SUB("1"), "admin", "en"))
        self.assertTrue(self.p.subscribe(SUB("2"), "admin", "hant"))
        self.assertTrue(self.p.subscribe(SUB("3"), "admin"))           # no language given
        self.assertTrue(self.p.subscribe(SUB("4"), "admin", "klingon"))  # unknown language
        langs = {s["endpoint"][-1]: s.get("lang") for s in self.p.subscriptions()}
        self.assertEqual(langs, {"1": "en", "2": "hant", "3": None, "4": None})
        self.p.send_test("admin")
        got = {ep[-1]: pl["title"] for ep, pl in self.sent}
        self.assertEqual(got, {"1": "Soulgent test", "2": "Soulgent 測試", "3": "Soulgent 测试", "4": "Soulgent 测试"})

    def test_resubscribe_updates_lang(self):
        self.p.subscribe(SUB("1"), "admin", "en")
        self.p.subscribe(SUB("1"), "admin", "hans")
        self.assertEqual([s.get("lang") for s in self.p.subscriptions()], ["hans"])

    def test_old_subscription_without_lang_is_hans(self):
        with open(self.p.path, "w") as f:
            json.dump({"subscriptions": [SUB("9", account="admin")]}, f)
        self.p.send_all({"kind": "show", "tag": "s-a", "title": "x", "body": "b", "text": "b", "url": "/",
                         "ev": "wait", "name": "x", "fb": False, "av": {"id": "a", "st": "wait"}})
        # old subscription (no language, no device info, non-Apple endpoint): Simplified Chinese, with avatar
        self.assertEqual(self.sent[0][1], {"kind": "show", "tag": "s-a", "title": "x", "body": "b", "url": "/",
                                           "av": {"id": "a", "st": "wait"}})


if __name__ == "__main__":
    unittest.main()
