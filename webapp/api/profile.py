"""Admin "Me" nickname and avatar, stored in the state volume: profile.json {name, v} and avatar.jpg (the phone shrinks it to a 160x160 JPEG first).
The guest has its own profile-<store>.json / avatar-<store>.jpg (store name: see guestcfg.store_id).
The guest's default nickname is not hard-coded: it comes from GUEST_NAME in .env (built-in fallback GUEST_NAME below);
GET returns it as default so the frontend can use it as a placeholder."""
import base64
import binascii
import json
import os
import re
import tempfile
import threading
from typing import Any, Dict, Optional

DEFAULT_NAME = ""  # an unchanged nickname is the empty string; the frontend shows "Me" per language (legacy saved values "我" are still recognized by the frontend)
GUEST_NAME = "访客"  # fallback default nickname for guests; the actual value comes from guest_name() reading GUEST_NAME in .env
NAME_MAX = 20
AVATAR_MAX = 40 * 1024  # a 160x160 JPEG is typically 5-15KB
_BAD_NAME = re.compile(r"[\x00-\x1f\x7f]")


class BadInput(ValueError):
    pass


def clean_name(v: Any, default: str = DEFAULT_NAME) -> str:
    if not isinstance(v, str) or _BAD_NAME.search(v):
        raise BadInput("bad name")
    v = v.strip()
    if len(v) > NAME_MAX:
        raise BadInput("name too long")
    return v or default


def guest_name(env: Optional[Dict[str, str]] = None) -> str:
    """Default guest nickname. If GUEST_NAME is invalid after stripping (empty, too long, control characters), use the default "访客"."""
    env = os.environ if env is None else env
    return guest_name_of(env.get("GUEST_NAME") or "")


def guest_name_of(v: Any) -> str:
    """Default nickname for one guest (the value of GUEST_NAME / GUESTn_NAME); invalid values use the default "访客"."""
    try:
        return clean_name(v if isinstance(v, str) else "", GUEST_NAME)
    except BadInput:
        return GUEST_NAME


def decode_avatar(v: Any) -> bytes:
    if not isinstance(v, str):
        raise BadInput("bad avatar")
    if v.startswith("data:"):  # also accepts data:image/jpeg;base64,...
        v = v.split(",", 1)[-1]
    if len(v) > AVATAR_MAX * 4 // 3 + 8:
        raise BadInput("avatar too large")
    try:
        data = base64.b64decode(v, validate=True)
    except (binascii.Error, ValueError):
        raise BadInput("bad avatar")
    if len(data) > AVATAR_MAX:
        raise BadInput("avatar too large")
    if not data.startswith(b"\xff\xd8\xff"):
        raise BadInput("not jpeg")
    return data


class ProfileStore:
    def __init__(self, folder: str, suffix: str = "", default_name: str = DEFAULT_NAME) -> None:
        self.dir = folder
        self.default_name = default_name
        self.json_path = os.path.join(folder, "profile%s.json" % suffix)
        self.avatar_path = os.path.join(folder, "avatar%s.jpg" % suffix)
        self._lock = threading.Lock()

    def _load(self) -> Dict[str, Any]:
        try:
            with open(self.json_path, "r", encoding="utf-8") as f:
                d = json.load(f)
            return d if isinstance(d, dict) else {}
        except (OSError, ValueError):
            return {}

    def get(self) -> Dict[str, Any]:
        d = self._load()
        name = d.get("name") if isinstance(d.get("name"), str) and d.get("name") else self.default_name
        has = os.path.isfile(self.avatar_path)
        v = int(d.get("v") or 0) if has else 0
        return {"name": name, "avatar": has, "v": v, "default": self.default_name}

    def avatar(self) -> Optional[bytes]:
        try:
            with open(self.avatar_path, "rb") as f:
                return f.read(AVATAR_MAX + 1)
        except OSError:
            return None

    def _write(self, path: str, data: bytes) -> None:
        os.makedirs(self.dir, exist_ok=True)
        fd, tmp = tempfile.mkstemp(dir=self.dir, prefix=".pf-")
        try:
            with os.fdopen(fd, "wb") as f:
                f.write(data)
            os.replace(tmp, path)
        except OSError:
            try:
                os.unlink(tmp)
            except OSError:
                pass
            raise

    def update(self, body: Dict[str, Any], now: float) -> Dict[str, Any]:
        """body: name (optional; empty = back to default), avatar (optional: base64 JPEG; null = delete). Validate everything first, then write."""
        name = clean_name(body["name"], self.default_name) if "name" in body else None
        pic = None
        clear = False
        if "avatar" in body:
            if body["avatar"] is None:
                clear = True
            else:
                pic = decode_avatar(body["avatar"])
        with self._lock:
            d = self._load()
            if pic is not None:
                self._write(self.avatar_path, pic)
                d["v"] = int(now * 1000)
            elif clear:
                try:
                    os.unlink(self.avatar_path)
                except FileNotFoundError:
                    pass
                d["v"] = 0
            if name is not None:
                d["name"] = name
            self._write(self.json_path, json.dumps(d, ensure_ascii=False).encode("utf-8"))
        return self.get()
