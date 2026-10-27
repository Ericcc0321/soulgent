# 外部依赖与缺了会怎样

[English](dependencies.md)

网页本身（`api` 和 `caddy` 两个容器）只读 `webapp/data/` 和 Claude Code 的会话记录。其余数据都来自 Mac 上的
**小帮手**（`webapp/helper/`，launchd 常驻），它要读本仓库以外的一些文件和程序。本页逐项列出：谁提供、缺了会怎样、
用哪个设置把小帮手指到别处。

## 设置怎么读

每一项都按同一个顺序找：

1. 进程环境变量；
2. `webapp/.env` 里的同名字段（小帮手由 launchd 启动，不会自动加载 `.env`，所以直接读这个字段）；
3. 下表里的默认值。

值为空或只有空白算没填。路径可以用 `~/` 开头。值后面不要加 `# 注释`。
所有设置都**只在小帮手启动时读一次**，改了要重启小帮手：`cd webapp && bash helper/install.sh`。全部不填就是下表的默认值。
安装命令环境里设置的受支持的 `SOULGENT_*` 变量会写进 launchd 服务；之后要改须重新安装（或把该字段写进 `webapp/.env`）。

## 依赖清单

| 依赖 | 谁提供 | 缺了会怎样 | 设置（默认值） |
|---|---|---|---|
| Soulgent for Mac（`Soulgent.app`，可执行文件 `Contents/MacOS/Soulgent`，用 `--dump` 运行） | 本仓库 `app/` 目录 | 每次快照都失败（`helper.log` 里「Soulgent for Mac app not found」），手机上没有会话，「数据截至」时间不再走 | `SOULGENT_PANEL`（依次找 `../app/Soulgent.app`、`/Applications`、`~/Applications`） |
| Soulgent for Mac 的偏好设置（UserDefaults：宠物、看过时间、置顶） | Soulgent for Mac（`Soulgent.app`） | 会话没有宠物（用内置灵火头像），Mac 上的已读红点不同步，手机上的置顶和「看过」到不了 Soulgent for Mac | `SOULGENT_PANEL_DOMAIN`（`io.github.ericcc0321.soulgent`） |
| Claude Code 配置目录：`sessions/<pid>.json`、`projects/` 会话记录 | Claude Code CLI | 没有 `sessions/`：会话拿不到工作目录和工区，也发不了消息。没有 `projects/`：对话页和历史都是空的 | `SOULGENT_CLAUDE_DIR`（`~/.claude`） |
| 工区表 `workzones.json` | 自己维护（不在本仓库） | 所有会话都是「未分区」（灰色「其他」），没有工区任务板 | `SOULGENT_WORKZONES`（`<Claude 目录>/workzones.json`） |
| 工区样式文件（简称、头像特效） | 可选的私有文件 | 工区简称用内置默认，没有头像特效 | `SOULGENT_ZONE_STYLE`（`webapp/data/zone-style.json`） |
| 下班名册（JSON，可选扩展） | 你自己的下班脚本维护 | 不显示下班名单；唤醒会提示「它已经不在下班名单里了」 | `SOULGENT_ROSTER`（默认不启用） |
| 唤醒 / 送下班脚本（可选扩展） | 自己提供（不在本仓库），接受 `--wake` / `--off` 加会话名 | 唤醒和送下班都失败 | `SOULGENT_OFFDUTY`（默认不启用） |
| 换窗谱系（jsonl，可选扩展） | 自己的换窗脚本（每换一次窗追加一行） | 对话页只有当前这一窗，看不到同一会话之前的窗；搜索也只搜当前窗 | `SOULGENT_LINEAGE`（默认不启用） |
| 状态栏输出 `meta.<会话id>.json`、`shared.five_hour`、`shared.seven_day` | 写这些文件的 Claude Code 状态栏脚本（最小示例见 `examples/statusline/`） | 对话页不显示模型 / 思考力度 / 上下文 / t/s，没有 5 小时 / 7 天额度，上下文环是空心灰环 | `SOULGENT_STATUSLINE_DIR`（`/tmp/claude-statusline`） |
| Orca 命令 `orca` | Orca | 发消息、作答、读终端都失败（「Orca 没接收」）；监控里没有 Orca 内存数据 | `SOULGENT_ORCA_BIN`（依次找 `/usr/local/bin/orca`、`/Applications/Orca.app/Contents/Resources/bin/orca`） |
| Orca 统计 `orca-stats.json`、`orca-claude-usage.json` | Orca | Orca 统计面板是空的，其余不受影响 | `SOULGENT_ORCA_STATS_DIR`（`~/Library/Application Support/orca`） |
| Claude Code 命令 `claude` | Claude Code | 上下文明细提示「Mac 上找不到 claude 命令」，其余不受影响 | `SOULGENT_CLAUDE_BIN`（依次找 `~/.local/bin`、`/opt/homebrew/bin`、`/usr/local/bin`、`PATH`） |
| Petdex 宠物 `~/.petdex/pets` | Petdex | `tools/build_pets.py` 只用 `../app/pets`；一只宠物都没有时手机用内置灵火头像 | `SOULGENT_PETDEX_DIR`（`~/.petdex/pets`） |
| 小帮手的 launchd 标签 | `helper/install.sh` | — | `SOULGENT_HELPER_LABEL`（`io.github.ericcc0321.soulgent.helper`） |

## 注意

- `SOULGENT_CLAUDE_DIR` 只改小帮手读哪里。`api` 容器自己挂会话记录（`docker-compose.yml` 里的
  `${HOME}/.claude/projects:/projects:ro`）；换了 Claude 目录，要在 `docker-compose.override.yml` 里把新的 `projects/`
  也挂到 `/projects`，再 `docker compose up -d`，否则对话页是空的。
- 只有 `SOULGENT_WORKZONES` 默认跟着 `SOULGENT_CLAUDE_DIR` 走（也可以单独设）；`SOULGENT_ROSTER`、`SOULGENT_LINEAGE` 没有默认值，要显式指定，否则名册和换窗谱系不启用。
- 手机上看着不对时，先看 `webapp/data/helper.log`。

## 从预发布版升级

下面这些设置只给公开发布之前就在跑的旧部署用。全新安装一个都不用设（`.env.example` 里也不再列）。只有符合下面情况时，才把它们加进 `webapp/.env`。（已有部署如果当初用的 compose 项目名不是 `soulgent`，还要把 `COMPOSE_PROJECT_NAME` 设成那个名字；它是通用可选项，`.env.example` 里有。否则 `docker compose up -d` 会新建一个空的 `<名字>_state` 卷，旧数据看起来像丢了。）

- `GUEST_LEGACY_ACCOUNT`：访客账号以前的内部名。设了以后，服务器仍把它认作访客：state 卷里的 `profile-<名字>.json` / `avatar-<名字>.jpg`、账号为该名字的推送订阅、以及用 `?account=<名字>` 打开的页面。只能用字母、数字、`_`、`-`，不能是 `guest` 或 `admin`。新部署留空。改完要 `docker compose up -d`。
- `SOULGENT_PANEL_DOMAIN_LEGACY`：第二个 UserDefaults 域，用于从旧的 Soulgent for Mac Bundle ID 迁移。设了以后，小帮手两个域都写（先旧后新），读取时旧域优先，直到 Mac 端迁移完成。迁完就清空。
- `SOULGENT_HELPER_LABEL_LEGACY`：旧版小帮手的 launchd 标签。设了以后，`helper/install.sh` 先停掉并移除这个标签的小帮手，再装新的，避免两份同时运行。装完后清空。

两个 `SOULGENT_*` 变量在小帮手启动时读取：改完用 `bash helper/install.sh` 重启。
