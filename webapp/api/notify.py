"""Notification rules (pure logic): given the previous state, a session snapshot and the current time, return the show/recall actions and the new state.
No file access, no network, no clock; the body comes from the caller's body_fn (called only when a push is really sent)."""
import re
from typing import Any, Callable, Dict, List, Optional, Tuple
from urllib.parse import quote

try:
    from api.summary import SUM_TEXT, summary_text
    from api.state import error_kind, is_gone
except ImportError:  # in the container the contents of api/ sit directly in the working directory
    from summary import SUM_TEXT, summary_text  # type: ignore
    from state import error_kind, is_gone  # type: ignore

WAIT_DELAY = 3      # seconds: push only after waiting has lasted this long
UNREAD_DELAY = 10   # seconds: push only after unread has lasted this long
MAX_BODY = 120


class _Fallback(str):
    """Marker type for fallback body text. step() recognizes "this is a fallback" by type, not by text: an Agent that really replies "Done" must not be treated as a fallback
    and switched to the English "Done". Compares and concatenates like a plain str."""
    __slots__ = ()


class _Summary(str):
    """Marker type for body text taken from the session summary (Simplified version): step() re-renders it in three languages from the session's summaryCode, and localize() picks by subscription language."""
    __slots__ = ()


class _Ask(str):
    """Marker type for a raw question taken from the transcript's last ask: localize() wraps it as "Asks: ..." per subscription language (sum.wait.ask)."""
    __slots__ = ()


FALLBACK_WAIT = _Fallback("有事要你定")
FALLBACK_DONE = _Fallback("干完了")

# Push wording is generated per the language stored with each subscription (the frontend POSTs the current UI language on subscribing; old subscriptions without a language use Simplified).
# Each key has three columns (en, hans, hant), identical character for character to the same key in web/i18n.js (checked by tests/test_push_i18n.py). The original session summary is not translated
PUSH_LANGS = ("en", "hans", "hant")
PUSH_TEXT = {
    "pushmsg.wait": ("Waiting for you", "在等你", "在等你"),
    "pushmsg.done": ("Done", "干完了", "完成了"),
    "pushmsg.fbWait": ("Needs your decision", FALLBACK_WAIT, "有事要你決定"),
    "pushmsg.fbDone": ("Done", FALLBACK_DONE, "完成了"),
    "pushmsg.testTitle": ("Soulgent test", "Soulgent 测试", "Soulgent 測試"),
    "pushmsg.testBody": ("This is a test notification", "这是一条测试通知", "這是一則測試通知"),
    # WorkBuddy error / stopped (summaryCode state.error / state.stopped); Mac disconnected / restored (tag mac-link, admin only)
    "pushmsg.err": ("Error", "出错了", "出錯了"),
    "pushmsg.stopped": ("Stopped", "已中止", "已中止"),
    # Limit reached (rate_limit); session process exited unexpectedly (disconnected, pushed once, no "done" push)
    "pushmsg.limit": ("Limit reached", "额度用完", "額度用完"),
    "pushmsg.lost": ("Exited unexpectedly", "意外退出", "意外結束"),
    "pushmsg.macDown": ("Mac disconnected", "Mac 已断开", "Mac 已中斷連線"),
    "pushmsg.macDownBody": ("{reason}. Data as of {at}", "{reason}，数据截至 {at}", "{reason}，資料截至 {at}"),
    "pushmsg.macUp": ("Mac reconnected", "Mac 已恢复", "Mac 已恢復連線"),
    "pushmsg.macUpBody": ("Data is live again", "数据已更新", "資料已更新"),
    # System push bodies (WeChat style: the title is the session, the body is just the message; the in-app banner keeps its "[label] text" form)
    "pushmsg.waitFb": ("Waiting for your decision", "在等你决定", "在等你決定"),
    "pushmsg.errBody": ("Error: {text}", "出错：{text}", "出錯：{text}"),
    "pushmsg.errStatusBody": ("Error {status}: {text}", "出错 {status}：{text}", "出錯 {status}：{text}"),
    "pushmsg.limitBody": ("Limit reached: {text}", "额度用完：{text}", "額度用完：{text}"),
    "pushmsg.reasonHelper": ("Helper stopped", "小帮手停了", "小幫手停了"),
    "pushmsg.reasonPanel": ("Soulgent isn't responding", "Soulgent 没响应", "Soulgent 沒回應"),
    # Session notification title = full session name; shown per language when the panel did not supply a name (same as the frontend plateOf)
    "name.untitled": ("Untitled", "未命名", "未命名"),
}
SESSION_EVS = ("wait", "done", "err", "stopped", "limit", "lost")  # session push event kinds: body label pushmsg.<ev>
URGENT_EVS = ("wait", "err", "limit", "lost")  # these are pushed after 3 s (WAIT_DELAY), the rest after 10 s
LINK_REASON = {"helper": "pushmsg.reasonHelper", "panel": "pushmsg.reasonPanel"}


def push_lang(v: Any) -> str:
    return v if isinstance(v, str) and v in PUSH_LANGS else "hans"


def ptext(key: str, lang: Any) -> str:
    return PUSH_TEXT[key][PUSH_LANGS.index(push_lang(lang))]


_INTERNAL = ("ev", "name", "untitled", "fb", "text", "i18n", "sum", "reason", "at", "av", "head", "emoji", "ask", "apiErr")


def localize(action: Dict[str, Any], lang: Any, icon: bool = False) -> Dict[str, Any]:
    """Action from step() (or push.TEST_SHOW) -> payload sent to one subscription: title and body composed per language; internal fields are not sent.
    Title = emoji + full session name (untitled is per language); body = the message (see _session_text); for a fallback, or content synonymous with the label, only the full event word is written.
    Only icon=True (non-Apple endpoints) carries the session avatar av, which sw resolves to an image. Actions without these fields (recall, legacy format) are sent as is."""
    out = {k: v for k, v in action.items() if k not in _INTERNAL}
    if icon and isinstance(action.get("av"), dict):
        out["av"] = action["av"]
    if action.get("i18n") == "test":
        out["title"], out["body"] = ptext("pushmsg.testTitle", lang), ptext("pushmsg.testBody", lang)
    elif action.get("ev") in ("macDown", "macUp"):
        out["title"], out["body"] = _link_text(action, lang)
    elif action.get("ev") in SESSION_EVS:
        out["title"], out["body"] = _session_text(action, lang)
    return out


def _session_text(action: Dict[str, Any], lang: Any) -> Tuple[str, str]:
    """Title = per-session emoji + session name (iOS always shows the app icon, so the emoji stands in for the avatar); body = the message itself, WeChat style.
    Waiting has no label (a raw ask question becomes "Asks: ..."); error / limit read "Error: ..." / "Limit reached: ..."; done is the text; fallbacks write the full event word."""
    ev = action["ev"]
    title = ptext("name.untitled", lang) if action.get("untitled") else str(action.get("name") or "")
    emoji = action.get("emoji")
    if isinstance(emoji, str) and emoji:
        title = emoji + " " + title
    if action.get("fb"):
        if ev == "wait":
            return title, ptext("pushmsg.waitFb", lang)
        return title, ptext("pushmsg.fbDone" if ev == "done" else "pushmsg." + ev, lang)
    text = str(action.get("text", action.get("body")) or "")  # text: raw content (body is already the finished Simplified version)
    if isinstance(action.get("sum"), dict) and action["sum"].get(push_lang(lang)):
        text = action["sum"][push_lang(lang)]
    if ev == "done":
        return title, text
    if ev == "wait":
        if action.get("ask"):
            return title, SUM_TEXT["sum.wait.ask"][PUSH_LANGS.index(push_lang(lang))].replace("{question}", text)
        return title, text
    api_err = action.get("apiErr")
    if ev == "err" and isinstance(api_err, dict):  # API error: the push says "Error {status}: {text}" (not the rendered "API error ..." summary, which would repeat "error")
        if api_err.get("status") is not None:
            return title, ptext("pushmsg.errStatusBody", lang).replace("{status}", str(api_err["status"])).replace("{text}", str(api_err.get("text") or ""))
        return title, ptext("pushmsg.errBody", lang).replace("{text}", str(api_err.get("text") or ""))
    if ev in ("err", "limit"):
        return title, ptext("pushmsg." + ev + "Body", lang).replace("{text}", text)
    return title, "[" + ptext("pushmsg." + ev, lang) + "] " + text


# ---------- Per-session emoji in the title ----------
# iOS web push ignores icon / image (the lock screen always shows the app icon), so the title starts with an emoji standing in for the avatar.
# The effective pet follows the list avatar (web/app.js petName, sw.js avatarPath): the assigned pet if installed, else the pet picked by hash(session id)
# from the sorted pet manifest; no pet at all -> the flame mascot. The emoji is picked from the palette by a stable hash of the pet id;
# data/pet-emoji.json ({petId: emoji}, optional, private) overrides it per pet.
FLAME_EMOJI = "\U0001F525"
PET_EMOJI = tuple(
    "\U0001F436 \U0001F431 \U0001F42D \U0001F439 \U0001F430 \U0001F98A \U0001F43B \U0001F43C "
    "\U0001F428 \U0001F42F \U0001F981 \U0001F42E \U0001F437 \U0001F438 \U0001F435 \U0001F414 "
    "\U0001F427 \U0001F426 \U0001F986 \U0001F989 \U0001F984 \U0001F41D \U0001F41B \U0001F98B "
    "\U0001F40C \U0001F41E \U0001F422 \U0001F40D \U0001F996 \U0001F419 \U0001F991 \U0001F980 "
    "\U0001F420 \U0001F42C \U0001F433 \U0001F988 \U0001F40A \U0001F993 \U0001F992 \U0001F994 "
    "\U0001F335 \U0001F344 \U0001F33B \U0001F340 \U0001F349 \U0001F353 \U0001F388 \U0001F680".split())
MAX_EMOJI = 16  # override values longer than this (characters) are ignored


def js_hash(text: str) -> int:
    """Same as app.js hash() / sw.js swHash(): djb2 over UTF-16 code units, wrapped to int32, absolute value."""
    x = 5381
    raw = str(text).encode("utf-16-le")
    for i in range(0, len(raw), 2):
        x = (x * 33 + (raw[i] | raw[i + 1] << 8)) & 0xFFFFFFFF
    if x >= 0x80000000:
        x -= 0x100000000
    return abs(x)


def effective_pet(s: Dict[str, Any], sid: str, names: Optional[List[str]]) -> Optional[str]:
    """names: sorted installed pet ids (None = manifest unknown: only the assigned pet counts)."""
    pet = s.get("pet")
    if isinstance(pet, str) and pet and (names is None or pet in names):
        return pet
    if names:
        return names[js_hash(sid) % len(names)]
    return None


def pet_emoji(pet: Optional[str], override: Optional[Dict[str, Any]] = None) -> str:
    if not pet:
        return FLAME_EMOJI
    v = (override or {}).get(pet)
    if isinstance(v, str) and v.strip() and len(v.strip()) <= MAX_EMOJI:
        return v.strip()
    return PET_EMOJI[js_hash(pet) % len(PET_EMOJI)]


def session_emoji(s: Dict[str, Any], sid: str, pets: Optional[Dict[str, Any]] = None) -> str:
    """pets: {"names": sorted pet ids or None, "emoji": override map or None}."""
    pets = pets or {}
    names = pets.get("names")
    return pet_emoji(effective_pet(s, sid, names if isinstance(names, list) else None),
                     pets.get("emoji") if isinstance(pets.get("emoji"), dict) else None)


State = Dict[str, Any]
Action = Dict[str, str]
BodyFn = Callable[[Dict[str, Any], str], str]


def new_state() -> State:
    return {"init": False, "e": {}}


def clip(text: str, limit: int = MAX_BODY) -> str:
    return text if len(text) <= limit else text[:limit - 1] + "…"


_FENCE = re.compile(r"^\s*(```|~~~).*$", re.M)
_IMG_LINK = re.compile(r"!?\[([^\]]*)\]\([^)]*\)")
_HEAD = re.compile(r"^\s{0,3}#{1,6}\s+", re.M)
_QUOTE = re.compile(r"^\s{0,3}>+\s?", re.M)
_BULLET = re.compile(r"^\s*(?:[-*+]|\d+\.)\s+", re.M)
_EMPH = re.compile(r"(\*{1,3}|_{2,3})(.+?)\1", re.S)


def strip_markdown(text: str) -> str:
    t = _FENCE.sub("", str(text))
    t = _IMG_LINK.sub(r"\1", t)
    t = _HEAD.sub("", t)
    t = _QUOTE.sub("", t)
    t = _BULLET.sub("", t)
    t = _EMPH.sub(r"\2", t)
    t = t.replace("`", "").replace("*", "").replace("~~", "")
    return re.sub(r"\s+", " ", t).strip()


def done_body(items: List[Dict[str, Any]]) -> str:
    """Last assistant text on the first page of the conversation, Markdown stripped, first 120 chars."""
    for it in reversed(items or []):
        if it.get("role") == "assistant":
            text = strip_markdown(it.get("text") or "")
            if text:
                return clip(text)
    return FALLBACK_DONE


def sum_body(session: Dict[str, Any], lang: str) -> str:
    """Render the session summary per language (summaryCode rules same as the frontend summaryText), Markdown stripped, first 120 chars; an empty render means no summary."""
    return clip(strip_markdown(summary_text(session, lang)))


def wait_body(session: Dict[str, Any], items: List[Dict[str, Any]]) -> str:
    """The question summary in the snapshot takes priority (the Simplified version rendered from summaryCode; step() then produces three languages); otherwise the last ask's question or the pending tool summary."""
    summary = sum_body(session, "hans")
    if summary:
        return _Summary(summary)
    for it in reversed(items or []):
        role = it.get("role")
        if role == "ask":
            qs = [str(q.get("question", "")).strip() for q in it.get("questions") or []
                  if isinstance(q, dict)]
            text = " ".join(q for q in qs if q) or str(it.get("text") or "")
            text = strip_markdown(text)
            if text:
                return _Ask(clip(text))
        elif role == "tool" and it.get("pending"):
            text = strip_markdown(it.get("text") or "")
            if text:
                return clip(text)
    return FALLBACK_WAIT


def _title_name(s: Dict[str, Any], sid: str) -> str:
    for k in ("name", "project"):
        v = s.get(k)
        if isinstance(v, str) and v.strip():
            return v.strip()
    return sid[:8]


# WorkBuddy: the existing summaryCode state.* decides what the "done" push becomes (with an errorKind, wb_error / wb_stopped is read instead).
# An error pushes "Error" (3 s, like waiting); stopped pushes "Stopped"; paused is neither a fault nor urgent, so it stays "Done"
_DONE_AS = {"state.error": "err", "state.stopped": "stopped"}
# With an errorKind it takes precedence (otherwise fall back to the summaryCode above): limit reached has its own label, WorkBuddy stopped stays "Stopped"
_ERR_AS = {"api": "err", "auth": "err", "wb_error": "err", "rate_limit": "limit", "wb_stopped": "stopped"}


def _done_kind(s: Dict[str, Any]) -> str:
    k = error_kind(s)
    return _ERR_AS[k] if k else _DONE_AS.get(str(s.get("summaryCode") or ""), "done")


def _avatar(s: Dict[str, Any], sid: str, kind: str) -> Dict[str, Any]:
    """Session avatar (Chrome / Edge / Android only): the server does not know the pet list, only the session id, the assigned pet and the spirit-flame expression;
    sw applies the same rules as the list (assigned pet -> pet picked by hash(id) from still.webp -> spirit flame mascot-av-<st>.png) and converts the image to a data URL."""
    av = {"id": sid, "st": "wait" if kind == "wait" else "done"}  # type: Dict[str, Any]
    pet = s.get("pet")
    if isinstance(pet, str) and pet and len(pet) <= 64:
        av["pet"] = pet
    return av


def _trigger(s: Dict[str, Any]) -> Optional[Tuple[str, Any]]:
    if s.get("muted"):  # do not disturb: no waiting / done pushes
        return None
    if s.get("status") == "waiting":
        return ("wait", s.get("since"))
    if is_gone(s):  # unexpected exit is pushed once (turn = exit time), no "done" push; flags_for has already forced unread to False
        return ("lost", s.get("disconnectedSince") or s.get("since"))
    if s.get("unread") and not s.get("manualUnread"):  # sessions swiped "mark as unread" are not pushed
        # The turn key is finishedAt (= max(since, bgEndedAt), written into the session item by state.flags_for); killing a background task via /tasks counts as a new turn even though since is unchanged.
        # Session items without finishedAt (legacy callers) still use since. While a background task runs (bg_live), flags_for has already forced unread to False
        # With an errorKind it pushes "error / limit reached / stopped" and not "done"; finishedAt already includes errorSince
        return (_done_kind(s), s.get("finishedAt", s.get("since")))
    return None


# ---------- App icon badge ----------
# The number = waiting + has-something-to-say (unread), same basis as the bottom-bar red dot (web/logic.js chatBadge -> countOf): resting sessions are excluded,
# muted / manually marked unread are still counted, waiting takes priority over unread (one session counts once). tests/test_badge.py runs node to cross-check with the frontend.
def badge_count(sessions: List[Dict[str, Any]]) -> int:
    n = 0
    for s in sessions or []:
        if not isinstance(s, dict) or s.get("rest"):
            continue
        if s.get("status") == "waiting" or (s.get("unread") and not is_gone(s)):  # unexpected exit is not counted (same as frontend kindOf gone)
            n += 1
    return n


def with_badge(actions: List[Dict[str, Any]], sessions: List[Dict[str, Any]]) -> List[Dict[str, Any]]:
    """Attach the current badge count to every action to be sent (sw sets the badge after receiving the push and calling showNotification). The original actions are not modified."""
    n = badge_count(sessions)
    return [dict(a, badge=n) for a in actions]


def _recall_if_needed(e: Dict[str, Any], sid: str, out: List[Action]) -> None:
    if e["pushed"] and not e["recalled"]:
        e["recalled"] = True  # only clears server state, no further "handled" push; the notification is closed locally by sw / the page


# ---------- The device in use goes first ----------
# If a device of the same account is in use (foreground snapshot polling carries X-Zbs-Dev / X-Zbs-Act, api/server.py Presence) -> no system notification at the due time; hold and wait for that device's banner to report back
# (X-Zbs-Seen: s-<session id>:<event>); after HOLD_MAX seconds with no report, or once the devices in use are gone -> push to all devices of the account as usual.
# After delivery, if no device is in use and it is still the same turn of waiting / error, push once more after NAG_AFTER seconds (once only); done / stopped get no repeat
HOLD_MAX = 12
NAG_AFTER = 120
NAG_EVS = ("wait", "err", "limit")  # unexpected exit (lost) is pushed once, no repeat
SEEN_SLACK = 2  # the report time may be this many seconds earlier than the server first saw the turn (frontend and server read their own snapshots, one poll apart)


def seen_key(sid: str, kind: str) -> str:
    return "s-%s:%s" % (sid, kind)


def _seen_ok(seen: Optional[Dict[str, float]], sid: str, e: Dict[str, Any]) -> bool:
    t = (seen or {}).get(seen_key(sid, e["kind"]))
    return isinstance(t, (int, float)) and t >= e["first"] - SEEN_SLACK


def _show(s: Dict[str, Any], sid: str, e: Dict[str, Any], now: float, body_fn: BodyFn,
          pets: Optional[Dict[str, Any]] = None) -> Action:
    try:
        raw = body_fn(s, e["kind"])
    except Exception:
        raw = FALLBACK_WAIT if e["kind"] in ("wait", "err", "limit") else FALLBACK_DONE
    # Fallback is recognized by type, not by comparing body text with the Chinese fallback phrase; the body of a WorkBuddy error / stopped is the state summary (synonymous with the label) -> only the full word is written
    # The body of an unexpected exit is also just the full word; API error / limit reached carry content (rendered from state.apiError) -> "[<error label>] API error 529: ..."
    fb = (isinstance(raw, _Fallback) or e["kind"] == "lost"
          or (e["kind"] in ("err", "stopped") and (str(s.get("summaryCode") or "") in _DONE_AS
                                                    or error_kind(s) in ("wb_error", "wb_stopped"))))
    text = str(raw)
    rnd = e["round"]
    ts = rnd if isinstance(rnd, (int, float)) and not isinstance(rnd, bool) and rnd > 0 else now
    # ev/name/untitled/fb/sum let localize() compose title and body per subscription language, av lets sw draw the session avatar for non-Apple subscriptions; removed before sending
    act = {"kind": "show", "tag": "s-" + sid, "text": clip(text), "url": "/#s/" + quote(sid, safe=""),
           "timestamp": int(round(ts * 1000)), "ev": e["kind"], "name": _title_name(s, sid),
           "untitled": s.get("nameUntitled") is True, "fb": fb, "av": _avatar(s, sid, e["kind"]),
           "emoji": session_emoji(s, sid, pets)}
    if isinstance(raw, _Ask) and not fb:
        act["ask"] = True
    if isinstance(raw, _Summary):  # body is a session summary: render one copy per language (without a code, all three are the original text)
        act["sum"] = {lg: sum_body(s, lg) or clip(text) for lg in PUSH_LANGS}
    a = s.get("summaryArgs") if isinstance(s.get("summaryArgs"), dict) else {}
    if (e["kind"] == "err" and not fb and s.get("summaryCode") == "state.apiError"
            and a.get("kind") not in ("auth", "rate_limit") and isinstance(a.get("text"), str) and a["text"]):
        act["apiErr"] = {"status": a.get("status"), "text": clip(a["text"])}
    # title/body hold the Simplified version: used in logs, and received by old subscriptions (no stored language)
    act["title"], act["body"] = _session_text(act, "hans")
    e["pushed"] = True
    return act


def step(state: State, sessions: List[Dict[str, Any]], now: float,
         body_fn: BodyFn, zones: Optional[List[Dict[str, Any]]] = None,
         active: bool = False, seen: Optional[Dict[str, float]] = None,
         pets: Optional[Dict[str, Any]] = None) -> Tuple[State, List[Action]]:
    """sessions: each item has id/name/status/since/unread (unread already includes panel sync); zones: the snapshot's zone table (code/color/lead).
    active: whether this account has a device in use now; seen: "s-<id>:<event>" this account has reported -> report time;
    pets: installed pet ids + emoji overrides for the title emoji (session_emoji). The passed-in state is not modified."""
    entries = {k: dict(v) for k, v in state["e"].items()}  # type: Dict[str, Dict[str, Any]]
    out = []  # type: List[Action]
    first_run = not state["init"]
    present = set()
    for s in sessions:
        sid = str(s.get("id"))
        present.add(sid)
        trig = _trigger(s)
        e = entries.get(sid)
        if e is not None and (trig is None or (e["kind"], e["round"]) != trig):
            _recall_if_needed(e, sid, out)
            if trig is None and e["fired"]:
                continue  # keep: it will not be pushed again if it returns in the same turn
            del entries[sid]
            e = None
        if trig is None:
            continue
        if e is None:
            e = entries[sid] = {"kind": trig[0], "round": trig[1], "first": now,
                                "fired": first_run, "pushed": False, "recalled": False}
        if not e["fired"]:
            delay = WAIT_DELAY if e["kind"] in URGENT_EVS else UNREAD_DELAY
            if now - e["first"] < delay:
                continue
            e["fired"] = True
            if _seen_ok(seen, sid, e):
                e["seen"] = True  # already seen in the app (viewing that session / the banner popped up before this)
            elif active:
                e["hold"] = now  # handed to the banner of the device in use, waiting for its report
                continue
            else:
                out.append(_show(s, sid, e, now, body_fn, pets))
                continue
        elif e.get("hold") is not None:
            if _seen_ok(seen, sid, e):
                e["hold"] = None
                e["seen"] = True
            elif not active or now - e["hold"] >= HOLD_MAX:  # not delivered: the device in use left / no report for 12 s
                e["hold"] = None
                out.append(_show(s, sid, e, now, body_fn, pets))
                continue
            else:
                continue
        # Once delivered (seen): if waiting / error is left unhandled and the user walks away, push once more after 2 minutes
        if e.get("seen") and not e.get("nagged") and e["kind"] in NAG_EVS:
            if active:
                e["away"] = None
            elif e.get("away") is None:
                e["away"] = now
            elif now - e["away"] >= NAG_AFTER:
                e["nagged"] = True
                out.append(_show(s, sid, e, now, body_fn, pets))
    for sid in [k for k in entries if k not in present]:  # session gone (off duty)
        _recall_if_needed(entries[sid], sid, out)
        del entries[sid]
    return {"init": True, "e": entries}, out


def new_link_gate() -> Dict[str, Any]:
    return {"hold": None, "sent": False}


def link_gate(g: Dict[str, Any], ev: Optional[str], act: Optional[Dict[str, Any]], stale: bool, down: bool,
              active: bool) -> Tuple[Dict[str, Any], List[Dict[str, Any]]]:
    """Mac disconnect / restore also honors in-use devices (admin only). ev/act: the event and action produced by link_step this round; stale: the snapshot is stale now;
    down: link_step's new state is still "disconnected" (pushed); active: admin has a device in use. Returns (new state, actions to send this round).
    If a device is in use at the moment of disconnect -> hold (the app already shows a grey page with the reason); push later only if still disconnected and all devices have left; restore is pushed only if a disconnect was actually pushed and nobody is using the app."""
    g = dict(g)
    out = []  # type: List[Dict[str, Any]]
    if ev == "down" and act is not None:
        if active:
            g["hold"] = act
        else:
            out.append(act)
            g["sent"] = True
    elif ev == "up" and act is not None:
        if g["sent"] and not active:
            out.append(act)
        g = new_link_gate()
    elif g["hold"] is not None and stale and not active:
        out.append(g["hold"])
        g["hold"], g["sent"] = None, True
    if not down:
        g = new_link_gate()
    return g, out


# ---------- Mac disconnected / restored (thresholds are a phone-side internal convention, not part of the snapshot contract) ----------
# A stale snapshot (helper not writing) for DOWN_AFTER seconds pushes "Mac disconnected" once, once per disconnect; after recovery it must stay fresh for UP_AFTER seconds to count as restored,
# and "Mac restored" is pushed only for disconnects lasting at least UP_PUSH_MIN seconds (same tag, replacing the disconnect one). A round in which the server itself just woke (woke: too long a gap between rounds, Mac lid closed) does not count.
# When the whole Mac sleeps / loses network the api container is down too and cannot push; known limitation.
DOWN_AFTER = 90
UP_AFTER = 10
UP_PUSH_MIN = 300
LINK_TAG = "mac-link"
BEAT_FRESH = 30  # written to the heartbeat file within this long counts as "helper still alive"


def new_link() -> Dict[str, Any]:
    return {"since": None, "pushed": False, "fresh": None}


def link_step(st: Dict[str, Any], now: float, stale: bool, woke: bool) -> Tuple[Dict[str, Any], Optional[str]]:
    """One round of disconnect judgement (pure function). st: since = when staleness was first noticed, pushed = whether a disconnect was pushed, fresh = when it became fresh again. Returns (new state, None/"down"/"up")."""
    st = dict(st)
    if woke:  # server just woke: this round is not a disconnect start; a pushed disconnect is kept so "restored" is pushed as usual on recovery
        return (st if st["pushed"] else new_link()), None
    if stale:
        st["fresh"] = None
        if st["since"] is None:
            st["since"] = now
            return st, None
        if not st["pushed"] and now - st["since"] >= DOWN_AFTER:
            st["pushed"] = True
            return st, "down"
        return st, None
    if st["since"] is None:
        return st, None
    if st["fresh"] is None:
        st["fresh"] = now
    if now - st["fresh"] < UP_AFTER:
        return st, None
    ev = "up" if st["pushed"] and st["fresh"] - st["since"] >= UP_PUSH_MIN else None
    return new_link(), ev


def down_reason(beat: Any, now: float) -> str:
    """Disconnect reason (helper heartbeat data/helper-beat.json {at, ok, err}): heartbeat fresh but dump failed -> panel (panel not responding);
    heartbeat also stale / missing -> helper (helper stopped)."""
    if isinstance(beat, dict):
        at = beat.get("at")
        if isinstance(at, (int, float)) and not isinstance(at, bool) and now - at <= BEAT_FRESH and beat.get("ok") is False:
            return "panel"
    return "helper"


def link_action(ev: str, reason: Optional[str], at: Optional[str]) -> Dict[str, Any]:
    """Actions for disconnect / restore pushes; title/body are Simplified (used in logs), and localize() recomposes them per subscription language."""
    act = {"kind": "show", "tag": LINK_TAG, "url": "/", "ev": "macDown" if ev == "down" else "macUp",
           "reason": reason, "at": at}
    act["title"], act["body"] = _link_text(act, "hans")
    return act


def _link_text(action: Dict[str, Any], lang: Any) -> Tuple[str, str]:
    if action.get("ev") == "macUp":
        return ptext("pushmsg.macUp", lang), ptext("pushmsg.macUpBody", lang)
    reason = ptext(LINK_REASON.get(str(action.get("reason") or ""), "pushmsg.reasonHelper"), lang)
    body = ptext("pushmsg.macDownBody", lang).replace("{reason}", reason).replace("{at}", str(action.get("at") or ""))
    return ptext("pushmsg.macDown", lang), body
