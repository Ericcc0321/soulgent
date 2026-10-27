# iPhone 一次性设置（Soulgent）

[English](iphone-setup.md) | 简体中文

前提：iPhone 与这台 Mac 在同一网络。下文的 `<SITE_IP>` 是 Mac 的局域网地址，即 `webapp/.env` 里 `SITE_IP` 的值（例如 `192.168.1.10`）。
密钥在 Mac 上仓库目录的 `webapp/.env` 文件里，变量名 `WEBAPP_KEY`（本文不记录密钥本身）。登录页只提示"没有密钥？请向管理员索取"，不会透露密钥存在哪里，所以密钥由管理员自己发给使用者。

**根证书要走可信渠道拿，装之前先核对指纹。** 根证书装上后能为任何网站作保，所以不要不加核对就装从网络上下载来的：在共用的 Wi-Fi 上有人可以把它换成自己的。

在 Mac 上（管理员），在 `webapp/` 目录里导出证书并打印 SHA-256 指纹：

```bash
docker compose exec -T caddy cat /data/caddy/pki/authorities/local/root.crt > ca.crt
openssl x509 -in ca.crt -noout -fingerprint -sha256
```

把指纹记下来（发给访客时，走当面、平时用的聊天软件这类本来就可信的渠道）。只要 `caddy_data` 卷不删，指纹就不会变。

1. 用 AirDrop 把 Mac 上的 `ca.crt` 传到 iPhone（或其他可信渠道），提示已下载描述文件时点"允许"。用 Safari 打开 `https://<SITE_IP>:8443/ca.crt` 下载也可以，但那样就全靠下一步的指纹核对来把关。
2. 设置 › 已下载描述文件。**先别点安装**：点"更多详细信息"，点进证书，把"指纹"下面 **SHA-256** 的值和 Mac 上打印的逐位对一遍（空格、冒号不算）。对不上就点"移除"并联系管理员；对上了再返回点"安装"（按提示输入锁屏密码）。
3. 设置 › 通用 › 关于本机 › 证书信任设置，把刚装的 Caddy Local Authority 根证书打开完全信任。
4. Safari 打开登录链接：`https://<SITE_IP>:8443/#k=<webapp/.env 里的 WEBAPP_KEY>`。在 Mac 的 `webapp/` 目录里运行 `python3 -I tools/login-link.py` 会打印这条链接；装了 Python 的 `qrcode` 包还会打印二维码，用 iPhone 相机扫即可；要访客的链接就加上访客账号名（`guest` 或 `GUESTn_ID`）。密钥在 `#` 后面，不会作为 URL 参数发送、不进常规访问日志；登录时经 HTTPS POST 提交给你自己的 API。成功后会自动跳到主页，并记住登录：这台设备只要每 90 天内用过一次就一直有效（没有固定的最长期限，使用中 cookie 自动续期）；在「我」页退出这台设备或换密钥后失效。旧的 `/?key=...` 链接暂时还能用，但会提示链接已过时，请索取新链接。
5. 点分享按钮 › 添加到主屏幕。
6. 从主屏幕图标首次打开时，主屏幕 App 的登录状态与 Safari 分开，会出现登录页，粘贴 `WEBAPP_KEY` 即可。

备注：
- 访客：步骤相同，凡是写 `WEBAPP_KEY` 的地方换成管理员单独发给您的访客密钥（每个访客一把，即 `webapp/.env` 里的 `GUEST_KEY` / `GUESTn_KEY`）。访客只看得到分给自己的那一个会话。
- 也可用 `https://<SITE_HOST>:8443/`（`webapp/.env` 里 `SITE_HOST` 的值，例如 `your-mac.local`），但 `.local` 名字依赖 mDNS，在部分网络里解析不到，优先用 IP。
- 若 Mac 的有线 IP 变了：改 `webapp/.env` 的 `SITE_IP`，在 `webapp/` 目录里执行 `docker compose up -d`（Caddy 会自动重签服务器证书）；iPhone 上用新地址重新"添加到主屏幕"，并粘贴一次密钥。根证书不变，只有 `caddy_data` 卷被删掉时才需要在 iPhone 上重装。
