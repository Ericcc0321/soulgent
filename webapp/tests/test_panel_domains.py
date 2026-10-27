"""Panel domain rename transition: dual writes to old and new domains, merged reads, the helper's new launchd label and old-label removal logic.
subprocess / launchctl are fully stubbed: never writes real defaults, never touches real launchd."""
import glob
import json
import os
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)
from tests import _sig  # noqa: E402  sets OUTBOX_SECRET; signs hand-written requests/results

from helper import outbox, snapshot  # noqa: E402

NEW = "org.example.new-panel"
OLD = "org.example.old-panel"
NOW = 1792431400.0


class PanelFake:
    """defaults stub: keeps a dict per domain; records writes in order; writes to domains listed in fail raise."""

    def __init__(self, domains=None, fail=()):
        self.domains = domains or {}
        self.fail = set(fail)
        self.calls = []

    def run(self, cmd, **kw):
        self.calls.append(cmd)
        if cmd[:2] == ["defaults", "export"]:
            return subprocess.CompletedProcess(cmd, 0, stdout=plistlib.dumps(self.domains.get(cmd[2], {})))
        if cmd[:2] == ["defaults", "write"] and cmd[2] in self.fail:
            raise subprocess.CalledProcessError(1, cmd)
        return subprocess.CompletedProcess(cmd, 0)

    def writes(self):
        return [c for c in self.calls if c[:2] == ["defaults", "write"]]


class Base(unittest.TestCase):
    legacy = OLD

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.ob = os.path.join(self.tmp.name, "ob")
        os.makedirs(self.ob)
        for k, v in (("PANEL_DOMAIN", NEW), ("PANEL_DOMAIN_LEGACY", self.legacy)):
            p = mock.patch.object(outbox, k, v)
            p.start()
            self.addCleanup(p.stop)

    def mark(self, fake, req):
        with open(os.path.join(self.ob, "r1.req.json"), "w") as f:
            json.dump(_sig.req(dict(req, id="r1", type="mark", createdAt=NOW)), f)
        with mock.patch.object(outbox.subprocess, "run", fake.run):
            outbox.process_once(self.ob, {}, self.tmp.name, [], os.path.join(self.tmp.name, "l"), NOW)
        self.assertEqual(os.listdir(self.ob), [])
        return fake.writes()


# one request per write path: seen (write only when larger), unseen (write backwards), pin (write the whole set)
PATHS = {
    "seen": {"seen": {"s1": 1792431352.448}},
    "unseen": {"unseen": {"s1": 1792431000.25}},
    "pin": {"pin": {"p3": True}},
}


class DualWriteTest(Base):
    def test_every_path_writes_old_then_new(self):
        for name, req in PATHS.items():
            with self.subTest(name):
                fake = PanelFake({OLD: {"seenAt": {"s1": 1792431100.0}, "pinned": ["p1"]}})
                w = self.mark(fake, req)
                self.assertEqual(len(w), 2, w)
                self.assertEqual([c[2] for c in w], [OLD, NEW])  # old first, then new
                self.assertEqual(w[0][3:], w[1][3:])  # both domains get the same content
        # seenAt is still a plist <real>, not -float
        w = self.mark(PanelFake(), PATHS["seen"])
        self.assertEqual(w[1], ["defaults", "write", NEW, "seenAt", "-dict-add", "s1", "<real>1792431352.448</real>"])

    def test_old_write_fails_new_not_written(self):
        for name, req in PATHS.items():
            with self.subTest(name):
                fake = PanelFake(fail={OLD})
                with mock.patch.object(outbox, "_warn") as warn:
                    w = self.mark(fake, req)
                self.assertEqual([c[2] for c in w], [OLD])  # stop when the old domain fails; nothing is written to the new domain
                self.assertTrue(warn.called)  # logged

    def test_never_writes_migrated_key(self):
        fake = PanelFake({NEW: {"legacyMigratedFrom": OLD, "seenAt": {}, "pinned": []}})
        req = {"seen": {"a": 5.0}, "unseen": {"b": 1.0}, "pin": {"c": True},
               "legacyMigratedFrom": "x", "other": {"legacyMigratedFrom": 1}}
        for c in self.mark(fake, req):
            self.assertIn(c[3], ("seenAt", "pinned"))
        with self.assertRaises(ValueError):
            outbox._panel_write(["legacyMigratedFrom", "-string", "x"])

    def test_only_one_write_function(self):
        # enumerate every "defaults", "write" call in helper/: they may only appear in _panel_write; all other paths must go through it for dual writes
        src = open(outbox.__file__, encoding="utf-8").read()
        body = re.search(r"\ndef _panel_write\(.*?(?=\ndef )", src, re.S)
        start, end = body.start(), body.end()
        n = 0
        for p in sorted(glob.glob(os.path.join(ROOT, "helper", "*.py"))):
            text = open(p, encoding="utf-8").read()
            for m in re.finditer(r"""["']defaults["']\s*,\s*["']write["']""", text):
                n += 1
                self.assertTrue(p == outbox.__file__ and start <= m.start() < end,
                                "defaults write bypasses _panel_write: %s:%d" % (p, text.count("\n", 0, m.start()) + 1))
        self.assertEqual(n, 1)


class PinResyncTest(Base):
    # an old panel only changed pinned in the old domain (the new domain keeps a stale x); the next phone action must rewrite both domains consistently
    def domains(self):
        return {OLD: {"pinned": []}, NEW: {"pinned": ["x"]}}

    def test_unpin_residual_writes_both_empty(self):
        w = self.mark(PanelFake(self.domains()), {"pin": {"x": False}})
        self.assertEqual(w, [["defaults", "write", OLD, "pinned", "-array"],
                             ["defaults", "write", NEW, "pinned", "-array"]])

    def test_pin_new_writes_both(self):
        w = self.mark(PanelFake(self.domains()), {"pin": {"y": True}})
        self.assertEqual(w, [["defaults", "write", OLD, "pinned", "-array", "y"],
                             ["defaults", "write", NEW, "pinned", "-array", "y"]])

    def test_all_invalid_writes_nothing(self):
        self.assertEqual(self.mark(PanelFake(self.domains()), {"pin": {"-a": True, "b": "x"}}), [])


class PinResyncNoLegacyTest(Base):
    legacy = ""

    def test_only_new_written(self):
        w = self.mark(PanelFake({NEW: {"pinned": ["x"]}}), {"pin": {"x": False}})
        self.assertEqual(w, [["defaults", "write", NEW, "pinned", "-array"]])


class NoLegacyTest(Base):
    legacy = ""

    def test_only_new_written(self):
        for name, req in PATHS.items():
            with self.subTest(name):
                w = self.mark(PanelFake(), req)
                self.assertEqual([c[2] for c in w], [NEW])

    def test_read_is_new_only(self):
        fake = PanelFake({NEW: {"seenAt": {"a": 1.0}}, OLD: {"seenAt": {"a": 9.0}}})
        with mock.patch.object(outbox.subprocess, "run", fake.run):
            self.assertEqual(outbox.read_panel(), {"seenAt": {"a": 1.0}})
        self.assertEqual([c[2] for c in fake.calls], [NEW])


class ReadFallbackTest(Base):
    def read(self, domains):
        fake = PanelFake(domains)
        with mock.patch.object(outbox.subprocess, "run", fake.run):
            return snapshot.read_panel_domain()

    def test_new_missing_reads_old(self):
        d = self.read({OLD: {"seenAt": {"a": 1.0}, "pinned": ["a"], "petBySession": {"a": "cat"}}})
        self.assertEqual(d["seenAt"], {"a": 1.0})
        self.assertEqual(d["pinned"], ["a"])
        self.assertEqual(snapshot.pets_from(d), {"a": "cat"})

    def test_before_migration_old_wins_per_key(self):
        # panel not migrated: the new domain only holds the seenAt entries dual-written from the phone, the old domain has the full set
        d = self.read({NEW: {"seenAt": {"a": 2.0}, "onlyNew": 1},
                       OLD: {"seenAt": {"a": 2.0, "b": 3.0}, "pinned": ["b"], "petBySession": {"b": "dog"}}})
        self.assertEqual(d["seenAt"], {"a": 2.0, "b": 3.0})
        self.assertEqual(d["pinned"], ["b"])
        self.assertEqual(d["onlyNew"], 1)  # keys missing from the old domain come from the new one

    def test_after_migration_new_wins_per_key(self):
        d = self.read({NEW: {"legacyMigratedFrom": OLD, "seenAt": {"a": 5.0}, "pinned": []},
                       OLD: {"seenAt": {"a": 1.0}, "pinned": ["x"], "petBySession": {"a": "cat"}}})
        self.assertEqual(d["seenAt"], {"a": 5.0})
        self.assertEqual(d["pinned"], [])
        self.assertEqual(snapshot.pets_from(d), {"a": "cat"})  # keys missing from the new domain fall back to the old one

    def test_mark_compares_against_old_before_migration(self):
        # write only when the new value is larger: compared against the old domain (full set), so a session already read on the panel is not written back to an earlier time
        fake = PanelFake({NEW: {"seenAt": {}}, OLD: {"seenAt": {"s1": 1792431400.0}}})
        self.assertEqual(self.mark(fake, {"seen": {"s1": 1792431300.0}}), [])

    def test_old_read_failure_uses_new(self):
        def run(cmd, **kw):
            if cmd[2] == OLD:
                raise subprocess.CalledProcessError(1, cmd)
            return subprocess.CompletedProcess(cmd, 0, stdout=plistlib.dumps({"seenAt": {"a": 1.0}}))
        with mock.patch.object(outbox.subprocess, "run", run):
            self.assertEqual(snapshot.read_panel_domain(), {"seenAt": {"a": 1.0}})


class InstallScriptTest(unittest.TestCase):
    """install.sh runs in a temp directory: no .env, launchctl replaced by a stub that records its arguments, HOME pointed at the temp directory."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        t = self.tmp.name
        self.webapp = os.path.join(t, "webapp")
        os.makedirs(os.path.join(self.webapp, "helper"))
        for f in ("install.sh", "uninstall.sh", "soulgent-helper.plist.template"):
            shutil.copy(os.path.join(ROOT, "helper", f), os.path.join(self.webapp, "helper", f))
        self.bin = os.path.join(t, "bin")
        os.makedirs(self.bin)
        self.log = os.path.join(t, "launchctl.log")
        with open(os.path.join(self.bin, "launchctl"), "w") as f:
            f.write('#!/bin/bash\necho "$*" >> "%s"\nexit 0\n' % self.log)
        os.chmod(os.path.join(self.bin, "launchctl"), 0o755)
        self.home = os.path.join(t, "home")
        os.makedirs(os.path.join(self.home, "Library", "LaunchAgents"))

    def run_sh(self, script, *args, **env):
        e = {"PATH": self.bin + ":/usr/bin:/bin", "HOME": self.home}
        e.update(env)
        return subprocess.run(["/bin/bash", os.path.join(self.webapp, "helper", script)] + list(args),
                              capture_output=True, text=True, env=e, timeout=20)

    def calls(self):
        if not os.path.exists(self.log):
            return []
        with open(self.log) as f:
            return f.read().splitlines()

    def test_print_default_label_and_no_launchctl(self):
        r = self.run_sh("install.sh", "--print", SOULGENT_HELPER_LABEL_LEGACY="org.example.old-helper")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("<string>io.github.ericcc0321.soulgent.helper</string>", r.stdout)
        self.assertNotIn("__LABEL__", r.stdout)
        self.assertIn("org.example.old-helper", r.stderr)  # tells the user the old label will be unloaded on install
        self.assertEqual(self.calls(), [])  # --print does not touch launchctl

    def test_install_removes_legacy_first(self):
        la = os.path.join(self.home, "Library", "LaunchAgents")
        open(os.path.join(la, "org.example.old-helper.plist"), "w").close()
        with open(os.path.join(self.webapp, ".env"), "w") as f:
            f.write("SOULGENT_HELPER_LABEL_LEGACY=org.example.old-helper\n")
        r = self.run_sh("install.sh")
        self.assertEqual(r.returncode, 0, r.stderr)
        uid = str(os.getuid())
        c = self.calls()
        self.assertEqual(c[:2], ["print gui/%s/org.example.old-helper" % uid,
                                 "bootout gui/%s/org.example.old-helper" % uid])
        self.assertEqual(c[-1], "bootstrap gui/%s %s/io.github.ericcc0321.soulgent.helper.plist" % (uid, la))
        self.assertFalse(os.path.exists(os.path.join(la, "org.example.old-helper.plist")))
        self.assertTrue(os.path.exists(os.path.join(la, "io.github.ericcc0321.soulgent.helper.plist")))

    def test_install_without_legacy_touches_only_new(self):
        r = self.run_sh("install.sh")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertTrue(all("io.github.ericcc0321.soulgent.helper" in c for c in self.calls()), self.calls())

    def test_uninstall_default_label(self):
        r = self.run_sh("uninstall.sh")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.calls(), ["bootout gui/%d/io.github.ericcc0321.soulgent.helper" % os.getuid()])


if __name__ == "__main__":
    unittest.main()
