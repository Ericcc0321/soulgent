"""Push text (WeChat style): title = per-session emoji + full session name, body = the message itself (no "[event]" label for waiting / done;
error / limit read "Error: ..." / "Limit reached: ..."); empty content / content synonymous with the label writes only the full event word; timestamp = event time; Chrome-family endpoints carry the session avatar av (Apple endpoints do not)."""
import unittest

from api import notify as N

LANGS = ("en", "hans", "hant")


def fire(sess, body_fn, zones=None):
    """Run step through: baseline -> appearance -> past the delay, and return the action that was pushed."""
    st, _ = N.step(N.new_state(), [], 0, body_fn, zones)
    st, _ = N.step(st, [sess], 10, body_fn, zones)
    _, acts = N.step(st, [sess], 30, body_fn, zones)
    assert len(acts) == 1, acts
    return acts[0]


def W(**kw):
    d = {"id": "a", "name": "Ops-demo-calc", "zone": "Ops", "status": "waiting", "since": 1700000000.5}
    d.update(kw)
    return d


def D(**kw):
    return W(status="idle", unread=True, **kw)


def loc(act):
    return {lg: N.localize(act, lg) for lg in LANGS}


class TitleTest(unittest.TestCase):
    def test_title_is_full_name_all_langs(self):
        a = fire(W(), lambda s, k: "改不改？")
        self.assertEqual({lg: x["title"] for lg, x in loc(a).items()},
                         {"en": "🔥 Ops-demo-calc", "hans": "🔥 Ops-demo-calc", "hant": "🔥 Ops-demo-calc"})
        self.assertEqual(a["title"], "🔥 Ops-demo-calc")  # Simplified Chinese version (log, old subscriptions)

    def test_lead_has_no_star_and_zone_not_reformatted(self):
        zones = [{"code": "Ops", "color": "#fff", "lead": "Ops-demo-calc"}]
        a = fire(W(), lambda s, k: "q", zones)
        for x in loc(a).values():
            self.assertEqual(x["title"], "🔥 Ops-demo-calc")
            self.assertNotIn("★", x["title"])

    def test_untitled_per_lang(self):
        a = fire(W(name="未命名", nameUntitled=True), lambda s, k: "q")
        self.assertEqual({lg: x["title"] for lg, x in loc(a).items()},
                         {"en": "🔥 Untitled", "hans": "🔥 未命名", "hant": "🔥 未命名"})

    def test_name_fallbacks(self):
        a = fire(W(name="", project="Proj"), lambda s, k: "q")
        self.assertEqual(N.localize(a, "en")["title"], "🔥 Proj")


class BodyTest(unittest.TestCase):
    def test_wait_untagged_three_langs(self):
        s = W(summary="问你：要不要挪？", summaryCode="wait.ask", summaryArgs={"question": "要不要挪？"})
        a = fire(s, lambda s, k: N.wait_body(s, []))
        self.assertEqual({lg: x["body"] for lg, x in loc(a).items()},
                         {"en": "Asks: 要不要挪？", "hans": "问你：要不要挪？",
                          "hant": "問你：要不要挪？"})

    def test_wait_approve(self):
        s = W(summaryCode="wait.approve.run", summaryArgs={"command": "docker compose up -d"})
        a = fire(s, lambda s, k: N.wait_body(s, []))
        self.assertEqual({lg: x["body"] for lg, x in loc(a).items()},
                         {"en": "Approve to run: docker compose up -d",
                          "hans": "等你批准运行：docker compose up -d",
                          "hant": "等你核准執行：docker compose up -d"})

    def test_wait_fallback(self):
        a = fire(W(), lambda s, k: N.FALLBACK_WAIT)
        self.assertEqual({lg: x["body"] for lg, x in loc(a).items()},
                         {"en": "Waiting for your decision", "hans": "在等你决定", "hant": "在等你決定"})

    def test_wait_raw_text_not_translated(self):
        a = fire(W(), lambda s, k: "新题 二题")
        self.assertEqual(N.localize(a, "en")["body"], "新题 二题")
        self.assertEqual(N.localize(a, None)["body"], "新题 二题")

    def test_wait_transcript_question_reads_asks(self):
        items = [{"role": "ask", "questions": [{"question": "改不改？"}]}]
        a = fire(W(), lambda s, k: N.wait_body(s, items))
        self.assertEqual({lg: x["body"] for lg, x in loc(a).items()},
                         {"en": "Asks: 改不改？", "hans": "问你：改不改？", "hant": "問你：改不改？"})
        self.assertNotIn("ask", N.localize(a, "en"))  # internal marker is not sent

    def test_wait_pending_tool_text_as_is(self):
        items = [{"role": "tool", "pending": True, "text": "Bash rm x"}]
        a = fire(W(), lambda s, k: N.wait_body(s, items))
        self.assertEqual({x["body"] for x in loc(a).values()}, {"Bash rm x"})

    def test_done_no_tag_reply_text(self):
        a = fire(D(), lambda s, k: "夜间补抓第一晚补完")
        self.assertEqual({x["body"] for x in loc(a).values()}, {"夜间补抓第一晚补完"})

    def test_done_fallback_full_word(self):
        a = fire(D(), lambda s, k: N.done_body([]))
        self.assertEqual({lg: x["body"] for lg, x in loc(a).items()},
                         {"en": "Done", "hans": "干完了", "hant": "完成了"})

    def test_workbuddy_error_synonym_full_word(self):
        s = D(summary="出错", summaryCode="state.error")
        a = fire(s, lambda s, k: N.wait_body(s, []))
        self.assertEqual(a["ev"], "err")
        self.assertEqual({lg: x["body"] for lg, x in loc(a).items()},
                         {"en": "Error", "hans": "出错了", "hant": "出錯了"})
        self.assertEqual(N.localize(a, "en")["title"], "🔥 Ops-demo-calc")

    def test_workbuddy_stopped_full_word(self):
        s = D(summary="已中止", summaryCode="state.stopped")
        a = fire(s, lambda s, k: N.wait_body(s, []))
        self.assertEqual({lg: x["body"] for lg, x in loc(a).items()},
                         {"en": "Stopped", "hans": "已中止", "hant": "已中止"})

    def test_err_with_real_content_is_prefixed(self):
        s = D(summaryCode="state.error")
        a = fire(s, lambda s, k: "API 出错 529：Overloaded")
        a = dict(a, fb=False)  # errorKind with content: label + content
        self.assertEqual({lg: x["body"] for lg, x in loc(a).items()},
                         {"en": "Error: API 出错 529：Overloaded", "hans": "出错：API 出错 529：Overloaded",
                          "hant": "出錯：API 出错 529：Overloaded"})

    def test_api_error_status_body_has_single_error_word(self):
        s = D(errorKind="api", errorStatus=529, errorText="API Error: 529 Overloaded", errorSince=10,
              summaryCode="state.apiError", summaryArgs={"kind": "api", "status": 529, "text": "Overloaded"})
        a = fire(s, lambda s, k: N.wait_body(s, []))
        self.assertEqual({lg: x["body"] for lg, x in loc(a).items()},
                         {"en": "Error 529: Overloaded", "hans": "出错 529：Overloaded", "hant": "出錯 529：Overloaded"})
        self.assertNotIn("apiErr", N.localize(a, "en"))

    def test_api_error_without_status_uses_err_body(self):
        s = D(errorKind="api", errorText="Overloaded", errorSince=10,
              summaryCode="state.apiError", summaryArgs={"kind": "api", "status": None, "text": "Overloaded"})
        a = fire(s, lambda s, k: N.wait_body(s, []))
        self.assertEqual({lg: x["body"] for lg, x in loc(a).items()},
                         {"en": "Error: Overloaded", "hans": "出错：Overloaded", "hant": "出錯：Overloaded"})

    def test_api_error_auth_unchanged(self):
        s = D(errorKind="api", errorSince=10, summaryCode="state.apiError",
              summaryArgs={"kind": "auth", "status": 401, "text": "bad key"})
        a = fire(s, lambda s, k: N.wait_body(s, []))
        self.assertEqual(a["ev"], "err")
        self.assertNotIn("apiErr", a)
        self.assertNotIn("401", N.localize(a, "hans")["body"].replace("出错", ""))  # auth keeps its fixed line

    def test_limit_with_content_is_prefixed(self):
        a = fire(D(), lambda s, k: "resets 1pm")
        a = dict(a, ev="limit", fb=False)
        self.assertEqual({lg: x["body"] for lg, x in loc(a).items()},
                         {"en": "Limit reached: resets 1pm", "hans": "额度用完：resets 1pm", "hant": "額度用完：resets 1pm"})

    def test_lost_and_stopped_fallback_unchanged(self):
        for ev, want in (("lost", {"en": "Exited unexpectedly", "hans": "意外退出", "hant": "意外結束"}),
                         ("stopped", {"en": "Stopped", "hans": "已中止", "hant": "已中止"})):
            a = dict(fire(D(), lambda s, k: "x"), ev=ev, fb=True)
            self.assertEqual({lg: x["body"] for lg, x in loc(a).items()}, want, ev)

    def test_body_error_fallbacks(self):
        def boom(s, k):
            raise OSError("x")
        self.assertEqual(N.localize(fire(W(), boom), "hans")["body"], "在等你决定")
        self.assertEqual(N.localize(fire(D(), boom), "hans")["body"], "干完了")

    def test_content_clipped(self):
        a = fire(W(), lambda s, k: "字" * 300)
        b = N.localize(a, "hans")["body"]
        self.assertEqual(len(b), N.MAX_BODY)
        self.assertTrue(b.endswith("…"))


class PayloadTest(unittest.TestCase):
    def test_timestamp_is_event_time_ms(self):
        a = fire(W(), lambda s, k: "q")
        self.assertEqual(a["timestamp"], 1700000000500)
        self.assertEqual(N.localize(a, "en")["timestamp"], 1700000000500)

    def test_timestamp_falls_back_to_now(self):
        a = fire(W(since=None), lambda s, k: "q")
        self.assertEqual(a["timestamp"], 30000)

    def test_avatar_only_for_non_apple(self):
        a = fire(W(pet="Boba"), lambda s, k: "q")
        self.assertEqual(a["av"], {"id": "a", "pet": "Boba", "st": "wait"})
        self.assertEqual(N.localize(a, "en", icon=True)["av"], {"id": "a", "pet": "Boba", "st": "wait"})
        self.assertNotIn("av", N.localize(a, "en"))  # omitted by default (Apple platforms ignore the icon, so avoid a wasted image fetch)
        d = fire(D(), lambda s, k: "x")
        self.assertEqual(d["av"], {"id": "a", "st": "done"})

    def test_payload_keys(self):
        a = fire(W(), lambda s, k: "q")
        self.assertEqual(set(N.localize(a, "en")), {"kind", "tag", "title", "body", "url", "timestamp"})
        self.assertEqual(set(N.localize(a, "en", icon=True)), {"kind", "tag", "title", "body", "url", "timestamp", "av"})

    def test_mac_link_text(self):
        a = N.link_action("down", "panel", "14:05")
        self.assertEqual(N.localize(a, "hans")["title"], "Mac 已断开")
        self.assertEqual(N.localize(a, "hans")["body"], "Soulgent 没响应，数据截至 14:05")
        self.assertNotIn("av", N.localize(a, "en", icon=True))
        up = N.link_action("up", None, None)
        self.assertEqual({lg: (N.localize(up, lg)["title"], N.localize(up, lg)["body"]) for lg in LANGS},
                         {"en": ("Mac reconnected", "Data is live again"), "hans": ("Mac 已恢复", "数据已更新"),
                          "hant": ("Mac 已恢復連線", "資料已更新")})


def fire_p(sess, pets):
    st, _ = N.step(N.new_state(), [], 0, lambda s, k: "q")
    st, _ = N.step(st, [sess], 10, lambda s, k: "q", pets=pets)
    _, acts = N.step(st, [sess], 30, lambda s, k: "q", pets=pets)
    assert len(acts) == 1, acts
    return acts[0]


class EmojiTest(unittest.TestCase):
    def test_palette_48_unique_without_flame(self):
        self.assertEqual(len(N.PET_EMOJI), 48)
        self.assertEqual(len(set(N.PET_EMOJI)), 48)
        self.assertNotIn(N.FLAME_EMOJI, N.PET_EMOJI)
        self.assertEqual(N.FLAME_EMOJI, "🔥")

    def test_js_hash_matches_app_js(self):
        # values from node: app.js hash() / sw.js swHash()
        self.assertEqual(N.js_hash("a-tom"), 250933827)
        self.assertEqual(N.js_hash("3f1c2b9e-1111-4222-8333-abcdefabcdef"), 684012993)
        self.assertEqual(N.js_hash("宠物😀x"), 998937725)  # UTF-16 code units, surrogate pair included
        self.assertEqual(N.js_hash(""), 5381)

    def test_stable_per_pet(self):
        e = N.pet_emoji("boba")
        self.assertIn(e, N.PET_EMOJI)
        self.assertEqual(e, N.pet_emoji("boba"))
        self.assertEqual(e, N.PET_EMOJI[N.js_hash("boba") % 48])
        self.assertGreater(len({N.pet_emoji("pet-%d" % i) for i in range(100)}), 30)  # spread over the palette

    def test_no_pet_is_flame(self):
        self.assertEqual(N.pet_emoji(None), "🔥")
        self.assertEqual(N.session_emoji({}, "a"), "🔥")
        self.assertEqual(N.session_emoji({}, "a", {"names": [], "emoji": None}), "🔥")

    def test_override(self):
        self.assertEqual(N.pet_emoji("boba", {"boba": "🧋"}), "🧋")
        self.assertEqual(N.pet_emoji("boba", {"boba": ""}), N.pet_emoji("boba"))  # empty / non-string / too long -> palette
        self.assertEqual(N.pet_emoji("boba", {"boba": 3}), N.pet_emoji("boba"))
        self.assertEqual(N.pet_emoji("boba", {"boba": "x" * 40}), N.pet_emoji("boba"))

    def test_effective_pet_follows_list_avatar(self):
        names = ["akaza", "boba", "cat"]
        self.assertEqual(N.effective_pet({"pet": "boba"}, "a", names), "boba")
        self.assertEqual(N.effective_pet({"pet": "gone"}, "a", names), names[N.js_hash("a") % 3])  # uninstalled -> hash pick
        self.assertEqual(N.effective_pet({}, "a", names), names[N.js_hash("a") % 3])
        self.assertEqual(N.effective_pet({"pet": "boba"}, "a", None), "boba")  # manifest unknown: assigned pet still counts
        self.assertIsNone(N.effective_pet({}, "a", None))

    def test_title_uses_pet_emoji_and_override(self):
        a = fire_p(W(pet="boba"), {"names": ["boba"], "emoji": None})
        self.assertEqual(N.localize(a, "en")["title"], N.pet_emoji("boba") + " Ops-demo-calc")
        a = fire_p(W(pet="boba"), {"names": ["boba"], "emoji": {"boba": "🧋"}})
        self.assertEqual({lg: x["title"] for lg, x in loc(a).items()},
                         {"en": "🧋 Ops-demo-calc", "hans": "🧋 Ops-demo-calc", "hant": "🧋 Ops-demo-calc"})
        self.assertNotIn("emoji", N.localize(a, "en"))  # internal field is not sent

    def test_untitled_keeps_emoji(self):
        a = fire_p(W(name="未命名", nameUntitled=True, pet="boba"), {"names": ["boba"], "emoji": {"boba": "🧋"}})
        self.assertEqual(N.localize(a, "en")["title"], "🧋 Untitled")


if __name__ == "__main__":
    unittest.main()
