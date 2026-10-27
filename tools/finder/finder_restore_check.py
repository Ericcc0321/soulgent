#!/usr/bin/python3
"""Checks for finder_sessions.py's backups and --restore, on fakes only: no Finder, no xattr, no state file.

Run: python3 -I finder_restore_check.py
"""
import copy, importlib.util, os, sys, tempfile
here = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("fs", os.path.join(here, "finder_sessions.py"))
fs = importlib.util.module_from_spec(spec); sys.dont_write_bytecode = True; spec.loader.exec_module(fs)
fails = 0
def check(name, ok):
    global fails
    print(("ok   " if ok else "FAIL ") + name)
    fails += 0 if ok else 1


class FakeMac:
    """Folders' tags and comments in memory; osa() answers the three scripts finder_sessions.py sends."""
    def __init__(self, comments, tags=None, deny=False):
        self.comments, self.tags, self.deny = dict(comments), dict(tags or {}), deny
    def osa(self, script, args):
        if self.deny:
            raise RuntimeError("Not authorised to send Apple events to Finder. (-1743)")
        if script == fs.GET_COMMENTS:
            return chr(30).join(self.comments.get(p, "") for p in args)
        if script == fs.SET_COMMENTS:
            for p, c in zip(args[0::2], args[1::2]):
                self.comments[p] = c
            return ""
        return ""
    def install(self):
        fs.osa = self.osa
        fs.read_tags = lambda p: list(self.tags.get(p, []))
        fs.write_tags = lambda p, t: self.tags.__setitem__(p, list(t))


fs.set_lang("en")
with tempfile.TemporaryDirectory() as tmp:
    a, b = os.path.join(tmp, "root", "a"), os.path.join(tmp, "root", "b")
    os.makedirs(a); os.makedirs(b)
    wanted = {a: ("comment from the tool", [("CC-Idle", 1)])}

    # The Automation permission is refused on the first run, so the original comment is never read; a later
    # --restore with the permission given must not write "" over the user's own comment.
    mac = FakeMac({a: "my own note"}, deny=True); mac.install()
    state = {}
    fs.apply(state, wanted)
    check("first run without Automation: tags written, no comment backup", "comment" not in state["orig"].get(a, {}) and "comment" not in state["written"][a])
    mac.deny = False
    fs.restore(state, fs.restore_paths(state, [a]))
    check("restore keeps a comment it never backed up", mac.comments[a] == "my own note")
    check("restore still takes the tool's tags off", mac.tags.get(a, []) == [] and a not in state["written"])

    # The ordinary round trip: backed up, changed, restored.
    mac = FakeMac({a: "before"}); mac.install()
    state = {}
    fs.apply(state, wanted)
    check("normal run: comment backed up then written", state["orig"][a]["comment"] == "before" and mac.comments[a] == "comment from the tool")
    fs.restore(state, fs.restore_paths(state, [a]))
    check("restore puts the backed-up comment back", mac.comments[a] == "before")

    # Backup read but the write failed: nothing to undo, the comment is the user's.
    state = {"orig": {a: {"comment": "before"}}, "written": {a: {"tags": []}}}
    mac = FakeMac({a: "edited by the user since"}); mac.install()
    fs.restore(state, fs.restore_paths(state, [a]))
    check("restore leaves a comment the tool never changed", mac.comments[a] == "edited by the user since")

    # A folder outside this run's roots (another --root, a --dry-run with other roots, an unmounted volume) must not
    # be taken for deleted and have its backup thrown away.
    elsewhere = os.path.join(tmp, "other-root", "c")
    os.makedirs(elsewhere)
    unmounted = os.path.join(tmp, "Volumes-gone", "proj")
    gone = os.path.join(tmp, "root", "deleted")
    rec = lambda c: {"comment": c, "tags": []}
    state = {"orig": {a: rec("A"), elsewhere: rec("C"), unmounted: rec("U"), gone: rec("G")},
             "written": {p: {"comment": "x"} for p in (a, elsewhere, unmounted, gone)},
             "files": {p: {"at": 1} for p in (a, elsewhere, unmounted, gone)}}
    fs.forget_gone(state, {a})
    check("a folder outside this run's roots keeps its backup", elsewhere in state["orig"] and elsewhere in state["written"])
    check("a folder whose volume is not mounted keeps its backup", unmounted in state["orig"] and unmounted in state["written"])
    check("a folder deleted from a reachable parent is forgotten", gone not in state["orig"] and gone not in state["written"])
    check("the scan cache still drops everything outside this run", set(state["files"]) == {a})

    # A folder that cannot be read is not taken for deleted just because its parent is there: the root of a volume that
    # is not mounted (its parent, the volumes folder, is), or a folder whose parent this user may list but not enter.
    # Only a folder confirmed missing from a parent read in full, and not on a volume that is not mounted, is forgotten.
    volumes = os.path.join(tmp, "Volumes"); os.makedirs(volumes)
    vol_root = os.path.join(volumes, "Backup")  # unmounted: no folder of that name left in the volumes folder
    mounted = os.path.join(volumes, "Data"); os.makedirs(mounted)
    vol_gone = os.path.join(mounted, "deleted")
    shut = os.path.join(tmp, "shut"); os.makedirs(os.path.join(shut, "proj"))
    sealed = os.path.join(tmp, "sealed"); os.makedirs(os.path.join(sealed, "proj"))
    in_shut, in_sealed = os.path.join(shut, "proj"), os.path.join(sealed, "proj")
    os.chmod(shut, 0o444)  # listed, not entered: the folder in it cannot be looked at
    os.chmod(sealed, 0o000)  # neither listed nor entered
    fs.VOLUMES, was_mount = volumes, fs.is_mount
    fs.is_mount = lambda q: q == mounted
    try:
        paths = (vol_root, vol_gone, in_shut, in_sealed)
        state = {"orig": {q: rec("V") for q in paths}, "written": {q: {"comment": "x"} for q in paths}, "files": {}}
        fs.forget_gone(state, set())
    finally:
        os.chmod(shut, 0o755); os.chmod(sealed, 0o755); fs.is_mount = was_mount
    check("the root of a volume no longer mounted keeps its backup", vol_root in state["orig"] and vol_root in state["written"])
    check("a folder whose parent can be listed but not entered keeps its backup", in_shut in state["orig"] and in_shut in state["written"])
    check("a folder whose parent cannot be read at all keeps its backup", in_sealed in state["orig"] and in_sealed in state["written"])
    check("a folder deleted on a mounted volume is forgotten", vol_gone not in state["orig"] and vol_gone not in state["written"])

    # --restore without --root works from the recorded folders, wherever they are; --only narrows by name.
    state = {"written": {a: {"comment": "x"}, elsewhere: {"comment": "x"}, unmounted: {"comment": "x"}}}
    check("--restore without --root: every recorded folder that is there", fs.restore_paths(state, None) == sorted([a, elsewhere]))
    check("--restore --only without --root: by folder name", fs.restore_paths(state, None, only={"c"}) == [elsewhere])
    check("--restore --root: the scanned folders that were written", fs.restore_paths(state, [a, b]) == [a])

    # --dry-run keeps the scan caches but no change to the backups reaches the disk.
    fs.STATE_DIR = __import__("pathlib").Path(tmp) / "state"; fs.STATE_DIR.mkdir()
    fs.STATE_FILE = fs.STATE_DIR / "state.json"; fs.ORIGINALS_FILE = fs.STATE_DIR / "original-metadata.json"
    saved = {"orig": {gone: rec("G")}, "written": {gone: {"comment": "x"}}, "files": {}}
    fs.save_state(copy.deepcopy(saved))
    loaded = fs.load_state()
    loaded["orig"].clear(); loaded["written"].clear(); loaded["files"]["new"] = {"at": 2}
    fs.save_state(loaded, keep_backups=True)
    after = fs.load_state()
    check("--dry-run save keeps the backups on disk as they were", after["orig"] == saved["orig"] and after["written"] == saved["written"]
          and __import__("json").loads(fs.ORIGINALS_FILE.read_text()) == saved["orig"])
    check("--dry-run save still keeps the scan caches", after["files"] == {"new": {"at": 2}})

    def rescan(state, folders):
        """What a run does with its scan before anything is written: follow moved folders, then forget gone ones."""
        getattr(fs, "relink", lambda s, f: None)(state, folders)
        fs.forget_gone(state, {str(f) for f in folders})

    tags = [("CC-Idle", 1)]

    # A renamed folder keeps the backup of its original comment: it is followed by its identity, not its path.
    r4 = os.path.join(tmp, "r4"); old, new = os.path.join(r4, "old"), os.path.join(r4, "new"); os.makedirs(old)
    mac = FakeMac({old: "important original note"}); mac.install()
    state = {}
    rescan(state, [old]); fs.apply(state, {old: ("generated", tags)})
    os.rename(old, new); mac.comments[new] = mac.comments.pop(old)
    rescan(state, [new]); fs.apply(state, {new: ("generated again", tags)})
    check("a renamed folder's backup follows it to the new path", state.get("orig", {}).get(new, {}).get("comment") == "important original note")
    fs.restore(state, fs.restore_paths(state, [new]))
    check("restore after a rename puts the original comment back", mac.comments[new] == "important original note")

    # A folder moved out of every root keeps its backup as an orphan, and gets it back when it comes back under a new name.
    r4b = os.path.join(tmp, "r4b"); out = os.path.join(tmp, "r4-outside"); os.makedirs(os.path.join(r4b, "p")); os.makedirs(out)
    p0, p_out, p_back = os.path.join(r4b, "p"), os.path.join(out, "p"), os.path.join(r4b, "back")
    mac = FakeMac({p0: "kept note"}); mac.install()
    state = {}
    rescan(state, [p0]); fs.apply(state, {p0: ("generated", tags)})
    os.rename(p0, p_out); mac.comments[p_out] = mac.comments.pop(p0)
    rescan(state, [])
    check("a folder moved out of every root keeps its backup as an orphan",
          any(o.get("orig", {}).get("comment") == "kept note" for o in state.get("orphans", [])))
    os.rename(p_out, p_back); mac.comments[p_back] = mac.comments.pop(p_out)
    rescan(state, [p_back]); fs.apply(state, {p_back: ("generated again", tags)})
    fs.restore(state, fs.restore_paths(state, [p_back]))
    check("an orphan backup goes back to its folder when it reappears", mac.comments[p_back] == "kept note")

    # A volume mounted again can give its folders another device number: a record at the same path with the same inode
    # takes the new one, and the folder is still followed through a rename.
    r4e = os.path.join(tmp, "r4e"); d0, d1 = os.path.join(r4e, "d"), os.path.join(r4e, "renamed"); os.makedirs(d0)
    mac = FakeMac({d0: "dev note"}); mac.install()
    state = {}
    rescan(state, [d0]); fs.apply(state, {d0: ("generated", tags)})
    state["orig"][d0]["id"][0] += 1  # as after a remount
    rescan(state, [d0]); fs.apply(state, {d0: ("generated again", tags)})
    check("a record with the same inode takes the folder's new device number", state["orig"][d0]["id"] == fs.folder_id(d0))
    os.rename(d0, d1); mac.comments[d1] = mac.comments.pop(d0)
    rescan(state, [d1]); fs.apply(state, {d1: ("generated once more", tags)})
    check("a folder whose device number changed is still followed through a rename", state["orig"].get(d1, {}).get("comment") == "dev note")

    # A comment in the form the tool writes is never saved as a folder's original.
    tool_like = os.path.join(tmp, "r4c", "t"); os.makedirs(tool_like)
    fake_tool = fs.mono("26/10/05") + " │" + fs.mono(1) + "/" + fs.mono(2) + fs.FIGURE_SPACE + "│ ⚪ x"
    mac = FakeMac({tool_like: fake_tool}); mac.install()
    state = {}
    rescan(state, [tool_like]); fs.apply(state, {tool_like: ("generated", tags)})
    check("a comment in the tool's own form is not backed up as the original", state["orig"][tool_like].get("comment") != fake_tool)

    # A backup kept without identity is matched by the comment the tool wrote there.
    legacy_old, legacy_new = os.path.join(tmp, "legacy-dir", "gone"), os.path.join(tmp, "legacy-dir", "here"); os.makedirs(legacy_new)
    mac = FakeMac({legacy_new: "generated legacy"}); mac.install()
    state = {"orig": {legacy_old: {"comment": "legacy original", "tags": []}}, "written": {legacy_old: {"comment": "generated legacy"}}}
    rescan(state, [legacy_new]); fs.apply(state, {legacy_new: ("generated", tags)})
    check("a backup without identity is matched by the comment the tool wrote", state["orig"][legacy_new].get("comment") == "legacy original")

    # A successful restore ends the backup: a later run backs up the comment the user wrote since.
    r5 = os.path.join(tmp, "r5", "f"); os.makedirs(r5)
    mac = FakeMac({r5: "A"}); mac.install()
    state = {}
    fs.apply(state, {r5: ("generated", tags)}); fs.restore(state, fs.restore_paths(state, [r5]))
    check("a successful restore drops that folder's backup", r5 not in state.get("orig", {}) and r5 not in state.get("written", {}))
    mac.comments[r5] = "B"
    fs.apply(state, {r5: ("generated", tags)}); fs.restore(state, fs.restore_paths(state, [r5]))
    check("restore after re-enabling puts back the newer user comment", mac.comments[r5] == "B")
    # A restore that fails keeps the backup and the record of what was written.
    fs.apply(state, {r5: ("generated", tags)})
    mac.deny = True
    try:
        fs.restore(state, fs.restore_paths(state, [r5]))
    except Exception:
        pass
    check("a failed restore keeps the backup and the written record",
          state["orig"].get(r5, {}).get("comment") == "B" and state["written"].get(r5, {}).get("comment") == "generated")

    # A batch write that stops part way: the folders already written are known to --restore.
    class StopsAfter(FakeMac):
        def __init__(self, comments, after, readable=True):
            super().__init__(comments); self.after, self.readable, self.stopped = after, readable, False
        def osa(self, script, args):
            if script == fs.SET_COMMENTS and len(args) > 2 * self.after and not self.stopped:
                for p, c in list(zip(args[0::2], args[1::2]))[:self.after]:
                    self.comments[p] = c
                self.stopped = True
                raise RuntimeError("Finder got an error: Can't get folder. (-1728)")
            if script == fs.GET_COMMENTS and self.stopped and not self.readable:
                raise RuntimeError("AppleEvent timed out. (-1712)")
            return super().osa(script, args)
    r6 = os.path.join(tmp, "r6"); x6, y6 = os.path.join(r6, "x"), os.path.join(r6, "y"); os.makedirs(x6); os.makedirs(y6)
    for readable in (True, False):
        mac = StopsAfter({x6: "X", y6: "Y"}, 1, readable); mac.install()
        state, saved_before = {}, []
        try:
            fs.apply(state, {x6: ("generated x", tags), y6: ("generated y", tags)}, persist=lambda: saved_before.append(copy.deepcopy(state)))
        except TypeError:  # an apply that cannot save before writing
            fs.apply(state, {x6: ("generated x", tags), y6: ("generated y", tags)})
        check(f"a partial batch write ({'read back' if readable else 'unreadable after the failure'}) changed the first folder only",
              mac.comments[x6] == "generated x" and mac.comments[y6] == "Y")
        how = "read back" if readable else "unreadable after the failure"
        check(f"a partial batch write ({how}) is saved with its backups before writing",
              bool(saved_before) and saved_before[0].get("orig", {}).get(x6, {}).get("comment") == "X"
              and saved_before[0].get("written", {}).get(x6, {}).get("pending") == "generated x")
        fs.restore(state, fs.restore_paths(state, [x6, y6]))
        check(f"restore after a partial batch write ({how}) puts the written folder back", mac.comments[x6] == "X" and mac.comments[y6] == "Y")

print("failures:", fails); sys.exit(1 if fails else 0)
