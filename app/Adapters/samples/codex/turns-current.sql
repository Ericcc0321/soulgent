-- The Codex app's turn table (thread_history_1.sqlite) as read today.
CREATE TABLE thread_turns (thread_id TEXT NOT NULL, rollout_ordinal INTEGER NOT NULL, status TEXT NOT NULL, started_at REAL);
INSERT INTO thread_turns VALUES ('00000000-demo-0000-0000-codex0000002', 1, 'completed', 1790000000);
