# iPhone One-Time Setup (Soulgent)

English | [简体中文](iphone-setup.zh-CN.md)

Before you start: the iPhone and this Mac must be on the same network. In the steps below, `<SITE_IP>` is the Mac's LAN address, i.e. the value of `SITE_IP` in `webapp/.env` (for example `192.168.1.10`).
The key lives in `webapp/.env` (in the repository folder on the Mac), under the variable `WEBAPP_KEY` (the key itself is not written in this document). The sign-in page only says "No key? Ask the admin for one"; it does not reveal where keys are stored, so as the admin, hand out the keys yourself.

**Get the root certificate over a trusted channel and check its fingerprint first.** Installing a root certificate lets it vouch for any website, so never install one you downloaded over the network without checking it: on a shared Wi-Fi someone could swap in their own.

On the Mac (admin), inside `webapp/`, export the certificate and print its SHA-256 fingerprint:

```bash
docker compose exec -T caddy cat /data/caddy/pki/authorities/local/root.crt > ca.crt
openssl x509 -in ca.crt -noout -fingerprint -sha256
```

Write the fingerprint down (or send it to guests over a channel you already trust, such as in person or your usual chat app). It stays the same unless the `caddy_data` volume is deleted.

1. AirDrop `ca.crt` from the Mac to the iPhone (or send it over another trusted channel) and tap "Allow" when it says the profile was downloaded. Downloading `https://<SITE_IP>:8443/ca.crt` in Safari also works, but then the fingerprint check in the next step is what protects you.
2. Go to Settings › Profile Downloaded. **Before tapping Install**, tap "More Details", tap the certificate, and compare the **SHA-256** value under Fingerprints with the one from the Mac (all characters must match; spaces/colons don't matter). If it differs, tap Remove and ask the admin. If it matches, go back and tap Install (enter your passcode when asked).
3. Go to Settings › General › About › Certificate Trust Settings and turn on full trust for the Caddy Local Authority root certificate you just installed.
4. In Safari, open the login link: `https://<SITE_IP>:8443/#k=<WEBAPP_KEY from webapp/.env>`. On the Mac, `python3 -I tools/login-link.py` (in `webapp/`) prints this link, and a QR code to scan with the iPhone camera if the `qrcode` Python package is installed; pass a guest's account name (`guest`, or a `GUESTn_ID`) to get that guest's link. The key comes after `#`, so it is never sent as a URL parameter and stays out of ordinary access logs; at login the page submits it over HTTPS (POST) to your own API. Once it works you are taken to the home page and stay signed in: this device keeps its sign-in as long as it is used at least once every 90 days (there is no fixed maximum; the cookie is renewed while in use). Signing this device out in Me, or changing the key, ends it. Old links of the form `/?key=...` still work for now, but show a notice that the link is outdated; ask for a new one.
5. Tap the Share button › Add to Home Screen.
6. The first time you open it from the Home Screen icon, you will see the sign-in page, because the Home Screen app keeps its sign-in separate from Safari. Paste `WEBAPP_KEY` and you're in.

Notes:
- Guests: do the same steps, but use the guest key your admin sends you (each guest has their own; it is `GUEST_KEY` / `GUESTn_KEY` in `webapp/.env`) wherever `WEBAPP_KEY` is mentioned. A guest only sees the one chat assigned to them.
- You can also use `https://<SITE_HOST>:8443/` (the value of `SITE_HOST` in `webapp/.env`, for example `your-mac.local`), but `.local` names rely on mDNS and don't resolve on some networks, so prefer the IP.
- If the Mac's wired IP changes: update `SITE_IP` in `webapp/.env` and run `docker compose up -d` inside `webapp/` (Caddy re-issues the server certificate automatically). On the iPhone, open the new address, Add to Home Screen again, and paste the key once more. The root certificate stays the same; you only need to reinstall it on the iPhone if the `caddy_data` volume is deleted.
