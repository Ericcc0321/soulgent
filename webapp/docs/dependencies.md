# External dependencies and what happens without them

[中文](dependencies.zh-CN.md)

The web app itself (the `api` and `caddy` containers) only reads `webapp/data/` and the Claude Code transcripts. Everything
else comes from the **helper** (`webapp/helper/`, a launchd agent on the Mac), which reads a number of files and programs
that live outside this repo. This page lists each of them: who provides it, what breaks when it is missing, and the
setting that points the helper somewhere else.

## How the settings are read

Every setting is looked up in the same order:

1. the process environment variable;
2. the same field in `webapp/.env` (the helper is started by launchd and does not load `.env` by itself, so it reads the
   field directly);
3. the default listed below.

An empty or whitespace-only value counts as not set. Paths may start with `~/`. Do not put a `# comment` after a value.
All settings are read **once when the helper starts**: after changing one, restart the helper with
`cd webapp && bash helper/install.sh`. Leaving every field empty gives exactly the defaults below.
Supported `SOULGENT_*` variables set in the environment of the install command are persisted into the launchd service; changing them later needs a reinstall (or put the field in `webapp/.env`).

## Dependencies

| Dependency | Provided by | Without it | Setting (default) |
|---|---|---|---|
| Soulgent for Mac (`Soulgent.app`, executable `Contents/MacOS/Soulgent`, run with `--dump`) | the `app/` folder of this repo | Every snapshot fails (`helper.log`: "Soulgent for Mac app not found"); the phone shows no sessions and the "data as of" time stops moving | `SOULGENT_PANEL` (`../app/Soulgent.app`, then `/Applications`, then `~/Applications`) |
| Soulgent for Mac preferences (UserDefaults: pets, seen-at, pinned) | Soulgent for Mac (`Soulgent.app`) | No pet per session (built-in flame avatar), no red "unread" dots synced from the Mac, pins and "seen" marks made on the phone do not reach Soulgent for Mac | `SOULGENT_PANEL_DOMAIN` (`io.github.ericcc0321.soulgent`) |
| Claude Code config directory: `sessions/<pid>.json`, `projects/` transcripts | Claude Code CLI | No `sessions/`: no working directory or zone for sessions, cannot send to a session. No `projects/`: chat pages and history are empty | `SOULGENT_CLAUDE_DIR` (`~/.claude`) |
| Zone table `workzones.json` | maintained by you (outside this repo) | Every session is "unzoned" (grey "Other"); no zone task boards | `SOULGENT_WORKZONES` (`<claude dir>/workzones.json`) |
| Zone style file (short names, avatar effects) | optional private file | Zone short names fall back to the defaults, no avatar effects | `SOULGENT_ZONE_STYLE` (`webapp/data/zone-style.json`) |
| Off-duty roster (JSON, optional extension) | maintained by your own off-duty script | No off-duty list; waking a session returns "no longer on the off-duty list" | `SOULGENT_ROSTER` (disabled by default) |
| Off-duty / wake script (optional extension) | provided by you (outside this repo); called with `--wake` / `--off` plus the session name | Wake and "send off duty" fail | `SOULGENT_OFFDUTY` (disabled by default) |
| Window lineage (jsonl, optional extension) | your own window-switch script (appends one line per switch) | Chat pages show only the current window, not the earlier windows of the same session; search covers only current windows | `SOULGENT_LINEAGE` (disabled by default) |
| Status line output `meta.<session id>.json`, `shared.five_hour`, `shared.seven_day` | a Claude Code status line script that writes them (minimal one: `examples/statusline/`) | The chat page shows no model / effort / context / t/s; no 5-hour / 7-day quota numbers; the context ring stays empty | `SOULGENT_STATUSLINE_DIR` (`/tmp/claude-statusline`) |
| Orca CLI `orca` | Orca | Sending messages, answering prompts and reading terminals fail ("Orca didn't accept it"); the monitor has no Orca memory data | `SOULGENT_ORCA_BIN` (`/usr/local/bin/orca`, then `/Applications/Orca.app/Contents/Resources/bin/orca`) |
| Orca stats `orca-stats.json`, `orca-claude-usage.json` | Orca | The Orca statistics panel is empty; everything else works | `SOULGENT_ORCA_STATS_DIR` (`~/Library/Application Support/orca`) |
| Claude Code CLI `claude` | Claude Code | The context detail panel says the claude command can't be found; everything else works | `SOULGENT_CLAUDE_BIN` (`~/.local/bin`, `/opt/homebrew/bin`, `/usr/local/bin`, then `PATH`) |
| Petdex pets `~/.petdex/pets` | Petdex | `tools/build_pets.py` only uses `../app/pets`; with no pets at all the phone uses the built-in flame avatar | `SOULGENT_PETDEX_DIR` (`~/.petdex/pets`) |
| launchd label of the helper | `helper/install.sh` | — | `SOULGENT_HELPER_LABEL` (`io.github.ericcc0321.soulgent.helper`) |

## Notes

- `SOULGENT_CLAUDE_DIR` only moves what the helper reads. The `api` container mounts the transcripts itself
  (`${HOME}/.claude/projects:/projects:ro` in `docker-compose.yml`); if you move the Claude directory, mount the new
  `projects/` on `/projects` in `docker-compose.override.yml` too, then `docker compose up -d`. Otherwise chat pages are empty.
- Only `SOULGENT_WORKZONES` defaults to a path under `SOULGENT_CLAUDE_DIR` (it can also be set on its own).
  `SOULGENT_ROSTER` and `SOULGENT_LINEAGE` have no default: set them explicitly, otherwise the roster and window-handoff
  lineage stay disabled.
- When something looks wrong on the phone, check `webapp/data/helper.log` first.

## Upgrading from pre-release builds

These settings exist only for deployments that were running before the public release. A new install leaves all of them unset (and they are not in `.env.example`). Add them to `webapp/.env` only if the case below applies to you. (If your existing deployment was started under a compose project name other than `soulgent`, also set `COMPOSE_PROJECT_NAME`, a general optional setting listed in `.env.example`, to that name; otherwise `docker compose up -d` creates a new empty `<name>_state` volume and the old data looks lost.)

- `GUEST_LEGACY_ACCOUNT`: the guest account's former internal name. When set, the server still recognizes it as the guest: `profile-<name>.json` / `avatar-<name>.jpg` in the state volume, push subscriptions whose account is that name, and pages opened with `?account=<name>`. Letters, digits, `_` and `-` only; it cannot be `guest` or `admin`. Leave it empty for new deployments. Restart with `docker compose up -d` after changing it.
- `SOULGENT_PANEL_DOMAIN_LEGACY`: a second UserDefaults domain, for migrating from an older Soulgent for Mac bundle ID. When set, the helper writes both domains (legacy first, then current), and on read the legacy domain wins until the app has migrated. Clear it once the migration is done.
- `SOULGENT_HELPER_LABEL_LEGACY`: the launchd label of an older helper. When set, `helper/install.sh` first stops and removes the helper with this label before installing the new one, so two copies never run together. Clear it afterwards.

The two `SOULGENT_*` variables are read when the helper starts: restart it with `bash helper/install.sh` after changing them.
