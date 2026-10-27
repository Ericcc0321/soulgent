# 在 Windows 电脑上使用 Soulgent（给访客）

[English](windows-setup.md) | 简体中文

只需要设置一次，大约 3 分钟。电脑要和运行 Soulgent App 的那台 Mac 在同一个网络里。
登录密钥和网址里的 `<SITE_IP>`（Mac 的局域网地址，即 `webapp/.env` 里 `SITE_IP` 的值，例如 `192.168.1.10`）由管理员单独发给您（本文不写密钥）。

## 第一步：安装证书（让浏览器信任这个网站）

根证书装上后能为任何网站作保，所以只装管理员给您的那一份，并且装之前先核对指纹。**不要**点掉浏览器的安全警告去下载：在共用的网络里，有人可以塞给您他自己的证书。

1. 从管理员那里经可信渠道拿到 `ca.crt`：U 盘、本来就信得过的共享文件夹、平时用的聊天软件都可以；同时另外拿到它的 **SHA-256 指纹**（例如当面念给您，或在聊天消息里发）。管理员在 Mac 的 `webapp/` 目录里这样导出：
   ```bash
   docker compose exec -T caddy cat /data/caddy/pki/authorities/local/root.crt > ca.crt
   openssl x509 -in ca.crt -noout -fingerprint -sha256
   ```
2. 在 Windows 上核对指纹：在 `ca.crt` 所在的文件夹打开 PowerShell，运行
   ```powershell
   $c = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 (Resolve-Path .\ca.crt)
   [BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash($c.RawData))
   ```
   把结果和管理员给的指纹逐位对一遍（`-` 和 `:` 不算，其余每一位都要一样）。不要用证书窗口里的"指纹/Thumbprint"：那是 SHA-1，永远对不上。对不上就停下，联系管理员。
3. 双击 `ca.crt`，点"安装证书"。
4. "存储位置"选 **本地计算机**，点"下一步"（如果 Windows 询问是否允许更改，点"是"）。
5. 选 **将所有的证书都放入下列存储**，点"浏览"，选 **受信任的根证书颁发机构**，点"确定"→"下一步"。
6. 点"完成"。看到"导入成功"就好了。
7. 把浏览器**全部关掉，再重新打开**。

## 第二步：登录

1. 打开：`https://<SITE_IP>:8443/`（地址栏不再提示"不安全"就说明证书装好了）
2. 粘贴管理员给您的密钥，点登录。浏览器会记住登录，以后不用再输。

## 可选：做成桌面应用、打开通知

- **做成桌面应用**（像普通软件一样从桌面或开始菜单打开）：
  - Edge：点右上角"…"→"应用"→"将此站点作为应用安装"。
  - Chrome：点地址栏右侧的"安装"小图标（或右上角"⋮"→"投放、保存和分享"→"安装页面作为应用"）。
- **打开通知**：在 Soulgent 里点左侧栏的"我"→"通知设置"→ 开启；浏览器询问时点"允许"。

## 使用小技巧

- 回车发送，Shift + 回车换行。
- 截图或复制图片后，在对话里按 Ctrl + V 直接贴成附件；也可以把文件拖进对话窗口。一次最多 9 个附件，和文字一起发送。
