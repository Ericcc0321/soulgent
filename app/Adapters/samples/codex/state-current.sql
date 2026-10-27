-- Codex's thread index (state_5.sqlite) as read today: the columns the CLI's and the app's readers name.
CREATE TABLE threads (id TEXT PRIMARY KEY, rollout_path TEXT NOT NULL, created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL,
    source TEXT NOT NULL, cwd TEXT NOT NULL, title TEXT NOT NULL, archived INTEGER NOT NULL DEFAULT 0, model TEXT, name TEXT,
    reasoning_effort TEXT, updated_at_ms INTEGER, recency_at_ms INTEGER, originator TEXT);
INSERT INTO threads VALUES ('00000000-demo-0000-0000-codex0000001', '/Users/demo/.codex/sessions/rollout-demo-cli.jsonl', 1790000000, 1790000000,
    'cli', '/Users/demo/Projects/demo-garden', 'Count the demo apples', 0, 'gpt-demo-1', 'demo apples', NULL, NULL, NULL, 'codex_cli_rs');
INSERT INTO threads VALUES ('00000000-demo-0000-0000-codex0000002', '/Users/demo/.codex/sessions/rollout-demo-app.jsonl', 1790000000, 1790000000,
    'vscode', '/Users/demo/Projects/demo-orchard', 'Sort the demo pears', 0, 'gpt-demo-1', NULL, 'low', 1790000000000, 1790000000000, 'Codex Desktop');
