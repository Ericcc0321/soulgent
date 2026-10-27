#!/usr/bin/env python3
"""Generate VAPID keys and add them to the given .env (left alone if already filled in; empty VAPID_*= lines copied
from .env.example are replaced). Prints only added / already present, never the keys.

Usage: VAPID_SUBJECT=mailto:you@example.com python3 tools/gen_vapid.py /path/to/.env (without VAPID_SUBJECT a placeholder address is used)
Requires cryptography (pip install cryptography).
"""
import base64
import os
import sys

# VAPID_SUBJECT written to .env comes from the environment (e.g. VAPID_SUBJECT=mailto:you@example.com python3 tools/gen_vapid.py .env);
# if unset, a placeholder address is written; edit .env afterwards
SUBJECT = os.environ.get("VAPID_SUBJECT") or "mailto:admin@example.com"
NAMES = ("VAPID_PRIVATE_KEY", "VAPID_PUBLIC_KEY", "VAPID_SUBJECT")


def b64url(b: bytes) -> str:
    return base64.urlsafe_b64encode(b).rstrip(b"=").decode("ascii")


def generate():
    from cryptography.hazmat.primitives import serialization
    from cryptography.hazmat.primitives.asymmetric import ec
    key = ec.generate_private_key(ec.SECP256R1())
    raw_priv = key.private_numbers().private_value.to_bytes(32, "big")
    pub = key.public_key().public_bytes(serialization.Encoding.X962,
                                        serialization.PublicFormat.UncompressedPoint)
    return b64url(raw_priv), b64url(pub)


def present(text: str) -> set:
    """Names of VAPID_* entries that have a value (empty VAPID_*= lines copied from .env.example do not count)."""
    found = set()
    for line in text.splitlines():
        name, sep, value = line.partition("=")
        if sep and name.strip() in NAMES and value.strip().strip('"').strip("'"):
            found.add(name.strip())
    return found


def drop_empty(text: str) -> str:
    """Remove empty VAPID_* lines (real values are appended afterwards; otherwise .env would hold two lines with the same name and docker compose may pick either)."""
    keep = []
    for line in text.splitlines(True):
        name, sep, value = line.partition("=")
        if sep and name.strip() in NAMES and not value.strip().strip('"').strip("'"):
            continue
        keep.append(line)
    return "".join(keep)


def main(argv) -> int:
    if len(argv) != 2:
        print("usage: gen_vapid.py <path to .env>", file=sys.stderr)
        return 2
    path = argv[1]
    try:
        with open(path, "r", encoding="utf-8") as f:
            text = f.read()
    except FileNotFoundError:
        text = ""
    have = present(text)
    if "VAPID_PRIVATE_KEY" in have or "VAPID_PUBLIC_KEY" in have:
        # private and public keys must come as a pair; never fill in just one
        if not {"VAPID_PRIVATE_KEY", "VAPID_PUBLIC_KEY"} <= have:
            print("error: only one of the private/public key is present; fix it manually", file=sys.stderr)
            return 1
        lines = []
    else:
        priv, pub = generate()
        lines = ["VAPID_PRIVATE_KEY=" + priv, "VAPID_PUBLIC_KEY=" + pub]
    if "VAPID_SUBJECT" not in have:
        lines.append("VAPID_SUBJECT=" + SUBJECT)
    if not lines:
        print("already present")
        return 0
    text = drop_empty(text)
    prefix = "" if not text or text.endswith("\n") else "\n"
    tmp = path + ".tmp-gen-vapid"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.write(text + prefix + "\n".join(lines) + "\n")
    os.replace(tmp, path)
    print("added")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
