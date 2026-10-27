"""Local test relay: http://127.0.0.1:8765 (DEV_PORT to change) -> https://<SITE_IP>:8443, adding the login cookie automatically. Binds 127.0.0.1 only.
TLS is verified against this deployment's Caddy root certificate (never disabled: the admin key goes over this link).
Export it once (repo root): docker compose exec -T caddy cat /data/caddy/pki/authorities/local/root.crt > data/ca.crt
Usage (repo root): set -a; . ./.env; set +a; /usr/bin/python3 -I tools/dev_proxy.py [--ca data/ca.crt], then open http://127.0.0.1:8765/ in Chrome.
The CA path can also come from DEV_CA; default is data/ca.crt.
Note: messages sent through it are really sent; use it only on test sessions."""
import argparse
import http.cookiejar
import http.server
import json
import os
import ssl
import sys
import urllib.error
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_CA = os.path.join(ROOT, "data", "ca.crt")
HOP = {"connection", "keep-alive", "transfer-encoding", "content-encoding", "content-length", "set-cookie", "strict-transport-security"}


def make_context(cafile):
    """Trust only this deployment's Caddy root certificate (chain and hostname/IP are both verified). Exit if none is given or the file is missing; never fall back to no verification."""
    cafile = cafile or os.environ.get("DEV_CA") or ""
    if not cafile or not os.path.isfile(cafile):
        sys.exit("dev_proxy: Caddy root certificate %r not found. Export it first: docker compose exec -T caddy cat "
                 "/data/caddy/pki/authorities/local/root.crt > data/ca.crt, or pass --ca / set DEV_CA" % cafile)
    ctx = ssl.create_default_context(cafile=cafile)  # CERT_REQUIRED + check_hostname (the Caddy certificate carries SITE_IP as an IP SAN)
    return ctx


def main():
    ap = argparse.ArgumentParser(description="Soulgent local test relay")
    ap.add_argument("--ca", help="Caddy root certificate (default: $DEV_CA or data/ca.crt)")
    args = ap.parse_args()
    # upstream address comes from SITE_IP in .env (run `. ./.env` first); a placeholder IP is used if unset
    up = "https://%s:8443" % (os.environ.get("SITE_IP") or "192.168.1.10")
    ctx = make_context(args.ca or os.environ.get("DEV_CA") or DEFAULT_CA)
    jar = http.cookiejar.CookieJar()
    op = urllib.request.build_opener(urllib.request.HTTPSHandler(context=ctx), urllib.request.HTTPCookieProcessor(jar))
    op.open(urllib.request.Request(up + "/api/auth", data=json.dumps({"key": os.environ["WEBAPP_KEY"]}).encode(),
                                   headers={"Content-Type": "application/json"}, method="POST"))

    class H(http.server.BaseHTTPRequestHandler):
        def _go(self, method):
            n = int(self.headers.get("Content-Length") or 0)
            body = self.rfile.read(n) if n else None
            hd = {k: v for k, v in self.headers.items() if k.lower() in ("content-type", "accept")}
            req = urllib.request.Request(up + self.path, data=body, headers=hd, method=method)
            try:
                r = op.open(req, timeout=40)
                code, data, rh = r.status, r.read(), r.headers
            except urllib.error.HTTPError as e:
                code, data, rh = e.code, e.read(), e.headers
            self.send_response(code)
            for k, v in rh.items():
                if k.lower() not in HOP:
                    self.send_header(k, v)
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def do_GET(self):
            self._go("GET")

        def do_POST(self):
            self._go("POST")

        def do_DELETE(self):
            self._go("DELETE")

        def log_message(self, *a):
            pass

    http.server.ThreadingHTTPServer(("127.0.0.1", int(os.environ.get("DEV_PORT", "8765"))), H).serve_forever()


if __name__ == "__main__":
    main()
