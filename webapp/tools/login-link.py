#!/usr/bin/env python3
"""Print the login link for an account: https://<host>:8443/#k=<key>.

The key sits in the URL fragment, which browsers never send to the server (no proxy logs, no Referer); the login page
reads it, removes it from the address bar and history, and logs in by POST.

Usage (repo root): python3 -I tools/login-link.py [account] [--host HOST] [--env PATH] [--no-qr]
  account  admin (default), guest, or a GUESTn_ID from .env
  --host   defaults to SITE_IP in .env
  --env    defaults to .env in the repo root

Keys are read from .env the same way the server reads them (WEBAPP_KEY, and guests via api.guestcfg.load_guests, so a guest the
server would disable is not offered here either). If the optional `qrcode` package is importable, a terminal QR code follows the
link. The key is only printed to stdout, never written anywhere else."""
import argparse
import os
import sys
from typing import Dict, Optional
from urllib.parse import quote

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)  # python3 -I leaves the script directory off sys.path
from api import guestcfg  # noqa: E402

PORT = 8443
KEY_MIN = 24  # same minimum as the server (api/server.py main)


def read_env(path: str) -> Dict[str, str]:
    """Minimal KEY=VALUE reader for the docker compose env_file: skips blank lines and # comments, drops an optional
    `export `, strips one pair of matching surrounding quotes."""
    out = {}  # type: Dict[str, str]
    with open(path, "r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            name, _, value = line.partition("=")
            name = name.strip()
            if name.startswith("export "):
                name = name[len("export "):].strip()
            value = value.strip()
            if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
                value = value[1:-1]
            out[name] = value
    return out


def account_key(environ: Dict[str, str], account: str) -> Optional[str]:
    admin = environ.get("WEBAPP_KEY", "")
    if len(admin) < KEY_MIN:
        raise SystemExit("WEBAPP_KEY is missing or too short in .env")
    if account == "admin":
        return admin
    for g in guestcfg.load_guests(admin, environ=environ):
        if g.account == account:
            return g.key
    return None


def login_link(host: str, key: str) -> str:
    return "https://%s:%d/#k=%s" % (host, PORT, quote(key, safe=""))


def print_qr(text: str) -> None:
    try:
        import qrcode  # optional, not a project dependency
    except ImportError:
        return
    qr = qrcode.QRCode(border=2)
    qr.add_data(text)
    qr.make(fit=True)
    print()
    qr.print_ascii(invert=True)


def main(argv: Optional[list] = None) -> int:
    ap = argparse.ArgumentParser(description="Print the #k= login link for an account.")
    ap.add_argument("account", nargs="?", default="admin")
    ap.add_argument("--host", help="host or IP in the link (default: SITE_IP from .env)")
    ap.add_argument("--env", default=os.path.join(ROOT, ".env"), help="path to .env (default: repo root .env)")
    ap.add_argument("--no-qr", action="store_true", help="do not print a QR code")
    args = ap.parse_args(argv)
    try:
        environ = read_env(args.env)
    except OSError as e:
        sys.stderr.write("cannot read %s: %s\n" % (args.env, e.strerror))
        return 2
    host = args.host or environ.get("SITE_IP", "")
    if not host:
        sys.stderr.write("no host: pass --host or set SITE_IP in .env\n")
        return 2
    key = account_key(environ, args.account)
    if key is None:
        names = ["admin"] + [g.account for g in guestcfg.load_guests(environ.get("WEBAPP_KEY", ""), environ=environ)]
        sys.stderr.write("unknown account %r; configured: %s\n" % (args.account, ", ".join(names)))
        return 2
    link = login_link(host, key)
    print(link)
    if not args.no_qr:
        print_qr(link)
    return 0


if __name__ == "__main__":
    sys.exit(main())
