# Demo Guide

A short fictional guide used as a rendering sample. Nothing here describes a real product.

Demo Guide has two parts that read the same data:

| | **Demo Desktop** | **Demo Web** |
|---|---|---|
| What it is | A native menu-bar app | A web app on the home screen |
| Good for | Watching everything at a desk | Checking in away from the desk |
| Status | Build it yourself | Work in progress |

> **Status:** early sample. The interface follows the system language.

## Why

1. **Give each item a face.** A name, a mood, a rest state.
2. **Make a crowd easy to coordinate.** See who is waiting, who is done, who is busy.

- **Main screen:** the full view where the work happens.
- **Second screen**: an always-on board for a quick glance.
- **Phone:** a message list with notifications.

## Supported platforms

| | Demo Desktop | Demo Web |
|---|---|---|
| macOS | Native app | The service runs here (Docker) |
| iPhone / iPad | Tablet as a second screen | Add to home screen, push supported |
| Android | - | Open in a browser |
| Windows | Not supported | Open in a browser on the same network |

### Three views

| Front desk | Office | Archive |
|---|---|---|
| Incoming items | Active work | Finished items |

## Alignment and edge cases

| 左对齐 | 居中 | 右对齐 |
|:---|:---:|---:|
| `code` | **粗** | *斜* |
| a \| b | ~~删~~ | [link](https://example.com/x?a=1&b=2) |
| 行尾没竖线 | 2 | 3
| 少一格 | 只有两格 |

## Install

```bash
git clone https://example.com/demo-guide.git
cd demo-guide

# install a few characters
tools/fetch-assets.sh <asset-id>

app/build.sh                # build
tools/install.sh            # start now and at login
```

On first launch the system asks for permission under **System Settings > Privacy & Security > Accessibility**. To remove the login item, run `tools/uninstall.sh`.

## How it works

- **Sessions**: a list of running items is read every 2 seconds from `~/.demo/sessions/`.
- **Groups (optional)**: defined in `~/.demo/groups.json`, see [the next section](#build-a-team).
- **Data stays on your machine.**

## Build a team

1. **Name items as `group-system-task`**, for example `Web-auth-flow`.
2. **Write a group file** like this one:

   ```json
   {
     "default": null,
     "groups": {
       "Web":   { "name": "Web",   "color": "#4A90D9", "order": 1, "lead": "Web-lead" },
       "Docs":  { "name": "Docs",  "color": "#E0A040", "order": 2, "lead": "Docs-lead" }
     }
   }
   ```

3. Restart and it takes effect.

   - Nested one level
     - Nested again, with `inline code` and **bold**

| Field | Meaning | Required | Example |
|---|---|---|---|
| `name` | Display name | yes | `Web` |
| `color` | Color | no | `#4A90D9` |
| `order` | Sort order | no | `1` |
| `lead` | Lead item | no | `Web-lead` |
| `fx` | Avatar effect | no | `halo` |
| `short` | Short name | no | `W` |
| `emoji` | Icon | no | :fire: |
| `<tag>` | Angle brackets | no | `<x>` |
| t | Single letter t | no | t("x") |
| 中文 | 中文 | 是 | 中文值 |
| 很长的一格很长的一格很长的一格很长的一格很长的一格很长的一格 | x | x | x |
| spaces |  |  |  |
| last | end | end | end |
| one more | more | more | more |

## Credits

- [Example Terminal](https://example.com/terminal): a terminal workspace.

---

MIT License
