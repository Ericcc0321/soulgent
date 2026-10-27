"""Helper settings: where the helper finds things outside this repo (panel app, Orca, Claude Code, hook state...).

Each item is read in the same order: process environment variable -> the same field in webapp/.env -> default.
The helper is started by launchd and does not load .env by itself, hence the .env lookup. Values are read once at import;
change them and restart the helper. Optional extensions (off-duty roster, wake script, window lineage) have no default: unset means disabled; see docs/dependencies.md.
"""

import os
from typing import Optional

WEBAPP = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
HOME = os.path.expanduser("~")


def dotenv_value(path: str, name: str) -> str:
    """Read a single field from .env (the helper is started by launchd, which does not load .env); empty string if not found."""
    try:
        with open(path, "r", encoding="utf-8") as f:
            for line in f:
                k, sep, v = line.strip().partition("=")
                if sep and k.strip() == name:
                    return v.strip().strip('"').strip("'")
    except OSError:
        pass
    return ""


def setting(name: str, default: str = "", env=None, webapp: str = WEBAPP) -> str:
    """Environment variable, then the same-named webapp/.env field, then default. Whitespace-only counts as unset."""
    env = os.environ if env is None else env
    return (env.get(name) or "").strip() or dotenv_value(os.path.join(webapp, ".env"), name) or default


def path_setting(name: str, default: str, env=None, webapp: str = WEBAPP) -> str:
    """Like setting, but expands ~ in a configured value; the default is returned as is."""
    given = setting(name, "", env, webapp)
    return os.path.expanduser(given) if given else default


def claude_dir(env=None, webapp: str = WEBAPP) -> str:
    """Claude Code config directory (contains sessions/ and projects/)."""
    return path_setting("SOULGENT_CLAUDE_DIR", os.path.join(HOME, ".claude"), env, webapp)


def claude_paths(env=None, webapp: str = WEBAPP) -> dict:
    """The ~/.claude locations the helper reads; the zones file can be pointed elsewhere separately. The roster and window-handoff lineage are optional extensions: an empty string means disabled."""
    base = claude_dir(env, webapp)
    return {
        "sessions_dir": os.path.join(base, "sessions"),
        "projects_dir": os.path.join(base, "projects"),
        "workzones": path_setting("SOULGENT_WORKZONES", os.path.join(base, "workzones.json"), env, webapp),
        "roster": path_setting("SOULGENT_ROSTER", "", env, webapp),
        "lineage_src": path_setting("SOULGENT_LINEAGE", "", env, webapp),
    }


def statusline_dir(env=None, webapp: str = WEBAPP) -> str:
    """Directory where the statusline script writes meta.<session id>.json."""
    return path_setting("SOULGENT_STATUSLINE_DIR", "/tmp/claude-statusline", env, webapp)


def orca_bin(env=None, webapp: str = WEBAPP) -> Optional[str]:
    """Configured orca command; None if unset (search default locations)."""
    return path_setting("SOULGENT_ORCA_BIN", "", env, webapp) or None


def claude_bin(env=None, webapp: str = WEBAPP) -> Optional[str]:
    """Configured claude command; None if unset (search PATH and common locations)."""
    return path_setting("SOULGENT_CLAUDE_BIN", "", env, webapp) or None


def orca_stats_dir(env=None, webapp: str = WEBAPP) -> str:
    """Orca data directory (orca-stats.json, orca-claude-usage.json)."""
    return path_setting("SOULGENT_ORCA_STATS_DIR", os.path.join(HOME, "Library", "Application Support", "orca"),
                        env, webapp)


def petdex_dir(env=None, webapp: str = WEBAPP) -> str:
    """Petdex pet directory (second default source for tools/build_pets.py)."""
    return path_setting("SOULGENT_PETDEX_DIR", os.path.join(HOME, ".petdex", "pets"), env, webapp)


def panel_domain(env=None, webapp: str = WEBAPP) -> str:
    """UserDefaults domain of the Mac panel (pets, seen times and pins are stored here)."""
    return setting("SOULGENT_PANEL_DOMAIN", "io.github.ericcc0321.soulgent", env, webapp)


def panel_domain_legacy(env=None, webapp: str = WEBAPP) -> str:
    """Legacy panel domain (dual-written and read as fallback during migration); empty string if unset, in which case only the new domain is used."""
    return setting("SOULGENT_PANEL_DOMAIN_LEGACY", "", env, webapp)
