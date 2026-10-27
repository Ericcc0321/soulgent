import json
import os
import tempfile
import unittest

from helper.zones import FX_KINDS, ZoneConfig, load_zone_config

HOME = "/Users/u"

ZONES = {
    "Docs": {"name": "文档组", "color": "#4A90D9", "order": 1, "lead": "Docs 负责人", "desc": ""},
    "Web": {"name": "前端组", "color": "#E67E22", "order": 2, "lead": None, "desc": ""},
    "Infra": {"name": "基础设施", "color": "#27AE60", "order": 3, "lead": None, "desc": ""},
    "Lab": {"name": "实验", "color": "#8E44AD", "order": 4, "lead": None, "desc": ""},
}

DIRS = {
    "~/projects/api-gateway": "Web",
    "~/projects/api-gateway/docs": "Docs",
}

GATEWAY = "/Users/u/projects/api-gateway"


def make_config(default=None):
    return ZoneConfig.parse({"default": default, "zones": ZONES, "dirs": DIRS}, home=HOME)


def write(path, obj):
    with open(path, "w", encoding="utf-8") as f:
        f.write(obj if isinstance(obj, str) else json.dumps(obj, ensure_ascii=False))


class ZoneConfigTest(unittest.TestCase):
    def setUp(self):
        self.cfg = make_config()

    def test_prefix_wins(self):
        self.assertEqual(self.cfg.resolve("Docs-wiki-demo", "/Users/u/projects/api-gateway"), "Docs")

    def test_longest_dir_match(self):
        self.assertEqual(self.cfg.resolve("x", "/Users/u/projects/api-gateway/docs/sub"), "Docs")
        self.assertEqual(self.cfg.resolve("x", GATEWAY), "Web")

    def test_dir_match_is_path_boundary(self):
        self.assertIsNone(self.cfg.resolve("x", "/Users/u/projects/api-gateway2"))

    def test_unknown_prefix_falls_back_to_dir(self):
        self.assertEqual(self.cfg.resolve("Foo-bar", GATEWAY), "Web")
        self.assertIsNone(self.cfg.resolve("MAC", None))

    def test_default_used_when_nothing_matches(self):
        cfg_with_default = make_config(default="Lab")
        self.assertEqual(cfg_with_default.resolve("网络拓扑", "/tmp"), "Lab")

    def test_unknown_default_is_treated_as_none(self):
        cfg = make_config(default="Nope")
        self.assertIsNone(cfg.resolve("网络拓扑", "/tmp"))

    def test_plate_strips_zone_prefix_only(self):
        self.assertEqual(self.cfg.plate("Docs-wiki-demo"), "wiki-demo")
        self.assertEqual(self.cfg.plate("Foo-bar"), "Foo-bar")
        self.assertEqual(self.cfg.plate("MAC"), "MAC")

    def test_zones_public_sorted_by_order(self):
        self.assertEqual([z["code"] for z in self.cfg.zones_public()], ["Docs", "Web", "Infra", "Lab"])

    def test_zones_public_has_only_public_fields(self):
        first = self.cfg.zones_public()[0]
        self.assertEqual(set(first.keys()), {"code", "name", "color", "order", "lead", "short", "fx"})
        self.assertEqual(first["name"], "文档组")
        self.assertEqual(first["lead"], "Docs 负责人")
        # no short name / effect configured means None (the frontend falls back to name / the pet frame)
        self.assertIsNone(first["short"])
        self.assertIsNone(first["fx"])

    def test_short_and_fx_from_workzones_entry(self):
        zones = dict(ZONES, Web=dict(ZONES["Web"], short="FE", fx="circuit"))
        cfg = ZoneConfig.parse({"zones": zones}, home=HOME)
        web = [z for z in cfg.zones_public() if z["code"] == "Web"][0]
        self.assertEqual((web["short"], web["fx"]), ("FE", "circuit"))

    def test_bad_short_and_unknown_fx_are_dropped(self):
        zones = {"Web": {"short": 5, "fx": "fireworks"}, "Lab": {"short": "  ", "fx": "orbit"}}
        cfg = ZoneConfig.parse({"zones": zones}, home=HOME)
        got = {z["code"]: (z["short"], z["fx"]) for z in cfg.zones_public()}
        self.assertEqual(got, {"Web": (None, None), "Lab": (None, "orbit")})

    def test_fx_kinds_are_neutral_names(self):
        self.assertEqual(set(FX_KINDS), {"marquee", "circuit", "halo", "orbit"})

    def test_style_overrides_entry(self):
        zones = dict(ZONES, Web=dict(ZONES["Web"], short="FE", fx="circuit"))
        style = {"Web": {"short": "前端", "fx": "halo"}, "Lab": {"fx": "orbit"}, "Gone": {"fx": "halo"}, "Infra": "bad"}
        cfg = ZoneConfig.parse({"zones": zones}, home=HOME, style=style)
        got = {z["code"]: (z["short"], z["fx"]) for z in cfg.zones_public()}
        self.assertEqual(got, {"Docs": (None, None), "Web": ("前端", "halo"), "Infra": (None, None), "Lab": (None, "orbit")})

    def test_load_merges_style_file_and_reloads_when_it_changes(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "workzones.json")
            style = os.path.join(tmp, "zone-style.json")
            write(path, {"zones": ZONES})
            write(style, {"Infra": {"short": "通用", "fx": "halo"}})
            cfg = load_zone_config(path, HOME, style)
            infra = [z for z in cfg.zones_public() if z["code"] == "Infra"][0]
            self.assertEqual((infra["short"], infra["fx"]), ("通用", "halo"))
            write(style, {"Infra": {"short": "共用的", "fx": "marquee"}})
            os.utime(style, (1, 1))  # re-read when mtime changes (independent of workzones.json changing)
            cfg = load_zone_config(path, HOME, style)
            infra = [z for z in cfg.zones_public() if z["code"] == "Infra"][0]
            self.assertEqual((infra["short"], infra["fx"]), ("共用的", "marquee"))

    def test_missing_or_bad_style_file_is_ignored(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "workzones.json")
            write(path, {"zones": ZONES})
            cfg = load_zone_config(path, HOME, os.path.join(tmp, "nope.json"))
            self.assertEqual(len(cfg.zones_public()), 4)
            bad = os.path.join(tmp, "bad.json")
            write(bad, "[1, 2")
            cfg = load_zone_config(path, HOME, bad)
            self.assertEqual([z["fx"] for z in cfg.zones_public()], [None] * 4)

    def test_load_missing_file_gives_empty_config(self):
        with tempfile.TemporaryDirectory() as tmp:
            cfg = load_zone_config(os.path.join(tmp, "missing.json"), HOME)
        self.assertEqual(cfg.zones_public(), [])
        self.assertIsNone(cfg.resolve("Docs-x", GATEWAY))

    def test_load_reads_file_and_ignores_comment_key(self):
        data = {"_说明": "ignored", "default": None, "zones": ZONES, "dirs": DIRS}
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "workzones.json")
            write(path, data)
            cfg = load_zone_config(path, HOME)
        self.assertEqual(cfg.resolve("x", GATEWAY), "Web")

    def test_non_dict_zones_and_dirs_are_treated_as_empty(self):
        cfg = ZoneConfig.parse({"zones": ["a"], "dirs": ["x"]}, home=HOME)
        self.assertEqual(cfg.zones_public(), [])
        self.assertIsNone(cfg.resolve("x", GATEWAY))
        mixed = ZoneConfig.parse({"zones": {"Docs": "bad"}, "dirs": {GATEWAY: "Web"}, "default": None}, home=HOME)
        self.assertEqual([z["code"] for z in mixed.zones_public()], ["Docs"])
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "workzones.json")
            write(path, '{"zones": ["a"], "dirs": ["x"]}')
            cfg = load_zone_config(path, HOME)
        self.assertEqual(cfg.zones_public(), [])

    def test_non_finite_order_sorts_last(self):
        text = '{"zones": {"Inf": {"order": Infinity}, "NaN": {"order": NaN}, "One": {"order": 1}}}'
        cfg = ZoneConfig.parse(json.loads(text), home=HOME)
        self.assertEqual([z["code"] for z in cfg.zones_public()], ["One", "Inf", "NaN"])
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "workzones.json")
            write(path, text)
            loaded = load_zone_config(path, HOME)
        self.assertEqual(loaded.zones_public()[0]["code"], "One")

    def test_huge_int_order_does_not_crash(self):
        text = '{"zones": {"Huge": {"order": 1%s}, "One": {"order": 1}}}' % ("0" * 400)
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "workzones.json")
            write(path, text)
            loaded = load_zone_config(path, HOME)
        self.assertEqual([z["code"] for z in loaded.zones_public()], ["One", "Huge"])

    def test_deeply_nested_json_gives_empty_config(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "workzones.json")
            write(path, "[" * 100000)
            loaded = load_zone_config(path, HOME)
        self.assertEqual(loaded.zones_public(), [])


if __name__ == "__main__":
    unittest.main()
