"""Push body rendering by summaryCode in three languages: api/summary.py is a port of summaryText in web/logic.js.
The template table matches the sum.* entries of web/i18n.js verbatim; the rules are checked case by case against the frontend (real logic.js run under node) with the same samples."""
import json
import os
import shutil
import subprocess
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from api import notify as N, summary as S  # noqa: E402
from tests.test_push_i18n import i18n_rows  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

CASES = [
    {"summary": "老看板原文"},
    {"summary": "x", "summaryCode": "wait.ask", "summaryArgs": {"question": "改不改 `a.py`？"}},
    {"summary": "x", "summaryCode": "wait.ask", "summaryArgs": {"question": "Q", "count": 3}},
    {"summary": "x", "summaryCode": "wait.ask", "summaryArgs": {"question": "Q", "count": "2"}},
    {"summary": "x", "summaryCode": "wait.ask", "summaryArgs": {"question": "Q", "count": 1}},
    {"summary": "x", "summaryCode": "wait.ask", "summaryArgs": {"question": "Q", "count": "abc"}},
    {"summary": "缺参数回原文", "summaryCode": "wait.ask", "summaryArgs": {}},
    {"summary": "x", "summaryCode": "wait.ask.generic"},
    {"summary": "x", "summaryCode": "wait.plan", "summaryArgs": {}},
    {"summary": "x", "summaryCode": "wait.approve.run", "summaryArgs": {"command": "rm -rf build"}},
    {"summary": "缺命令", "summaryCode": "wait.approve.run", "summaryArgs": {"command": None}},
    {"summary": "等你批准修改：", "summaryCode": "wait.approve.edit", "summaryArgs": {"file": ""}},
    {"summary": "x", "summaryCode": "wait.approve.edit", "summaryArgs": {"file": None}},
    {"summary": "x", "summaryCode": "wait.approve.edit", "summaryArgs": {}},
    {"summary": "x", "summaryCode": "wait.approve.edit", "summaryArgs": {"file": "web/app.js"}},
    {"summary": "x", "summaryCode": "wait.approve.tool", "summaryArgs": {"tool": "WebFetch"}},
    {"summary": "x", "summaryCode": "wait.approve"},
    {"summary": "x", "summaryCode": "wait.answer", "summaryArgs": {"options": 3}},
    {"summary": "x", "summaryCode": "wait.answer", "summaryArgs": {"options": 1}},
    {"summary": "x", "summaryCode": "wait.answer", "summaryArgs": {"options": "1"}},
    {"summary": "x", "summaryCode": "wait.answer", "summaryArgs": {"options": 2.0}},
    {"summary": "x", "summaryCode": "wait.answer", "summaryArgs": {}},
    {"summary": "x", "summaryCode": "state.paused"},
    {"summary": "x", "summaryCode": "state.stopped"},
    {"summary": "x", "summaryCode": "state.error"},
    {"summary": "x", "summaryCode": "prompt.you", "summaryArgs": {"text": "帮我看看"}},
    {"summary": "x", "summaryCode": "relay.agent"},
    {"summary": "x", "summaryCode": "relay.peer"},
    {"summary": "x", "summaryCode": "relay.from", "summaryArgs": {"peer": "Docs-QS"}},
    {"summary": "回原文", "summaryCode": "relay.from", "summaryArgs": {"name": "Docs-QS"}},
    {"summary": "x", "summaryCode": "text", "summaryArgs": {"kind": "reply", "text": "改好了，见 **README**"}},
    {"summary": "x", "summaryCode": "text", "summaryArgs": {"kind": "progress", "text": ""}},
    {"summary": "回原文", "summaryCode": "text", "summaryArgs": {"kind": "raw"}},
    {"summary": "x", "summaryCode": "none", "summaryArgs": {}},
    {"summary": "不认识的 code", "summaryCode": "future.thing", "summaryArgs": {"a": 1}},
    {"summary": "args 不是对象", "summaryCode": "wait.plan", "summaryArgs": "oops"},
    {"summary": "", "summaryCode": "", "summaryArgs": {}},
    {"summary": None},
    {"summary": "x", "summaryCode": "wait.ask", "summaryArgs": {"question": "{count} 不认识的 {zzz}", "count": 2}},
    # state.apiError (kind/status/text), state.retrying (attempt/max), state.disconnected
    {"summary": "x", "summaryCode": "state.apiError", "summaryArgs": {"kind": "api", "status": 529, "text": "Overloaded"}},
    {"summary": "x", "summaryCode": "state.apiError", "summaryArgs": {"kind": "api", "status": None, "text": "Connection error."}},
    {"summary": "x", "summaryCode": "state.apiError", "summaryArgs": {"kind": "api", "text": "no status key"}},
    {"summary": "x", "summaryCode": "state.apiError", "summaryArgs": {"kind": "rate_limit", "status": 429, "text": "You've hit your limit · resets 1pm"}},
    {"summary": "x", "summaryCode": "state.apiError", "summaryArgs": {"kind": "auth", "status": 401, "text": "OAuth expired"}},
    {"summary": "缺 text 回原文", "summaryCode": "state.apiError", "summaryArgs": {"kind": "api", "status": 500}},
    {"summary": "x", "summaryCode": "state.apiError", "summaryArgs": {"kind": "auth"}},
    {"summary": "x", "summaryCode": "state.retrying", "summaryArgs": {"attempt": 3, "max": 10}},
    {"summary": "缺 attempt 回原文", "summaryCode": "state.retrying", "summaryArgs": {"max": 10}},
    {"summary": "x", "summaryCode": "state.disconnected", "summaryArgs": {}},
]


class TableTest(unittest.TestCase):
    def test_sum_rows_match_i18n_js_both_ways(self):
        rows = {k: v for k, v in i18n_rows().items() if k.startswith("sum.")}
        self.assertEqual(sorted(rows), sorted(S.SUM_TEXT))
        for k, cols in S.SUM_TEXT.items():
            self.assertEqual(list(cols), rows[k], k)

    def test_twenty_codes(self):
        """The base set plus three (state.apiError / state.retrying / state.disconnected)."""
        codes = {k[4:] for k in S.SUM_TEXT} - {"wait.ask.n", "wait.approve.edit.nofile", "wait.answer.one", "wait.answer.noopt",
                                               "state.apiError.limit", "state.apiError.auth", "state.apiError.nostatus"}
        self.assertEqual(len(codes | {"text", "none"}), 20)


class RuleTest(unittest.TestCase):
    def r(self, code, args, lang, summary="原文"):
        return S.summary_text({"summary": summary, "summaryCode": code, "summaryArgs": args}, lang)

    def test_three_languages(self):
        self.assertEqual(self.r("wait.ask", {"question": "改不改？"}, "en"), "Asks: 改不改？")  # quoted original text is not translated
        self.assertEqual(self.r("wait.ask", {"question": "改不改？"}, "hant"), "問你：改不改？")
        self.assertEqual(self.r("wait.approve.run", {"command": "make"}, "en"), "Approve to run: make")
        self.assertEqual(self.r("wait.plan", {}, "hant"), "計畫寫好了，等你核准")

    def test_fallbacks(self):
        self.assertEqual(self.r("wait.ask", {}, "en"), "原文")
        self.assertEqual(self.r("no.such", {}, "en"), "原文")
        self.assertEqual(S.summary_text({"summary": "旧看板"}, "en"), "旧看板")
        self.assertEqual(self.r("none", {}, "en"), "")
        self.assertEqual(self.r("text", {"kind": "reply", "text": "干完了"}, "en"), "干完了")

    def test_b3_simplified_templates_match_contract(self):
        """Simplified Chinese templates verbatim: apiError "API 出错 {status}：{text}", status null "API 出错：{text}", rate_limit is just {text},
        auth "要重新登录"; retrying "正在重试 {attempt}/{max}"; disconnected "意外退出"."""
        self.assertEqual(self.r("state.apiError", {"kind": "api", "status": 529, "text": "Overloaded"}, "hans"), "API 出错 529：Overloaded")
        self.assertEqual(self.r("state.apiError", {"kind": "api", "status": None, "text": "Connection error."}, "hans"), "API 出错：Connection error.")
        self.assertEqual(self.r("state.apiError", {"kind": "rate_limit", "status": 429, "text": "resets 1pm"}, "hans"), "resets 1pm")
        self.assertEqual(self.r("state.apiError", {"kind": "rate_limit", "status": 429, "text": "resets 1pm"}, "en"), "resets 1pm")
        self.assertEqual(self.r("state.apiError", {"kind": "auth", "status": 401, "text": "x"}, "hans"), "要重新登录")
        self.assertEqual(self.r("state.apiError", {"kind": "auth"}, "hant"), "需要重新登入")
        self.assertEqual(self.r("state.apiError", {"kind": "api", "status": 500}, "hans"), "原文")  # missing text falls back to the original
        self.assertEqual(self.r("state.retrying", {"attempt": 3, "max": 10}, "hans"), "正在重试 3/10")
        self.assertEqual(self.r("state.retrying", {"attempt": 3, "max": 10}, "en"), "Retrying 3/10")
        self.assertEqual(self.r("state.retrying", {"max": 10}, "hans"), "原文")
        self.assertEqual(self.r("state.disconnected", {}, "hans"), "意外退出")
        self.assertEqual(self.r("state.disconnected", {}, "hant"), "意外結束")
        self.assertEqual(self.r("state.disconnected", {}, "en"), "Exited unexpectedly")

    def test_edit_without_file_uses_nofile(self):
        for f in ("", None):
            self.assertEqual(self.r("wait.approve.edit", {"file": f}, "en"), "Approve a file edit")
            self.assertEqual(self.r("wait.approve.edit", {"file": f}, "hans"), "等你批准修改文件")


@unittest.skipUnless(shutil.which("node"), "node not available")
class ParityWithFrontendTest(unittest.TestCase):
    """The same samples go through the real web/logic.js summaryText (node) and through Python; results must be identical for each of the three languages."""

    def test_same_as_logic_js(self):
        js = ("import * as L from './web/logic.js'; import { setLang } from './web/i18n.js';"
              "const cases = JSON.parse(require_stdin());"
              "const out = {}; for (const l of ['en','hans','hant']) { setLang(l); out[l] = cases.map((c) => L.summaryText(c)); }"
              "process.stdout.write(JSON.stringify(out));")
        js = js.replace("require_stdin()", "(await new Promise((r) => { let d = ''; process.stdin.on('data', (x) => d += x); process.stdin.on('end', () => r(d)); }))")
        p = subprocess.run(["node", "--input-type=module", "-e", js], input=json.dumps(CASES), capture_output=True,
                           text=True, cwd=ROOT, timeout=30)
        self.assertEqual(p.returncode, 0, p.stderr)
        want = json.loads(p.stdout)
        for lang in S.LANGS:
            for c, w in zip(CASES, want[lang]):
                self.assertEqual(S.summary_text(c, lang), w, (lang, c))


class PushBodyTest(unittest.TestCase):
    """notify: the "waiting for you" body follows the subscription language; fallback and "done" are unchanged."""

    def run_step(self, s):
        sess = dict({"id": "a", "name": "Web-QS", "zone": "Web", "status": "waiting", "since": 1}, **s)
        st, _ = N.step(N.new_state(), [], 0, lambda *_: "")
        st, acts = N.step(st, [sess], 10, lambda x, k: N.wait_body(x, []) if k == "wait" else N.done_body([]),
                          [{"code": "Web", "lead": ""}])
        st, acts = N.step(st, [sess], 20, lambda x, k: N.wait_body(x, []) if k == "wait" else N.done_body([]),
                          [{"code": "Web", "lead": ""}])
        self.assertEqual(len(acts), 1)
        return acts[0]

    def test_wait_body_per_language(self):
        a = self.run_step({"summary": "问你：改不改？", "summaryCode": "wait.ask", "summaryArgs": {"question": "改不改？"}})
        self.assertEqual(a["body"], "问你：改不改？")  # Simplified Chinese version (log, old subscriptions)
        self.assertEqual(N.localize(a, "en")["body"], "Asks: 改不改？")
        self.assertEqual(N.localize(a, "hant")["body"], "問你：改不改？")
        self.assertEqual(N.localize(a, None)["body"], "问你：改不改？")
        self.assertNotIn("sum", N.localize(a, "en"))  # internal fields are not sent out

    def test_markdown_stripped_and_clipped_in_every_language(self):
        a = self.run_step({"summary": "x", "summaryCode": "wait.approve.run", "summaryArgs": {"command": "`" + "y" * 300 + "`"}})
        for lg in S.LANGS:
            b = N.localize(a, lg)["body"]
            self.assertEqual(len(b), N.MAX_BODY, lg)  # content truncated to 120 characters, no label
            self.assertNotIn("`", b)

    def test_none_code_uses_fallback(self):
        a = self.run_step({"summary": "", "summaryCode": "none", "summaryArgs": {}})
        self.assertTrue(a["fb"])
        self.assertEqual(N.localize(a, "en")["body"], "Waiting for your decision")

    def test_old_summary_without_code_same_in_all_languages(self):
        a = self.run_step({"summary": "旧看板摘要"})
        self.assertEqual({N.localize(a, lg)["body"] for lg in S.LANGS}, {"旧看板摘要"})

    def test_done_reply_literal_stays_original(self):
        # the Agent's last sentence happens to be "干完了": it is original text (not the fallback), and an English subscription still receives "干完了"
        st, _ = N.step(N.new_state(), [], 0, lambda *_: "")
        sess = {"id": "a", "name": "Web-QS", "status": "idle", "unread": True, "since": 1}
        body = lambda x, k: N.done_body([{"role": "assistant", "text": "干完了"}])  # noqa: E731
        st, _ = N.step(st, [sess], 1, body)
        st, acts = N.step(st, [sess], 20, body)
        self.assertEqual(N.localize(acts[0], "en")["body"], "干完了")


if __name__ == "__main__":
    unittest.main()
