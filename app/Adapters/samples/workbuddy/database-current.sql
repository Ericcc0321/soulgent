-- WorkBuddy's database (workbuddy.db) as read today: the sessions table's columns the reader names.
CREATE TABLE sessions (id TEXT PRIMARY KEY, title TEXT, custom_title TEXT, cwd TEXT, status TEXT, permission_mode TEXT, model TEXT,
    updated_at INTEGER, last_activity_at INTEGER, transport TEXT, deleted_at INTEGER, is_background_automation INTEGER);
INSERT INTO sessions VALUES ('00000000-demo-0000-0000-workbuddy001', 'Plan the demo picnic', '', '/Users/demo/WorkBuddy/demo-picnic', 'pending',
    'default', 'demo-model-1', 1790000000000, 1790000000000, 'local', NULL, 0);
