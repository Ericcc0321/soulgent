-- codex turns: a later turn table whose ordinal column was renamed (rollout_ordinal -> turn_index).
CREATE TABLE thread_turns (thread_id TEXT NOT NULL, turn_index INTEGER NOT NULL, status TEXT NOT NULL, started_at REAL);
INSERT INTO thread_turns VALUES ('00000000-demo-0000-0000-codex0000002', 1, 'completed', 1790000000);
