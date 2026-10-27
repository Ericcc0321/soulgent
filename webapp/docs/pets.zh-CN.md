# 宠物与工具小人

[English](pets.md) | 简体中文

Soulgent 手机端的宠物（会话头像、SoulChat 消息列表里「干活中」时走出头像框）和对话页的工具小人，都来自 Petdex。
Petdex 里的宠物是用户投稿作品，素材版权归各投稿人；本仓库不收录任何 Petdex 宠物图，也不写死宠物名。感谢 Petdex 和每一位投稿人。

没装任何宠物时，工具小人用内置的原创形象「灵火」（`web/figures/soulflame/`），开箱就有。

下文路径都相对仓库里的 `webapp/` 目录，命令也在那里执行。

## 1. 装宠物

```sh
npx petdex install <id>      # <id> 是宠物在 Petdex 上的名字
```

装好的宠物在 `~/.petdex/pets/<id>/spritesheet.webp`。仓库里的 `app/pets/<id>/`（从 `webapp/` 看是 `../app/pets/<id>/`）是可选的本地宠物来源。内置灵火在 Mac 端的 `app/brand/soulgent/pet/soulflame/`；手机端的内置灵火形象在 `webapp/web/figures/soulflame/`，不经过切图。

## 2. 切成手机用的小图

脚本要 Mac 自己的 Python 装了 Pillow（Docker 镜像里装的不算）。先从 PyPI 装一次：

```sh
/usr/bin/python3 -m pip install --user Pillow
```

```sh
cd webapp                         # 在仓库根目录下
/usr/bin/python3 tools/build_pets.py
```

- 默认依次读 `../app/pets` 和 `~/.petdex/pets`（同名先到先得），输出到 `data/pets/<id>/{0,1,2,3,4,6,7,still}.webp` 和 `data/pets/manifest.json`。
- `data/pets/` 不进 git，由 caddy 以 `/pets/` 发给手机。
- 没改过的宠物会跳过，重跑很快。换了同名宠物的图，手机有缓存，要改 `web/sw.js` 的 `PET_CACHE` 名字才会更新。

## 3. 指定工具小人

```sh
/usr/bin/python3 tools/build_pets.py --figure <id>    # 选一只当工具小人
/usr/bin/python3 tools/build_pets.py --figure ""      # 取消，回到自动挑
```

选中的那只在 `manifest.json` 的条目里带 `figure` 字段；以后不带 `--figure` 重跑会沿用上次的选择。手机端规则：

1. 清单里带 `figure` 的那只（7 条精灵图要齐全）；
2. 没指定：按名字排序第一只齐全的宠物；
3. 一只都没装（`/pets/manifest.json` 不存在或为空）：内置灵火。

形象的几何（脚踩在哪、停在气泡底下时露多少、要不要裁掉头顶的道具）可以写在 `data/pets/<id>/figure.json`，build_pets 会把它放进 `figure` 字段。字段都可省，缺省值和含义见 `web/logic.js` 的 `FIG_GEOM_DEFAULT`；内置灵火的配置是 `web/figures/soulflame/figure.json`，可以照着写。

## 4. 宠物能力（SoulChat 列表出框）

未分区的会话在干活时，宠物会走出头像框。哪只能走，写在 `data/pets/<id>/caps.json`：

```json
{"walk": true}
```

- `walk`：第 7 行「干活」动画是走路 → 出门跑腿 / 搬文件；
- 其他情况（`unsure`，或没有 caps.json）：宠物留在头像里，由内置灵火替它出门跑腿。

改完重跑 build_pets.py，caps 会汇总进 manifest。

## 5. 推送通知的 emoji

iPhone 锁屏通知显示不了头像，所以每条会话推送的标题前加一个按宠物挑的 emoji（没有宠物用 🔥）；想自己指定，写 `data/pet-emoji.json`，格式 `{"<宠物 id>": "🐳"}`（可选、私有，api 发现文件改了会重读）。
