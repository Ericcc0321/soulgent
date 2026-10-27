#!/usr/bin/python3
"""Checks for finder_sessions.py's --lang (pure functions only: no Finder, no xattr, no state). Run: python3 -I finder_lang_check.py"""
import importlib.util, sys, os
here = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("fs", os.path.join(here, "finder_sessions.py"))
fs = importlib.util.module_from_spec(spec); sys.dont_write_bytecode = True; spec.loader.exec_module(fs)
fails = 0
def check(name, ok):
    global fails
    print(("ok   " if ok else "FAIL ") + name)
    fails += 0 if ok else 1

ZH = {"waiting": ("CC-等你处理", 6), "busy": ("CC-在用", 2), "idle": ("CC-空闲", 1)}
check("default (no set_lang) is zh-Hans names, colours and glyphs",
      fs.STATUS == {"waiting": ("CC-等你处理", 6, "🔴"), "busy": ("CC-在用", 2, "🟢"), "idle": ("CC-空闲", 1, "⚪")} and fs.STALE_TAG == ("CC-久未使用", 7))
check("default retires the English and Traditional names, never its own (the stale tag is shared by both Chinese languages)", fs.RETIRED_TAGS == {"CC-Waiting", "CC-Working", "CC-Idle", "CC-Stale", "CC-等你處理", "CC-使用中", "CC-閒置"})
check("zh-Hans comment words", fs.WORDS["closed"](4, ["x", "y"]) == "已关闭 4 个：x、y" and fs.WORDS["closed"](2, []) == "已关闭 2 个"
      and fs.WORDS["gone"](2, ["a", "b"]) == "已清理 2 个：a、b" and fs.WORDS["untitled"] == "未命名")
mine_zh = fs.merge_tags(["Red\n6", "CC-在用\n2", "CC-久未使用\n7"], [("CC-空闲", 1)])
check("zh run keeps the user's tag, drops retired/own, adds the wanted", mine_zh == ["Red\n6", "CC-空闲\n1"])
check("zh run strips English tags too", fs.merge_tags(["CC-Idle\n1", "Blue\n4"], []) == ["Blue\n4"])

fs.set_lang("en")
check("en names and colours", fs.STATUS == {"waiting": ("CC-Waiting", 6, "🔴"), "busy": ("CC-Working", 2, "🟢"), "idle": ("CC-Idle", 1, "⚪")} and fs.STALE_TAG == ("CC-Stale", 7))
check("en retires the Chinese names", fs.RETIRED_TAGS == {"CC-等你处理", "CC-在用", "CC-空闲", "CC-久未使用", "CC-等你處理", "CC-使用中", "CC-閒置"})
swapped = fs.merge_tags(["Mine\n3", "CC-等你处理\n6", "CC-久未使用\n7"], [("CC-Waiting", 6)])
check("a folder tagged in Chinese gets the English tag, same colour, own tag kept, none left over", swapped == ["Mine\n3", "CC-Waiting\n6"])
check("restore (merge with nothing) takes both languages off, only those",
      fs.merge_tags(["CC-Waiting\n6", "CC-等你处理\n6", "CC-Stale\n7", "CC-Other\n1", "Mine\n3"], []) == ["CC-Other\n1", "Mine\n3"])
check("en comment words", fs.WORDS["closed"](4, ["x", "y"]) == "4 closed: x, y" and fs.WORDS["closed"](2, []) == "2 closed"
      and fs.WORDS["gone"](2, ["a", "b"]) == "2 cleaned up: a, b" and fs.WORDS["untitled"] == "Untitled")
check("normalize_lang", [fs.normalize_lang(c) for c in ("en", "en-US", "zh-Hans", "zh_CN", "zh-Hant", "zh-TW", "zh-HK", "zh-Hans-HK", "zh-Hant-TW", "ja")] == ["en", "en", "zh-Hans", "zh-Hans", "zh-Hant", "zh-Hant", "zh-Hant", "zh-Hans", "zh-Hant", None])

# describe(): the same folder in both languages, an untitled live session, closed and cleaned-up ones
from pathlib import Path
folder = Path("/tmp/fake-session/proj"); now = 2_000_000_000.0
live = [{"sessionId": "L1", "cwd": str(folder), "status": "busy"}]
transcripts = {"/t/C1.jsonl": {"cwd": str(folder), "custom": "Closed One", "mtime": now - 100}}
history = {"H1": {"proj": str(folder), "last": now - 50, "text": "first prompt"}}
files = {str(folder): {"newest": now - 10}}
out = {}
for lang in ("zh-Hans", "en"):
    fs.set_lang(lang)
    out[lang] = fs.describe([folder], [folder], live, transcripts, history, files, now)[str(folder)]
check("zh describe: untitled name, closed, cleaned up, in-use tag", "未命名" in out["zh-Hans"][0] and "已关闭 1 个：Closed One" in out["zh-Hans"][0] and "已清理 1 个：first prompt" in out["zh-Hans"][0] and out["zh-Hans"][1] == [("CC-在用", 2)])
check("en describe: Untitled, closed, cleaned up, CC-Working", "Untitled" in out["en"][0] and "1 closed: Closed One" in out["en"][0] and "1 cleaned up: first prompt" in out["en"][0] and out["en"][1] == [("CC-Working", 2)])
check("en describe has no Chinese", not any("一" <= c <= "鿿" for c in out["en"][0] + out["en"][1][0][0]))
print("failures:", fails); sys.exit(1 if fails else 0)
