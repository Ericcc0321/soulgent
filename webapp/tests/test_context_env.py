"""Medium risk: the /context subprocess must use the configured Claude dir (SOULGENT_CLAUDE_DIR); stripping every CLAUDE* variable would fall back to the default dir."""
import json
import os
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from helper import outbox  # noqa: E402

SID = "8bbbbbbb-2222-4222-8222-222222222222"


class ContextEnvTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.sdir = os.path.join(self.tmp.name, "sessions")
        os.makedirs(self.sdir)
        with open(os.path.join(self.sdir, "1.json"), "w") as f:
            json.dump({"sessionId": SID, "cwd": self.tmp.name}, f)
        self.addCleanup(self._reset)

    def _reset(self):
        run = outbox._CTX_RUN
        if run:
            with outbox._FORKS_LOCK:
                outbox._FORKS.pop(run["fork"], None)
            run["out"].close()
            run["err"].close()
        outbox._CTX_RUN = None

    def start(self, environ, claude_dir):
        seen = {}

        def fake_popen(cmd, **kw):
            seen.update(kw["env"])
            return mock.Mock(pid=99999)

        with mock.patch.dict(os.environ, environ, clear=True), \
                mock.patch.object(outbox.subprocess, "Popen", fake_popen), \
                mock.patch.object(outbox, "CLAUDE_DIR", claude_dir):
            err = outbox._ctx_start({"sid": SID, "name": "x", "reqs": []}, self.sdir, claude="/bin/echo",
                                    projects_dir=self.tmp.name)
        self.assertIsNone(err)
        return seen

    def test_custom_claude_dir_passed_to_child(self):
        env = self.start({"PATH": "/usr/bin", "CLAUDE_CONFIG_DIR": "/somewhere/else", "CLAUDECODE": "1",
                          "CLAUDE_CODE_ENTRYPOINT": "cli", "CLAUDE_CODE_USE_BEDROCK": "1",
                          "ORCA_TERMINAL_HANDLE": "t1", "ANTHROPIC_MODEL": "m"}, "/Users/x/.claude-work")
        self.assertEqual(env["CLAUDE_CONFIG_DIR"], "/Users/x/.claude-work")
        for k in ("CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT", "ORCA_TERMINAL_HANDLE"):  # nested-session markers are still stripped
            self.assertNotIn(k, env)
        self.assertEqual(env["CLAUDE_CODE_USE_BEDROCK"], "1")  # normal Claude config variables are kept
        self.assertEqual(env["ANTHROPIC_MODEL"], "m")

    def test_default_dir_leaves_config_dir_unset(self):
        """With the default ~/.claude, CLAUDE_CONFIG_DIR is not set (setting it makes Claude Code look for .claude.json inside that dir), and none is inherited from elsewhere."""
        env = self.start({"PATH": "/usr/bin", "CLAUDE_CONFIG_DIR": "/somewhere/else"},
                         os.path.join(outbox.HOME, ".claude"))
        self.assertNotIn("CLAUDE_CONFIG_DIR", env)


if __name__ == "__main__":
    unittest.main()
