# Soulgent App

English | [简体中文](#简体中文)

Soulgent App is a phone-friendly web page for watching and chatting with your Claude Code sessions from an iPhone on the same LAN; its chat page is called SoulChat. It runs on your Mac in Docker (an API container plus a Caddy HTTPS reverse proxy), plus a small launchd helper that reads session data on the Mac.

## What you need

1. **Docker Desktop** on the Mac (Compose v2).
2. **Soulgent for Mac** (`Soulgent.app`). The helper looks for it at `../app/Soulgent.app`, `/Applications`, then `~/Applications`; set `SOULGENT_PANEL` if it lives elsewhere.
3. **The helper launchd service**: run `bash helper/install.sh` on the Mac (remove with `helper/uninstall.sh`). Restart it after changing helper-related `.env` values.
4. Claude Code sessions on the Mac (config dir `~/.claude` by default). See `docs/dependencies.md` for what is read and what happens when something is missing.

**Optional: status line.** The context ring, model / effort / t/s and the 5-hour / 7-day quota numbers on the chat page come from files written by a Claude Code status line script; without one they stay empty. A minimal script is in `examples/statusline/`; set it up as described in `examples/statusline/README.md`.

## Configure `.env`

Copy `.env.example` to `.env` and fill it in. `.env` is never committed. Names and purposes only (values are examples):

| Variable | Purpose |
|---|---|
| `WEBAPP_KEY` | Admin sign-in key, 24+ chars (e.g. generated with `openssl rand -hex 24`). Required. |
| `SITE_HOST` | The Mac's `.local` name, put into the certificate (e.g. `your-mac.local`). |
| `SITE_IP` | The Mac's LAN IP; Caddy listens on this address, port 8443 (e.g. `192.168.1.10`). |
| `OUTBOX_SECRET` | Shared secret (32+ chars) the api and the helper use to sign request/result files; generate with `python3 -c 'import secrets;print(secrets.token_hex(32))'`. Required: without it nothing can be sent. |
| `COMPOSE_PROJECT_NAME` | Optional compose project name (default `soulgent`). |
| `VAPID_PRIVATE_KEY`, `VAPID_PUBLIC_KEY`, `VAPID_SUBJECT` | Web Push keys (generate with `VAPID_SUBJECT=mailto:you@example.com python3 tools/gen_vapid.py .env`; needs `python3 -m pip install --user cryptography` on the Mac) and a contact such as `mailto:you@example.com`. |
| `GUEST_KEY`, `GUEST_SESSION`, `GUEST_NAME`, `GUEST_TAG` | Optional first guest: own key, the one session they may see, default nickname, and message prefix. |
| `GUEST_SLASH_COMMANDS` | Optional comma-separated slash commands guests may send (e.g. `/window`, a custom window-handoff command; empty = none). |
| `GUEST2_ID`, `GUEST2_KEY`, `GUEST2_SESSION`, `GUEST2_TAG`, `GUEST2_NAME` (up to `GUEST9_*`) | Optional more guests; each is isolated from the others. |
| `ADMIN_ONLY_PREFIXES` | Optional comma-separated path prefixes guests get 403 on (private reverse proxies in `caddy-private/`). |
| `FILE_ROOTS` | Optional extra host directories the phone may open (`host-path=container-path`, colon separated); must match mounts in `docker-compose.override.yml` (see the `.example`). |
| `SOULGENT_PANEL` | Path to `Soulgent.app` if not in the default places. |
| `SOULGENT_PANEL_DOMAIN` | UserDefaults domain of the Mac app (only change it if the app's bundle ID differs). |
| `SOULGENT_HELPER_LABEL` | launchd label of the helper. |
| `SOULGENT_CLAUDE_DIR`, `SOULGENT_WORKZONES`, `SOULGENT_ROSTER`, `SOULGENT_LINEAGE`, `SOULGENT_OFFDUTY` | Where the helper finds the Claude Code config dir, zone table, off-duty roster, window lineage and off-duty script. |
| `SOULGENT_STATUSLINE_DIR`, `SOULGENT_ORCA_BIN`, `SOULGENT_ORCA_STATS_DIR`, `SOULGENT_CLAUDE_BIN`, `SOULGENT_PETDEX_DIR`, `SOULGENT_ZONE_STYLE` | Optional locations of statusline metadata, `orca`, Orca data, `claude`, Petdex pets and zone styles. |

Optional fields of a zone entry in `workzones.json` (`zones.<code>`):

| Field | Purpose |
|---|---|
| `short`, `fx` | Short badge name and avatar effect (can also live in the `SOULGENT_ZONE_STYLE` file). |
| `taskboard` | Optional path to a Markdown file shown on the zone's board card (max 20 KB; may start with `~/`). Without it the card shows no task board. |

## Start

```bash
cp .env.example .env     # then edit it
docker compose up -d
bash helper/install.sh   # the launchd helper
/usr/bin/python3 -m pip install --user Pillow   # once: the pet slicer runs on the Mac's own Python
/usr/bin/python3 tools/build_pets.py            # slice installed Petdex pets into data/pets/
```

Without the last two steps every avatar falls back to the built-in Soulgent flame. Re-run `build_pets.py` after installing new pets; details in [docs/pets.md](docs/pets.md).

If the Mac's IP changes, update `SITE_IP` and run `docker compose up -d` again.

## Security model

Read this before you hand out a key.

- **The admin key is roughly a shell on this Mac.** Text you send goes into the Claude Code terminal as typed, and a line starting with `!` is run by Claude Code as a bash command. Anyone holding `WEBAPP_KEY` can do whatever you can do in that terminal.
- **Keep it on your LAN.** The site listens only on `SITE_IP` (the Mac's wired address). Do not port-forward it or expose it to the internet.
- **A guest talks to its bound session with your permissions.** Guest messages get a name prefix, so they cannot start with `!`; a guest can send only the slash commands you list in `GUEST_SLASH_COMMANDS` (none by default), and guests cannot answer prompts or approve tools. But the agent still acts on what a guest asks, using your account. Bind guests only to sessions you would let that person steer, and avoid sessions that auto-approve tools.
- **Trusting the root certificate.** Full trust for the Caddy Local Authority lets that CA vouch for any website on that phone. Its private key lives in the `caddy_data` Docker volume on the Mac. Install it only on your own devices (and your guests' on theirs), and remove the profile if you stop using Soulgent App.
- **Each device gets its own sign-in.** Logging in issues a random per-device token (cookie lifetime about 400 days, refreshed while in use); the server keeps only its hash in `/state/devices.json` (the `state` volume), and a token unused for 90 days stops working. Me > Where you're signed in lists your own devices and signs any of them out. If a phone is lost, sign it out there, or change `WEBAPP_KEY` (or that guest's `GUEST_KEY`) in `.env` and run `docker compose up -d` to sign out every device of that account. Cookies from older versions (derived from the key) still work for now and are swapped for a device token on next use.
- **Push notifications** are end-to-end encrypted to each device and delivered through Apple, Google or Mozilla push services, which see only that a message was sent, not its content.

## iPhone: trust the root certificate and add to Home Screen

Full steps are in `docs/iphone-setup.md`. In short, with the iPhone on the same network:

1. On the Mac export the root certificate and note its SHA-256 fingerprint: `docker compose exec -T caddy cat /data/caddy/pki/authorities/local/root.crt > ca.crt`, then `openssl x509 -in ca.crt -noout -fingerprint -sha256`. AirDrop `ca.crt` to the iPhone.
2. Settings > Profile Downloaded > More Details: check the SHA-256 fingerprint matches, then Install.
3. Settings > General > About > Certificate Trust Settings: enable full trust for the Caddy Local Authority root certificate.
4. Open the login link in Safari: `https://<SITE_IP>:8443/#k=<your WEBAPP_KEY>`. `python3 -I tools/login-link.py [account]` prints it for `admin` (default) or a guest, plus a QR code if the `qrcode` package is installed. The key sits after `#`, so it is never sent as a URL parameter and stays out of ordinary access logs; at login the page submits it over HTTPS (POST) to your own API. Old `?key=` links still work for now but show an "outdated link" notice.
5. Share > Add to Home Screen. The first launch from the icon asks for the key again (the Home Screen app has its own sign-in).

Guests do the same with their own key. Windows guests: see `docs/windows-setup.md`.

## Tests

```bash
python3 -m unittest discover -s tests -t . && node --test web/tests/*.test.mjs && node tools/render-check/run.mjs
```

The last one drives the real frontend in headless Chrome (needs Google Chrome) and takes about ten minutes; see `tools/render-check/README.md`.

---

## 简体中文

Soulgent App：手机上看和聊 Claude Code 会话的网页，里面的聊天页叫 SoulChat。跑在 Mac 的 Docker 里（API 容器加 Caddy HTTPS 反代），另有一个 launchd 小帮手在 Mac 上读会话数据。

**要装什么**：Docker Desktop；Soulgent for Mac（`Soulgent.app`，默认在 `../app/`、`/Applications`、`~/Applications` 里找，位置不同用 `SOULGENT_PANEL` 指定）；小帮手 launchd 服务（`bash helper/install.sh`，卸载用 `helper/uninstall.sh`，改了小帮手相关配置要重启）。依赖详情见 `docs/dependencies.zh-CN.md`。不装状态栏脚本，聊天页的上下文环和额度数字不会显示；要显示就按 `examples/statusline/README.md` 配置。

**配置 `.env`**：把 `.env.example` 复制成 `.env` 再填，变量名和用途见上面英文表（`WEBAPP_KEY` 管理员密钥；`OUTBOX_SECRET` api 与小帮手之间的签名密钥（必填，至少 32 个字符）；`SITE_HOST`/`SITE_IP` 证书与监听地址；`VAPID_*` 推送（`VAPID_SUBJECT=mailto:you@example.com python3 tools/gen_vapid.py .env` 生成，宿主要先 `python3 -m pip install --user cryptography`）；`GUEST_*`/`GUEST2_*…` 访客；`ADMIN_ONLY_PREFIXES` 私有反代；`FILE_ROOTS` 额外附件目录；`SOULGENT_*` 小帮手读的各种外部位置）。`.env` 里的密钥不要提交。

`workzones.json` 里每个工区（`zones.<代号>`）的可选字段：`short`、`fx`（徽章简称、头像特效，也可放在 `SOULGENT_ZONE_STYLE` 文件里）；`taskboard`（可选，一个 Markdown 文件的路径，显示在该工区的看板卡上，最大 20 KB，可以用 `~/` 开头；不配的话卡片上不显示任务板）。

**启动**：`docker compose up -d`，再 `bash helper/install.sh`。然后切宠物图：先 `/usr/bin/python3 -m pip install --user Pillow`（只需一次，切图跑在 Mac 自带的 Python 上），再 `/usr/bin/python3 tools/build_pets.py`，把已装的 Petdex 宠物切进 `data/pets/`；不做这两步，头像全是内置灵火。装了新宠物后重跑 `build_pets.py`，详见 [docs/pets.zh-CN.md](docs/pets.zh-CN.md)。Mac 的 IP 变了就改 `SITE_IP` 后重跑 `docker compose up -d`。

**安全模型**（发密钥给别人之前先看）：管理员密钥约等于这台 Mac 的终端权限，发出的文字原样进 Claude Code 终端，以 `!` 开头的一行会被当成 bash 命令执行，拿到 `WEBAPP_KEY` 的人能做你在终端里能做的事。只在局域网里用：网站只监听 `SITE_IP`（Mac 的有线地址），不要做端口转发、不要暴露到公网。访客是用你的权限和它绑定的会话对话：访客的话会自动加名字前缀，不能以 `!` 开头，斜杠命令只允许 `.env` 里 `GUEST_SLASH_COMMANDS` 列出的（默认一个都不允许），也不能作答或批准工具，但 Agent 仍会按访客的要求、用你的账号去做事，所以只把访客绑到你愿意让这个人指挥的会话，避开自动批准工具的会话。iPhone 完全信任 Caddy 本地根证书后，这个证书可以为这台手机上的任何网站作保，它的私钥在 Mac 的 Docker 卷 `caddy_data` 里；只装在自己（和访客自己）的设备上，不用 Soulgent App 了就删掉描述文件。每台设备单独登录：登录时发一个随机的设备令牌（cookie 约 400 天，使用中自动续期），服务器只在 `state` 卷的 `/state/devices.json` 存它的哈希，90 天没用就失效；「我」页的「登录管理（各设备）」能看到自己账号的设备并逐台退出。手机丢了，在那里让它退出；或在 `.env` 里换掉 `WEBAPP_KEY`（或那个访客的 `GUEST_KEY`）再 `docker compose up -d`，这个账号的设备全部退出。旧版本由密钥算出的 cookie 暂时仍可用，下次使用时自动换成设备令牌。推送内容对每台设备端到端加密，经 Apple、Google 或 Mozilla 的推送服务送达，它们只知道发了一条消息，看不到内容。

**iPhone**：先在 Mac 上导出根证书并记下 SHA-256 指纹（命令见 `docs/iphone-setup.zh-CN.md`），AirDrop 到 iPhone > 设置 › 已下载描述文件 › 更多详细信息里核对 SHA-256 指纹一致再安装 > 通用 > 关于本机 > 证书信任设置，打开 Caddy Local Authority 根证书的完全信任 > 用 `https://<SITE_IP>:8443/#k=<密钥>` 登录（`python3 -I tools/login-link.py [账号]` 打印 `admin` 或访客的登录链接，装了 `qrcode` 包还会打印二维码；密钥在 `#` 后面，不会作为 URL 参数发送、不进常规访问日志，登录时经 HTTPS POST 提交给你自己的 API；旧的 `?key=` 链接暂时还能用，但会提示链接已过时） > 分享 > 添加到主屏幕（从图标首次打开要再输一次密钥）。详见 `docs/iphone-setup.zh-CN.md`。Windows 访客见 `docs/windows-setup.zh-CN.md`。

**测试**：`python3 -m unittest discover -s tests -t . && node --test web/tests/*.test.mjs && node tools/render-check/run.mjs`。最后一项用无头 Chrome 跑真实前端（需要装 Google Chrome），约十分钟，见 `tools/render-check/README.md`。
