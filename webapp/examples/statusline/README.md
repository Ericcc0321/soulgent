# Status line example for Soulgent

The helper reads status line output to fill the chat page's context ring, model / effort / t/s, and the 5-hour / 7-day quota numbers. Claude Code does not write these files by itself; this script does.

`soulgent-statusline.py` (stdlib only, runs on the Python 3 that ships with macOS) reads the JSON Claude Code pipes to a status line command and writes into `SOULGENT_STATUSLINE_DIR` (default `/tmp/claude-statusline`, the same variable the helper uses):

- `meta.<session id>.json`, written atomically, with `model`, `effort`, `fast`, `used_percentage`, `used_tokens`, `window`, `ts`. A field Claude Code did not provide is left out.
- `shared.five_hour` and `shared.seven_day` (two lines: used percent, reset time as epoch seconds), only when the input has `rate_limits` (Claude.ai subscription accounts, after the first response).

It prints one short line such as `Opus | ctx 12%`.

## Enable

In `~/.claude/settings.json`:

```json
{
  "statusLine": {
    "type": "command",
    "command": "/usr/bin/python3 /path/to/soulgent-statusline.py"
  }
}
```

If the helper uses a custom directory, set `SOULGENT_STATUSLINE_DIR` to the same value in the environment Claude Code runs in.

## Combine with your own status line

Claude Code allows one command, and stdin can be read only once. In your own script, save stdin and feed it to both:

```bash
#!/bin/bash
input=$(cat)
echo "$input" | /usr/bin/python3 /path/to/soulgent-statusline.py >/dev/null
echo "$input" | your-existing-statusline   # its output is what Claude Code shows
```

## What stays empty

- t/s (`speed`): Claude Code's input has no such figure, so this script never writes it.
- Effort and the fast flag: shown only if your Claude Code version includes them in the input.
- 5-hour / 7-day quota: empty unless the input carries `rate_limits`.
- Without any status line script all of the above stay empty and the context ring is not drawn.
