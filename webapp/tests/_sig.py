"""Outbox signing for tests: sets OUTBOX_SECRET (api and helper both read the env var at call time) and signs hand-written request/result files.
Takes effect on import; signing matches api/outbox.py and helper/outbox.py (HMAC-SHA256 over domain + compact JSON)."""
import hashlib
import hmac
import json
import os

SECRET = "t" * 40
os.environ["OUTBOX_SECRET"] = SECRET


def _sign(domain, obj):
    body = {k: v for k, v in obj.items() if k != "sig"}
    raw = (domain + "\n" + json.dumps(body, sort_keys=True, ensure_ascii=False, separators=(",", ":"))).encode("utf-8")
    out = dict(obj)
    out["sig"] = hmac.new(SECRET.encode("utf-8"), raw, hashlib.sha256).hexdigest()
    return out


def req(obj, rid=None, account="admin"):
    """Request file content (as the api writes it): fills in id (when rid is given) and account (default admin), then signs."""
    obj = dict(obj)
    if rid is not None:
        obj.setdefault("id", rid)
    if account is not None:
        obj.setdefault("account", account)
    return _sign("req", obj)


def res(obj):
    """Result file content (as the helper writes it)."""
    return _sign("res", obj)
