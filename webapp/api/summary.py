"""Session one-line summary rendered per language (pure logic): a Python port of web/logic.js summaryText, used for push bodies.
The Mac --dump gives summaryCode / summaryArgs; known codes render from the three-language templates below, which match the
sum.* entries in web/i18n.js character for character (tests/test_summary.py checks). Anything unknown falls back to the raw summary."""
import math
import re
from typing import Any, Dict

LANGS = ("en", "hans", "hant")

# Each key has three columns (en, hans, hant), identical to the same key in web/i18n.js; placeholders like {question} are filled from summaryArgs, and quoted text is not translated
SUM_TEXT = {
    "sum.wait.ask": ("Asks: {question}", "问你：{question}", "問你：{question}"),
    "sum.wait.ask.n": ("Asks: {question} ({count} questions)", "问你：{question}（共 {count} 个问题）", "問你：{question}（共 {count} 個問題）"),
    "sum.wait.ask.generic": ("Has a question for you", "在等你回答问题", "在等你回答問題"),
    "sum.wait.plan": ("Plan ready for approval", "计划写好了，等你批准", "計畫寫好了，等你核准"),
    "sum.wait.approve.run": ("Approve to run: {command}", "等你批准运行：{command}", "等你核准執行：{command}"),
    "sum.wait.approve.edit": ("Approve edit: {file}", "等你批准修改：{file}", "等你核准修改：{file}"),
    "sum.wait.approve.edit.nofile": ("Approve a file edit", "等你批准修改文件", "等你核准修改檔案"),
    "sum.wait.approve.tool": ("Approve tool: {tool}", "等你批准使用 {tool}", "等你核准使用 {tool}"),
    "sum.wait.approve": ("Needs approval", "等你批准", "等你核准"),
    "sum.wait.answer": ("Needs your answer ({options} options)", "等你回答（{options} 个选项）", "等你回答（{options} 個選項）"),
    "sum.wait.answer.one": ("Needs your answer (1 option)", "等你回答（1 个选项）", "等你回答（1 個選項）"),
    "sum.wait.answer.noopt": ("Needs your answer", "等你回答", "等你回答"),
    "sum.state.paused": ("Paused", "已暂停", "已暫停"),
    "sum.state.stopped": ("Stopped", "已中止", "已中止"),
    "sum.state.error": ("Error", "出错", "出錯"),
    # apiError splits by args.kind into api / rate_limit (Claude Code's own wording, untranslated) / auth; a null status uses nostatus
    "sum.state.apiError": ("API error {status}: {text}", "API 出错 {status}：{text}", "API 出錯 {status}：{text}"),
    "sum.state.apiError.limit": ("{text}", "{text}", "{text}"),
    "sum.state.apiError.auth": ("Needs sign-in again", "要重新登录", "需要重新登入"),
    "sum.state.apiError.nostatus": ("API error: {text}", "API 出错：{text}", "API 出錯：{text}"),
    "sum.state.retrying": ("Retrying {attempt}/{max}", "正在重试 {attempt}/{max}", "正在重試 {attempt}/{max}"),
    "sum.state.disconnected": ("Exited unexpectedly", "意外退出", "意外結束"),
    "sum.prompt.you": ("You: {text}", "你：{text}", "你：{text}"),
    "sum.relay.agent": ("Handling a subagent report…", "处理子代理回报…", "處理子代理回報…"),
    "sum.relay.peer": ("Handling a message from another session…", "处理其他会话的消息…", "處理其他會話的訊息…"),
    "sum.relay.from": ("Handling {peer}'s report…", "处理 {peer} 的回报…", "處理 {peer} 的回報…"),
}
# Without these required args, the code falls back to the raw summary (same as the frontend SUM_NEED)
SUM_NEED = {"wait.ask": "question", "wait.approve.run": "command", "wait.approve.tool": "tool",
            "prompt.you": "text", "relay.from": "peer", "state.retrying": "attempt"}
_SLOT = re.compile(r"\{(\w+)\}", re.ASCII)  # same as JS \w (ASCII only)


def _js_str(v: Any) -> str:
    """Stringify like JS String(v) (number 3.0 -> "3", true -> "true") so the three-language templates match the frontend exactly."""
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, float):
        if math.isnan(v):
            return "NaN"
        if math.isinf(v):
            return "Infinity" if v > 0 else "-Infinity"
        return str(int(v)) if v.is_integer() and abs(v) < 1e21 else repr(v)
    if isinstance(v, (list, tuple)):
        return ",".join("" if x is None else _js_str(x) for x in v)
    if isinstance(v, dict):
        return "[object Object]"
    return str(v)


def _js_num(v: Any) -> float:
    """Like JS Number(v): null -> 0, bool -> 1/0, empty string -> 0, unrecognized -> NaN."""
    if v is None:
        return 0.0
    if isinstance(v, bool):
        return 1.0 if v else 0.0
    if isinstance(v, (int, float)):
        return float(v)
    if isinstance(v, str):
        s = v.strip()
        if not s:
            return 0.0
        if s in ("Infinity", "+Infinity", "-Infinity"):
            return -math.inf if s[0] == "-" else math.inf
        if "_" in s or s.lower().lstrip("+-") in ("nan", "inf", "infinity"):  # forms Python accepts but JS does not
            return math.nan
        try:
            return float(s)
        except ValueError:
            return math.nan
    return math.nan


def _fill(key: str, lang: str, args: Dict[str, Any]) -> str:
    row = SUM_TEXT[key]
    i = LANGS.index(lang) if lang in LANGS else 1
    s = row[i] or (row[1] if lang == "hant" else "") or row[0]
    return _SLOT.sub(lambda m: _js_str(args[m.group(1)]) if args.get(m.group(1)) is not None else m.group(0), s)


def summary_text(s: Any, lang: str) -> str:
    """Render a session summary for a language, same rules as the frontend summaryText: no code, unknown code, or missing required arg -> raw summary;
    text (args.kind = reply / progress / recap / raw) returns args.text as is; none = empty."""
    if not isinstance(s, dict):
        return ""
    raw = s.get("summary")
    raw = _js_str(raw) if raw not in (None, "", 0, False) else ""
    code = s.get("summaryCode") if isinstance(s.get("summaryCode"), str) else ""
    if not code:
        return raw
    a = s.get("summaryArgs") if isinstance(s.get("summaryArgs"), dict) else {}
    if code == "text":
        return a["text"] if isinstance(a.get("text"), str) else raw
    if code == "none":
        return ""
    need = SUM_NEED.get(code)
    if need and a.get(need) is None:
        return raw
    if code == "wait.ask" and _js_num(a.get("count")) > 1:
        return _fill("sum.wait.ask.n", lang, a)
    # null or empty file takes the same path (nofile, no trailing colon)
    if code == "wait.approve.edit":
        f = a.get("file")
        if f is None or f == "":
            return _fill("sum.wait.approve.edit.nofile", lang, a)
        return _fill("sum.wait.approve.edit", lang, {"file": _js_str(f)})
    if code == "wait.answer":
        if a.get("options") is None:
            return _fill("sum.wait.answer.noopt", lang, a)
        return _fill("sum.wait.answer.one" if _js_num(a.get("options")) == 1 else "sum.wait.answer", lang, a)
    # state.apiError: auth is a fixed line; otherwise text is required (raw summary if absent); rate_limit is Claude Code's own wording; a null status omits the status code
    if code == "state.apiError":
        if a.get("kind") == "auth":
            return _fill("sum.state.apiError.auth", lang, a)
        if a.get("text") is None:
            return raw
        if a.get("kind") == "rate_limit":
            return _fill("sum.state.apiError.limit", lang, a)
        return _fill("sum.state.apiError" if a.get("status") is not None else "sum.state.apiError.nostatus", lang, a)
    key = "sum." + code
    return _fill(key, lang, a) if key in SUM_TEXT else raw
