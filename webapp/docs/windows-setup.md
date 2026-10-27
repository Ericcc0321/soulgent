# Using Soulgent on a Windows PC (for guests)

English | [简体中文](windows-setup.zh-CN.md)

You only need to do this once, and it takes about 3 minutes. Your PC must be on the same network as the Mac that runs Soulgent App.
Your admin will send you the sign-in key and the `<SITE_IP>` used in the addresses below (the Mac's LAN address, i.e. the value of `SITE_IP` in `webapp/.env`, for example `192.168.1.10`). The key is not written in this document.

## Step 1: Install the certificate (so your browser trusts the site)

A root certificate can vouch for any website, so only install the one your admin gave you, and check its fingerprint first. Do **not** download it by clicking past a browser security warning: on a shared network someone could hand you their own certificate.

1. Get `ca.crt` from your admin over a trusted channel: a USB stick, a file share you already trust, or your usual chat app, together with its **SHA-256 fingerprint** (sent separately, for example read out in person or in a chat message). The admin exports both on the Mac, inside `webapp/`:
   ```bash
   docker compose exec -T caddy cat /data/caddy/pki/authorities/local/root.crt > ca.crt
   openssl x509 -in ca.crt -noout -fingerprint -sha256
   ```
2. Check the fingerprint on Windows: open PowerShell in the folder with `ca.crt` and run
   ```powershell
   $c = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 (Resolve-Path .\ca.crt)
   [BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash($c.RawData))
   ```
   Compare the result with the admin's fingerprint (ignore `-` and `:`; every character must match). Don't use the "Thumbprint" shown in the certificate window: that is SHA-1 and will never match. If it differs, stop and ask your admin.
3. Double-click `ca.crt` and click "Install Certificate".
4. Under "Store Location", choose **Local Machine** and click "Next" (if Windows asks whether to allow changes, click "Yes").
5. Choose **Place all certificates in the following store**, click "Browse", select **Trusted Root Certification Authorities**, then click "OK" → "Next".
6. Click "Finish". When you see "The import was successful", you're done.
7. **Close every browser window, then open the browser again.**

## Step 2: Sign in

1. Open `https://<SITE_IP>:8443/` (if the address bar no longer says "Not secure", the certificate is installed correctly).
2. Paste the key your admin gave you and click Sign in. The browser remembers you, so you won't need to enter it again.

## Optional: install as a desktop app and turn on notifications

- **Install as a desktop app** (open it from the desktop or Start menu like any other program):
  - Edge: click "…" in the top-right corner → "Apps" → "Install this site as an app".
  - Chrome: click the "Install" icon on the right side of the address bar (or "⋮" in the top-right corner → "Cast, save, and share" → "Install page as app").
- **Turn on notifications**: in Soulgent, click "Me" on the left → "Notifications" → turn it on, then click "Allow" when the browser asks.

## Tips

- Press Enter to send and Shift + Enter for a new line.
- After taking or copying a screenshot, press Ctrl + V in a chat to paste it as an attachment, or drag files into the chat window. You can send up to 9 attachments at a time, together with your text.
