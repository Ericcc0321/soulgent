// Three-language string table (en English / hans Simplified Chinese / hant Traditional Chinese, Taiwan usage) plus language
// detection. Shared by browser and node; imports no other module (logic.js, app.js and viewer.js import it).
// UI Chinese may appear only in this file (residue scan in web/tests/i18n.test.mjs).
// Detection: a manual choice in localStorage zbs.lang wins; otherwise the first of navigator.languages: zh-TW / zh-HK / zh-MO / zh-Hant* → hant,
// other zh* → hans, everything else en. Missing entries: hant falls back to hans then en, hans to en; if en is missing too, the key is returned (tests catch it).
// Switching language = write localStorage and reload the page (app.js caches too much DOM for a live switch).

export const LANGS = ["en", "hans", "hant"];
export const LANG_KEY = "zbs.lang";
const COL = { en: 0, hans: 1, hant: 2 };

// One key, three columns: [en, hans, hant]. Placeholders like {n} and {name} are filled by t() via vars, never concatenated in code
const STR = {
  // ---------- General ----------
  // ---------- General ----------
  "c.cancel": ["Cancel", "取消", "取消"],
  "c.close": ["Close", "关闭", "關閉"],
  "c.retry": ["Retry", "重试", "重試"],
  "c.copy": ["Copy", "复制", "複製"],
  "c.copied": ["Copied", "已复制", "已複製"],
  "c.copyFail": ["Copy failed", "复制失败", "複製失敗"],
  "c.save": ["Save", "保存", "儲存"],
  "c.saved": ["Saved", "已保存", "已儲存"],
  "c.search": ["Search", "搜索", "搜尋"],
  "c.loading": ["Loading…", "正在加载…", "正在載入…"],
  "c.loadFail": ["Couldn't load", "加载失败", "載入失敗"],
  "c.opFail": ["Something went wrong, try again later", "操作失败，请稍后再试", "操作失敗，請稍後再試"],
  "c.netDown": ["Network down, try again later", "网络不通，请稍后再试", "網路不通，請稍後再試"],
  "c.file": ["File", "文件", "檔案"],
  "c.image": ["Image", "图片", "圖片"],
  "c.webpage": ["Web page", "网页", "網頁"],
  "c.fileGone": ["File no longer exists", "文件已不在", "檔案已不在"],
  "c.other": ["Other", "其他", "其他"],
  "c.all": ["All", "全部", "全部"],
  "c.me": ["Me", "我", "我"],
  "c.admin": ["Admin", "管理员", "管理員"],
  "c.adminInitial": ["A", "管", "管"],
  "c.guest": ["Guest", "访客", "訪客"],
  "c.subagent": ["Subagent", "子代理", "子代理"],
  "c.unzoned": ["No zone", "未分区", "未分區"],
  "c.peer": ["Between sessions", "会话间", "會話之間"],
  "c.on": ["On", "开", "開"],
  "c.off": ["Off", "关", "關"],
  "c.collapse": ["Show less", "收起", "收起"],
  "c.expand": ["Show more", "展开", "展開"],
  // ---------- Time ----------
  "time.justNow": ["Just now", "刚刚", "剛剛"],
  "time.min": ["{n} min", "{n} 分钟", "{n} 分鐘"],
  "time.hour": ["{n} h", "{n} 小时", "{n} 小時"],
  "time.day": ["{n} d", "{n} 天", "{n} 天"],
  "time.yesterday": ["Yesterday", "昨天", "昨天"],
  "time.tomorrow": ["Tomorrow", "明天", "明天"],
  "time.ago": ["{t} ago", "{t}前", "{t}前"],
  "time.secAgo": ["{n}s ago", "{n} 秒前", "{n} 秒前"],
  "time.minAgo": ["{n} min ago", "{n} 分钟前", "{n} 分鐘前"],
  "time.hourAgo": ["{n} h ago", "{n} 小时前", "{n} 小時前"],
  // ---------- Send-failure reasons (code from helper / server) ----------
  "fail.helper-timeout": ["The Mac helper isn't responding", "Mac 小帮手没响应", "Mac 小幫手沒有回應"],
  "fail.no-terminal": ["Can't find this session's Orca terminal", "找不到这个会话的 Orca 终端", "找不到這個會話的 Orca 終端機"],
  "fail.session-gone": ["Session has ended", "会话已结束", "會話已結束"],
  "fail.orca-failed": ["Orca didn't accept it", "Orca 没接收", "Orca 沒有接收"],
  "fail.not-claude": ["Replies aren't supported for this kind of session", "此类会话暂不支持回复", "這類會話暫不支援回覆"],
  "fail.helper-restarted": ["The Mac helper restarted; check before resending", "Mac 小帮手重启过，请确认后重发", "Mac 小幫手重新啟動過，請確認後再重傳"],
  "fail.unknown-status": ["Status unknown; check the chat before deciding to resend", "状态未知，请稍后查看对话再决定是否重发", "狀態不明，請稍後查看對話再決定是否重傳"],
  "fail.session-waiting": ["It's waiting for the admin; send after that's handled", "它在等管理员处理，处理完再发", "它在等管理員處理，處理完再傳"],
  "fail.slash-forbidden": ["This command can only be entered on the Mac", "这个命令只能在 Mac 上输入", "這個命令只能在 Mac 上輸入"], // guests may only send the slash commands in GUEST_SLASH_COMMANDS
  "fail.at-menu": ["The session is waiting for your answer/approval; answer in the card above, or handle it in Orca first", "会话在等你作答/批准，请在上面的卡片里答，或先在 Orca 里处理", "會話在等你作答／核准，請在上面的卡片裡回答，或先在 Orca 裡處理"],
  "fail.forbidden": ["Not allowed", "没有权限", "沒有權限"],
  "fail.context-timeout": ["Reading details timed out", "读取明细超时", "讀取明細逾時"],
  "fail.context-failed": ["Couldn't read details", "读取明细失败", "讀取明細失敗"],
  "fail.context-parse": ["Couldn't understand the details format", "明细格式认不出来", "明細格式無法辨識"],
  "fail.claude-not-found": ["Can't find the claude command on the Mac", "Mac 上找不到 claude 命令", "Mac 上找不到 claude 指令"],
  "fail.cwd-missing": ["The session's start folder no longer exists", "会话的启动目录已不存在", "會話的啟動資料夾已不存在"],
  "fail.too-large": ["File is over 20 MB", "文件超过 20 MB", "檔案超過 20 MB"],
  "fail.network": ["Network down, try again later", "网络不通，请稍后再试", "網路不通，請稍後再試"],
  "send.fail": ["Send failed", "发送失败", "傳送失敗"],
  "send.partial": ["Failed after step {n}; handle it in Orca", "已发到第 {n} 步后失败，请到 Orca 处理", "已送到第 {n} 步後失敗，請到 Orca 處理"],
  // ---------- Approve buttons ----------
  "appr.planAuto": ["Approve (auto-accept edits)", "批准（自动接受编辑）", "核准（自動接受編輯）"],
  "appr.planManual": ["Approve (confirm each edit)", "批准（手动确认编辑）", "核准（手動確認編輯）"],
  "appr.planKeep": ["Keep planning", "继续规划", "繼續規劃"],
  "appr.approve": ["Approve", "批准", "核准"],
  "appr.always": ["Approve, don't ask again", "批准且不再问", "核准且不再詢問"],
  "appr.deny": ["Deny", "拒绝", "拒絕"],
  // ---------- Off duty / wake ----------
  "off.unknownTime": ["Off-duty time unknown", "下班时间未知", "下班時間不明"],
  "off.line": ["Off duty {t}", "下班 {t}", "下班 {t}"],
  "off.just": ["Just went off duty", "刚下班", "剛下班"],
  "off.head": ["Off duty", "已下班", "已下班"],
  "off.headAgo": ["Off duty · {t}", "已下班 · {t}", "已下班 · {t}"],
  "wakefail.wake-timeout": ["Wake-up timed out; it may be stuck on a dialog on the Mac", "唤醒超时，可能停在 Mac 上的确认框", "喚醒逾時，可能停在 Mac 上的確認視窗"],
  "wakefail.not-offduty": ["It's no longer on the off-duty list", "它已经不在下班名单里了", "它已經不在下班名單裡了"],
  "wakefail.helper-timeout": ["The Mac helper isn't responding", "Mac 小帮手没响应", "Mac 小幫手沒有回應"],
  "wakefail.helper-restarted": ["The Mac helper restarted; check before retrying", "Mac 小帮手重启过，请确认后重试", "Mac 小幫手重新啟動過，請確認後再試"],
  "wakefail.wake-already-awake": ["It's already awake", "它已经醒着了", "它已經醒著了"], // helper maps the script's original text to a code
  "wakefail.wake-no-terminal": ["Orca didn't open a terminal for it", "Orca 没开出终端", "Orca 沒有開出終端機"],
  "wakefail.unknown-status": ["Status unknown; check later whether it woke up", "状态未知，请稍后看看它是否已醒", "狀態不明，請稍後看看它是否已醒來"],
  "wake.fail": ["Couldn't wake it up", "唤醒失败", "喚醒失敗"],
  // ---------- Push ----------
  "push.iosHint": ["On iOS, add Soulgent to your Home Screen and open it from there to turn on notifications", "iOS 需要先把 Soulgent 添加到主屏幕，再从主屏幕图标打开，才能开启通知", "iOS 需要先把 Soulgent 加入主畫面，再從主畫面圖示開啟，才能開啟通知"],
  "push.unsupported": ["Notifications aren't supported here", "此环境不支持通知", "此環境不支援通知"],
  "push.denied": ["Notifications were denied (re-allow them in Settings)", "通知已被拒绝（到系统设置里重新允许）", "通知已被拒絕（到系統設定裡重新允許）"],
  "push.subscribed": ["Notifications on", "通知已开启", "通知已開啟"],
  "push.off": ["Notifications off", "通知未开启", "通知未開啟"],
  // ---------- Top bar summary / working ----------
  "busy.lt1": ["Working < 1 min", "已干不到 1 分钟", "已工作不到 1 分鐘"],
  "busy.min": ["Working {m} min", "已干 {m} 分钟", "已工作 {m} 分鐘"],
  "busy.hour": ["Working {h} h", "已干 {h} 小时", "已工作 {h} 小時"],
  "busy.hourMin": ["Working {h} h {m} min", "已干 {h} 小时 {m} 分钟", "已工作 {h} 小時 {m} 分鐘"],
  // Pill and list titles are written "SA N · BG M" in all three languages, not translated; the explanatory sentence follows the language
  "head.agents": ["SA {n}", "SA {n}", "SA {n}"],
  "head.bgCmds": ["BG {n}", "BG {n}", "BG {n}"],
  "head.helperList": ["SA {n} · BG {m}", "SA {n} · BG {m}", "SA {n} · BG {m}"],
  "head.helperTip": ["Tap a row to jump to its card or crab", "点一行，跳到对话里的牌子或小螃蟹", "點一行，跳到對話裡的牌子或小螃蟹"],
  "head.helperBg": ["BG", "BG", "BG"],
  "head.helperBgN": ["Background commands ×{n}", "后台命令 ×{n}", "背景指令 ×{n}"],
  "head.helperFoot": ["Subagents show m:ss; background commands show minutes only", "子代理显示已跑 分:秒；后台命令只显示已跑多少分钟", "子代理顯示已跑 分:秒；背景指令只顯示已跑多少分鐘"],
  "head.helperMore": ["{n} more without details", "还有 {n} 个没有详情", "還有 {n} 個沒有詳情"],
  "head.bgMin": ["{m} min", "{m} 分", "{m} 分"],
  "head.helperAria": ["Show subagents and background tasks", "查看子代理和后台任务", "查看子代理和背景任務"],
  "head.helperGone": ["Can't find it in the chat (maybe in older history)", "对话里找不到（可能在更早的历史里）", "對話裡找不到（可能在更早的歷史裡）"],
  "chat.newMsg": ["↓ New messages", "↓ 新消息", "↓ 新訊息"],
  "chat.newMsgN": ["↓ {n} new", "↓ 新消息 {n}", "↓ 新訊息 {n}"],
  // ---------- Recall ----------
  "recall.lockToast": ["It's been over 2 minutes, can't unsend", "超过 2 分钟，撤不回了", "超過 2 分鐘，收不回了"],
  "recall.interrupted": ["Interrupted; text put back in the input box", "已打断，原文已放回输入框", "已打斷，原文已放回輸入框"],
  "recall.answered": ["It already answered; text put back", "它已答完，原文已放回", "它已回答完，原文已放回"],
  "recall.processingGuest": ["It's working on this one; text put back", "它正在处理这条，原文已放回", "它正在處理這則，原文已放回"],
  "recall.processing": ["It's working on this one; later messages are still queued", "它正在处理这条，后面的还在排队", "它正在處理這則，後面的還在排隊"],
  "recall.done": ["Unsent; text put back in the input box", "已撤回，原文放回输入框", "已收回，原文放回輸入框"],
  "recall.fail": ["Couldn't unsend", "撤回失败", "收回失敗"],
  "recallfail.already-read": ["The agent already read this, can't unsend", "Agent 已经读了这条，撤不回", "Agent 已經讀了這則，收不回"],
  "recallfail.recall-uncertain": ["Unsend wasn't confirmed; check the input box in Orca", "撤回没确认成功，请到 Orca 看一下输入框", "收回沒有確認成功，請到 Orca 看一下輸入框"],
  "recallfail.no-transcript": ["Can't find this session's transcript, can't unsend", "找不到这个会话的记录，撤不回", "找不到這個會話的紀錄，收不回"],
  "recallfail.session-waiting": ["It's waiting for the admin; can't unsend right now", "它在等管理员处理，暂时撤不回", "它在等管理員處理，暫時收不回"],
  "recallfail.admin-queued": ["The admin has queued messages; can't unsend yet", "管理员有排队消息，暂不能撤回", "管理員有排隊中的訊息，暫時不能收回"],
  "recallfail.at-menu": ["The session is waiting for your answer/approval; answer in the card first, then unsend", "会话在等你作答/批准，先在卡片里答完再撤回", "會話在等你作答／核准，先在卡片裡回答完再收回"],
  "recallfail.too-old": ["It's been over 2 minutes, can't unsend", "超过 2 分钟，撤不回了", "超過 2 分鐘，收不回了"],
  "recallfail.forbidden": ["You can only unsend your own messages", "只能撤回自己发的消息", "只能收回自己傳的訊息"],
  "recall.askQ": ["It's working on this one; unsending will interrupt its current turn. Continue?", "它正在处理这条，撤回会打断它这一轮。继续？", "它正在處理這則，收回會打斷它這一輪。要繼續嗎？"],
  "recall.askOk": ["Interrupt and unsend", "打断并撤回", "打斷並收回"],
  "fwd.prefix": ["[Forwarded from {name}]", "[转发自 {name}]", "[轉傳自 {name}]"],
  "up.progress": ["Uploading {i}/{n}", "上传中 {i}/{n}", "上傳中 {i}/{n}"],
  // ---------- List rows / status text ----------
  "mac.disconnected": ["Mac disconnected, data as of {at}", "Mac 已断开，数据截至 {at}", "Mac 已中斷連線，資料截至 {at}"],
  "mac.disconnectedShort": ["Disconnected {at}", "已断开 {at}", "已中斷 {at}"],
  "mac.orcaDown": ["Mac · Orca not running", "Mac · Orca 未运行", "Mac · Orca 未執行"],
  "mac.orcaDownShort": ["Orca not running", "Orca 未运行", "Orca 未執行"],
  "mac.orcaOn": ["Mac · Orca online", "Mac · Orca 在线", "Mac · Orca 在線上"],
  "mac.orcaOnShort": ["Orca ✓", "Orca ✓", "Orca ✓"],
  // Reasons data is stale (helper heartbeat, server snapshot down.reason)
  "mac.helperDown": ["Mac helper stopped, data as of {at}", "Mac 小帮手停了，数据截至 {at}", "Mac 小幫手停了，資料截至 {at}"],
  "mac.panelDown": ["Soulgent isn't responding, data as of {at}", "Soulgent 没响应，数据截至 {at}", "Soulgent 沒回應，資料截至 {at}"],
  "mac.helperDownShort": ["Helper down", "小帮手停了", "小幫手停了"], // the phone's top row has no room for the time; see the grey bar and timer on the chat page
  "mac.panelDownShort": ["Soulgent down", "Soulgent 没响应", "Soulgent 沒回應"],
  "row.tagAdminWait": ["[Waiting for admin]", "[等管理员]", "[等管理員]"],
  "row.adminWaitText": ["Waiting for the admin to answer or approve", "在等管理员回答或批准", "在等管理員回答或核准"],
  "row.tagWait": ["[Waiting for you]", "[在等你]", "[在等你]"],
  "row.waitText": ["Needs your answer or approval", "需要你回答或批准", "需要你回答或核准"],
  "row.agents": ["Delegating ({n})", "正在派活({n})", "正在派工({n})"],
  "row.working": ["Working", "正在干活", "正在工作"],
  "row.bgRun": ["Running in background ({n})", "后台在跑 ({n})", "背景執行中 ({n})"],
  "row.bgStale": ["Background task may be stuck", "后台任务疑似挂住", "背景任務疑似卡住"],
  "row.rest": ["Resting {t}", "休息 {t}", "休息 {t}"],
  "row.noSummary": ["(No summary)", "（没有摘要）", "（沒有摘要）"],
  "row.draft": ["[Draft]", "[草稿]", "[草稿]"],
  // WorkBuddy status labels (summaryCode state.*): error red, aborted/paused grey
  "row.tagErr": ["[Error]", "[出错]", "[出錯]"],
  "row.tagStopped": ["[Stopped]", "[已中止]", "[已中止]"],
  "row.tagPaused": ["[Paused]", "[已暂停]", "[已暫停]"],
  // Quota exhausted (amber, not treated as a fault); banners at the top of the chat page: error / quota exhausted / retrying / unexpected exit / context just compacted
  "row.tagLimit": ["[Limit reached]", "[额度用完]", "[額度用完]"],
  "head.err": ["Error: {text}", "出错：{text}", "出錯：{text}"],
  "head.compacted": ["Context just compacted", "刚压缩过上下文", "剛壓縮過上下文"],
  "busy.retry": ["Retrying the API ({a}/{m})", "正在重试 API（{a}/{m}）", "正在重試 API（{a}/{m}）"],
  "lost.banner": ["The session exited unexpectedly.", "会话意外退出。", "會話意外結束。"],
  // Identity badge after the name
  "kind.codex": ["Codex", "Codex", "Codex"],
  "kind.workbuddy": ["WorkBuddy", "WorkBuddy", "WorkBuddy"],
  "st.waiting": ["Waiting for you", "在等你", "在等你"],
  "st.unread": ["Replied", "回复你", "回覆你"],
  "st.busy": ["Working", "干活中", "工作中"],
  "st.rest": ["Resting", "休息", "休息"],
  // ---------- Stats / monitor ----------
  "num.wan": ["{n} 万", "{n} 万", "{n} 萬"],
  "num.yi": ["{n} 亿", "{n} 亿", "{n} 億"],
  "unit.min": ["min", "分钟", "分鐘"],
  "unit.hour": ["h", "小时", "小時"],
  "me.costNote": ["Another {n} tokens from unknown models not counted", "另有 {n} token 型号不明，未计", "另有 {n} token 型號不明，未計入"],
  "mon.normal": ["Normal", "正常", "正常"],
  "mon.warn": ["Warning", "警告", "警告"],
  "mon.critical": ["Critical", "严重", "嚴重"],
  "mon.unknown": ["Unknown", "未知", "不明"],
  "mon.free": ["{v} free", "{v} 可用", "{v} 可用"],
  "mon.memUsed": ["Used {v} · Compressed {c}", "已用 {v} · 压缩 {c}", "已用 {v} · 壓縮 {c}"],
  "mon.memHigh": ["high compression", "压缩偏高", "壓縮偏高"],
  "mon.swapNone": ["Not in use", "未使用", "未使用"],
  "mon.noBattery": ["No battery", "无电池", "無電池"],
  "mon.charging": ["Charging", "充电中", "充電中"],
  "mon.ac": ["On power adapter", "已接电源", "已接電源"],
  "mon.onBattery": ["On battery", "使用电池", "使用電池"],
  "mon.noData": ["No monitoring data yet", "还没有监控数据", "還沒有監控資料"],
  "mon.dataAt": ["Data as of {t}", "数据截至 {t}", "資料截至 {t}"],
  // ---------- Quota countdown / context ----------
  "ql.m": ["{m}m", "{m}分", "{m}分"],
  "ql.h": ["{h}h", "{h}时", "{h}時"],
  "ql.hm": ["{h}h{m}m", "{h}时{m}分", "{h}時{m}分"],
  "ql.d": ["{d}d", "{d}天", "{d}天"],
  "ql.dh": ["{d}d{h}h", "{d}天{h}时", "{d}天{h}時"],
  "qc.used": ["{pct}% used", "已用 {pct}%", "已用 {pct}%"],
  "qc.min": ["{m} min", "{m} 分钟", "{m} 分鐘"],
  "qc.h": ["{h} h", "{h} 小时", "{h} 小時"],
  "qc.hm": ["{h} h {m} min", "{h} 小时 {m} 分钟", "{h} 小時 {m} 分鐘"],
  "qc.d": ["{d} d", "{d} 天", "{d} 天"],
  "qc.dh": ["{d} d {h} h", "{d} 天 {h} 小时", "{d} 天 {h} 小時"],
  "qc.recover": ["{head} · back in {span} ({at})", "{head} · {span}后恢复（{at}）", "{head} · {span}後恢復（{at}）"],
  "qc.reset": ["{head} · resets in {span} ({at})", "{head} · {span}后重置（{at}）", "{head} · {span}後重置（{at}）"],
  "qc.tomorrow": ["Tomorrow {t}", "明天 {t}", "明天 {t}"],
  "ctx.none": ["No context data", "没有上下文数据", "沒有上下文資料"],
  "ctx.usage": ["Context {v}", "上下文 {v}", "上下文 {v}"],
  "ctx.ageUnknown": ["Data time unknown", "数据时间不明", "資料時間不明"],
  "ctx.age": ["Data {t}", "数据 {t}", "資料 {t}"],
  "ctx.g.mcpTools": ["MCP tools", "MCP 工具", "MCP 工具"],
  "ctx.g.agents": ["Custom agents", "自定义代理", "自訂代理"],
  "ctx.g.memory": ["Memory files", "记忆文件", "記憶檔案"],
  "ctx.g.skills": ["Skills", "技能", "技能"],
  "ctx.smallTitle": ["Other ({n} items)", "其他（{n} 项）", "其他（{n} 項）"],
  "ctx.detailAge": ["Details {t}", "明细 {t}", "明細 {t}"],
  // ---------- Swipe / long-press menu ----------
  "act.seen": ["Mark as read", "标为已读", "標為已讀"],
  "act.unseen": ["Mark as unread", "标为未读", "標為未讀"],
  "act.back": ["Back", "回来", "回來"],
  "act.rest": ["Rest", "休息", "休息"],
  "act.off": ["Off duty", "下班", "下班"],
  "act.top": ["Pin", "置顶", "釘選"],
  "act.untop": ["Unpin", "取消置顶", "取消釘選"],
  "act.mute": ["Mute", "消息免打扰", "訊息勿擾"],
  "act.unmute": ["Unmute", "取消免打扰", "取消勿擾"],
  "rc.read": ["Read", "已读", "已讀"],
  "rc.sent": ["Delivered — it'll read when free", "已送到，它忙完会读", "已送到，它忙完會讀"],
  "rc.failed": ["Not delivered", "未送达", "未送達"],
  "rc.clock": ["Sending", "发送中", "傳送中"],
  "rc.delivered": ["Delivered — it'll read when free", "已送到，它忙完会读", "已送到，它忙完會讀"],
  "offfail.offduty-timeout": ["Going off duty timed out: it may be stuck on a dialog on the Mac", "下班超时：它可能停在 Mac 上的确认框", "下班逾時：它可能停在 Mac 上的確認視窗"],
  "offfail.session-gone": ["That session is gone", "会话已经不在了", "會話已經不在了"],
  "offfail.not-offdutyable": ["Only Claude sessions can go off duty", "只有 Claude 会话能下班", "只有 Claude 會話能下班"],
  "offfail.unknown-session": ["That session is gone", "会话已经不在了", "會話已經不在了"],
  "offfail.unknown session": ["That session is gone", "会话已经不在了", "會話已經不在了"],
  "offfail.helper-timeout": ["The Mac helper isn't responding", "Mac 小帮手没响应", "Mac 小幫手沒有回應"],
  "offfail.helper-restarted": ["The Mac helper restarted; check whether it went off duty", "Mac 小帮手重启过，请看看它是否已下班", "Mac 小幫手重新啟動過，請看看它是否已下班"],
  "offfail.offduty-restarting": ["The Mac is restarting sessions; try again later", "Mac 上正在重启会话，稍后再试", "Mac 上正在重新啟動會話，稍後再試"],
  "offfail.offduty-not-idle": ["It isn't idle, so it wasn't sent off duty", "它不是空闲状态，没送下班", "它不是閒置狀態，沒有送下班"],
  "offfail.offduty-agents-running": ["It has subagents running in the background, so it wasn't sent off duty", "它有后台子代理在跑，没送下班", "它有背景子代理在跑，沒有送下班"],
  "offfail.unknown-status": ["Status unknown; check later whether it went off duty", "状态未知，请稍后看看它是否已下班", "狀態不明，請稍後看看它是否已下班"],
  "offfail.network": ["Network down, try again later", "网络不通，请稍后再试", "網路不通，請稍後再試"],
  "off.fail": ["Couldn't go off duty", "下班失败", "下班失敗"],
  // ---------- Subagent cards ----------
  "ag.lt1": ["< 1 min", "不到 1 分", "不到 1 分"],
  "ag.m": ["{m} min", "{m} 分", "{m} 分"],
  "ag.hm": ["{h} h {m} min", "{h} 时 {m} 分", "{h} 時 {m} 分"],
  "ag.default": ["Default", "默认", "預設"],
  "ag.n1": ["1 subagent", "1 个子代理", "1 個子代理"],
  "ag.n": ["{n} subagents", "{n} 个子代理", "{n} 個子代理"],
  "ag.ran": ["Ran", "已跑", "已跑"],
  "ag.took": ["Took", "共用时", "共用時"],
  "ag.total": ["{v} total", "共 {v}", "共 {v}"],
  "ag.running": ["Running {t}", "在跑 {t}", "執行中 {t}"],
  "ag.gone": ["Quiet · {t}", "没动静 · {t}", "沒有動靜 · {t}"],
  "ag.failed": ["Failed · {t}", "失败 · {t}", "失敗 · {t}"],
  "ag.used": ["Took", "用时", "用時"],
  // ---------- Chat page time / window switch ----------
  "origin.peer": ["↔ Talking with {name}", "↔ 与 {name} 往来", "↔ 與 {name} 往來"], // server originTag
  "origin.peerAny": ["↔ Between sessions", "↔ 会话间往来", "↔ 會話間往來"],
  "origin.agent": ["⚙ Handled a subagent report", "⚙ 处理了子代理回报", "⚙ 處理了子代理回報"],
  // Push text: the server's api/notify.py PUSH_TEXT generates it per subscription language; this is the same copy (tests/test_push_i18n.py checks it verbatim; change both together)
  "pushmsg.wait": ["Waiting for you", "在等你", "在等你"],
  "pushmsg.done": ["Done", "干完了", "完成了"],
  "pushmsg.fbWait": ["Needs your decision", "有事要你定", "有事要你決定"],
  "pushmsg.fbDone": ["Done", "干完了", "完成了"],
  "pushmsg.testTitle": ["Soulgent test", "Soulgent 测试", "Soulgent 測試"],
  "pushmsg.testBody": ["This is a test notification", "这是一条测试通知", "這是一則測試通知"],
  // Push: WorkBuddy error / aborted; Mac disconnected / restored (sent by the server, same tag mac-link overwrites)
  "pushmsg.err": ["Error", "出错了", "出錯了"],
  "pushmsg.stopped": ["Stopped", "已中止", "已中止"],
  // Quota exhausted, session exited unexpectedly (pushed once, not on completion)
  "pushmsg.limit": ["Limit reached", "额度用完", "額度用完"],
  "pushmsg.lost": ["Exited unexpectedly", "意外退出", "意外結束"],
  "pushmsg.macDown": ["Mac disconnected", "Mac 已断开", "Mac 已中斷連線"],
  "pushmsg.macDownBody": ["{reason}. Data as of {at}", "{reason}，数据截至 {at}", "{reason}，資料截至 {at}"],
  "pushmsg.macUp": ["Mac reconnected", "Mac 已恢复", "Mac 已恢復連線"],
  "pushmsg.macUpBody": ["Data is live again", "数据已更新", "資料已更新"],
  // System push bodies only (built by api/notify.py; the in-app banner keeps "[label] text")
  "pushmsg.waitFb": ["Waiting for your decision", "在等你决定", "在等你決定"],
  "pushmsg.errBody": ["Error: {text}", "出错：{text}", "出錯：{text}"],
  "pushmsg.errStatusBody": ["Error {status}: {text}", "出错 {status}：{text}", "出錯 {status}：{text}"],
  "pushmsg.limitBody": ["Limit reached: {text}", "额度用完：{text}", "額度用完：{text}"],
  "pushmsg.reasonHelper": ["Helper stopped", "小帮手停了", "小幫手停了"],
  "pushmsg.reasonPanel": ["Soulgent isn't responding", "Soulgent 没响应", "Soulgent 沒回應"],
  // Icon test: A no icon, B icon URL, C sw inlines the image
  "notice.compacted": ["Context compacted", "上下文已压缩", "上下文已壓縮"], // server {role:"notice", code:"compacted"}
  "sep.continued": ["Before compaction", "压缩续接前", "壓縮續接前"],
  "sep.prev": ["Before window switch", "换窗前", "換窗前"],
  "sep.guess": ["guessed", "推测", "推測"],
  "gs.count": ["{n} related", "{n} 条相关", "{n} 則相關"],
  "kind.sheet": ["Spreadsheet", "表格", "試算表"],
  "kind.text": ["Text", "文本", "文字"],
  "kind.html": ["Web page", "网页", "網頁"],
  "kind.data": ["Data", "数据", "資料"],
  // ---------- index.html static text ----------
  "tab.chat": ["SoulChat", "SoulChat", "SoulChat"],
  "tab.agents": ["Agents", "Agents", "Agents"],
  "tab.zones": ["Dashboard", "看板", "看板"],
  "tab.me": ["Me", "我", "我"],
  "tab.nav": ["Main navigation", "主导航", "主導覽"],
  "html.clear": ["Clear", "清除", "清除"],
  "html.paneMsg": ["Messages", "消息", "訊息"],
  "html.macBtn": ["Signed-in devices: Orca usage and Mac health", "已登录设备：Orca 占用和 Mac 健康", "已登入裝置：Orca 用量和 Mac 健康狀態"],
  "html.paneContacts": ["Contacts", "通讯录", "通訊錄"],
  "html.rail": ["Zone index", "工区索引", "工作區索引"],
  "html.paneZones": ["Zones", "工区", "工作區"],
  "html.paneSearch": ["Search results", "搜索结果", "搜尋結果"],
  "html.deskEmpty": ["Pick a session on the left to view the chat", "点左边的会话查看对话", "點左邊的會話查看對話"],
  "html.detail": ["Chat", "对话", "對話"],
  "html.back": ["Back", "返回", "返回"],
  "html.ctx": ["Context usage", "上下文用量", "上下文用量"],
  "html.chatInfo": ["Chat info", "聊天信息", "聊天資訊"],
  "html.dropTitle": ["Drop to attach", "松手加入附件", "放開即可加入附件"],
  "html.dropSub": ["Up to 9, sent with your text", "最多 9 个，和文字一起发送", "最多 9 個，和文字一起傳送"],
  "html.clipImg": ["Clipboard image", "剪贴板图片", "剪貼簿圖片"],
  "html.clipTx": ["There's an image on the clipboard", "剪贴板里有图片", "剪貼簿裡有圖片"],
  "html.clipAdd": ["Attach", "加入附件", "加入附件"],
  "html.quoteX": ["Cancel quote", "取消引用", "取消引用"],
  "html.pick": ["Choose files", "选文件", "選擇檔案"],
  "html.reply": ["Reply to this session…", "回复这个会话…", "回覆這個會話…"],
  "html.replyLabel": ["Reply text", "回复内容", "回覆內容"],
  "html.send": ["Send", "发送", "傳送"],
  "html.plus": ["Send images or files", "发送图片或文件", "傳送圖片或檔案"],
  "html.wake": ["Wake up", "唤醒", "喚醒"],
  "html.ppPhoto": ["Photos", "照片", "照片"],
  "html.ppCamera": ["Camera", "拍摄", "拍照"],
  "html.ppFile": ["Files", "文件", "檔案"],
  "html.ppPaste": ["Paste image", "粘贴图片", "貼上圖片"],
  // ---------- login.html (login.html imports this file directly) ----------
  "login.title": ["Soulgent · Sign in", "Soulgent · 登录", "Soulgent · 登入"],
  "login.first1": ["First time on this device?", "第一次在这台设备上打开，", "第一次在這台裝置上開啟，"],
  "login.first2": ["Paste your access key", "请粘贴访问密钥", "請貼上存取金鑰"],
  "login.ph": ["Paste key", "粘贴密钥", "貼上金鑰"],
  "login.go": ["Enter", "进入", "進入"],
  "login.checking": ["Verifying…", "验证中…", "驗證中…"],
  "login.hint1": ["No key? Ask your admin.", "没有密钥？请向管理员索取。", "沒有金鑰？請向管理員索取。"],
  "login.hint2": ["Once verified, it's remembered — no need to enter it again.", "验证后会长期记住，不用再输。", "驗證後會長期記住，不用再輸入。"],
  "login.bad": ["Wrong key, please paste it again", "密钥不对，请重新粘贴", "金鑰不正確，請重新貼上"],
  "login.tooMany": ["Too many attempts, try again in 10 minutes", "错误次数太多，请 10 分钟后再试", "錯誤次數太多，請 10 分鐘後再試"],
  "login.server": ["Server error ({n})", "服务器出错（{n}）", "伺服器錯誤（{n}）"],
  "login.net": ["Can't reach the server, check your network", "连不上服务器，检查网络", "連不上伺服器，請檢查網路"],
  "login.switch": ["You are already signed in. Press Enter to switch to this key's account.", "当前已登录。要切换到此密钥的账号，请点「进入」。", "目前已登入。要切換到此金鑰的帳號，請按「進入」。"],
  "login.legacy": ["This link format is outdated and will stop working. Ask for a new link.", "此链接格式已过时，以后会失效，请索取新链接。", "此連結格式已過時，之後會失效，請索取新連結。"],
  // ---------- app.js: messages page top ----------
  "notice.offline": ["Offline · data as of {t}", "已离线 · 数据截至 {t}", "已離線 · 資料截至 {t}"],
  "notice.stale": ["Mac data is stale · as of {t}", "Mac 数据已过期 · 截至 {t}", "Mac 資料已過期 · 截至 {t}"],
  "quota.aria": ["{label} quota {pct}% used", "{label} 额度已用 {pct}%", "{label} 額度已用 {pct}%"],
  "quota.ariaLeft": [", back in {t}", "，{t}后恢复", "，{t}後恢復"],
  "empty.noConn": ["Can't reach Soulgent", "连不上 Soulgent", "連不上 Soulgent"],
  "empty.noConnSub": ["Check that your phone and the Mac are on the same network", "检查手机和 Mac 是否在同一网络", "檢查手機和 Mac 是否在同一個網路"],
  "empty.noSessions": ["No sessions right now", "现在没有会话", "目前沒有會話"],
  "svg.mute": ["Muted", "消息免打扰", "訊息勿擾"],
  "svg.pinned": ["Reply later", "稍后回复", "稍後回覆"],
  // ---------- app.js: message list / Agents / search ----------
  "fx.errand": ["Errand", "跑腿中", "跑腿中"],
  "list.restFold": ["Hide resting sessions", "收起休息中的会话", "收起休息中的會話"],
  "list.restN": ["{n} resting", "休息中 {n} 个", "休息中 {n} 個"],
  "list.restMore": ["{names} and more", "{names} 等", "{names} 等"],
  "list.restSub": ["{names}: nothing new, or you told it to rest", "{names}，没新动静或你让它休息", "{names}，沒有新動靜或你讓它休息"],
  "list.byZone": ["View by zone", "按工区查看", "依工作區檢視"],
  "list.guestOffline": ["“{name}” is offline right now, check back later", "「{name}」现在不在线，稍后再来", "「{name}」目前不在線上，稍後再來"],
  "list.guestUnbound": ["No session bound yet", "还没有绑定会话", "還沒有綁定會話"],
  "list.zoneEmpty": ["No sessions on duty in this zone right now", "这个工区现在没有在班的会话", "這個工作區目前沒有值班中的會話"],
  "wake.btn": ["Wake up", "唤醒", "喚醒"],
  "wake.aria": ["Open {name}'s chat to wake it up", "打开 {name} 的对话页去唤醒", "開啟 {name} 的對話頁去喚醒"],
  "wake.orcaDown": ["Orca isn't open; open Orca on the Mac first", "Orca 没开，先在 Mac 上打开 Orca", "Orca 沒開，先在 Mac 上開啟 Orca"],
  "ct.waiting": ["Waiting for you", "在等你的", "在等你的"],
  "ct.pinned": ["Reply later", "稍后回复", "稍後回覆"],
  "ct.off": ["Off duty", "已下班的", "已下班的"],
  "ct.secOn": ["{n} on duty", "在班 {n}", "值班 {n}"],
  "ct.secOff": [", {n} off", "，下班 {n}", "，下班 {n}"],
  "ct.offHead": ["Off duty", "已下班", "已下班"],
  "ct.jump": ["Jump to {name}", "跳到 {name}", "跳到 {name}"],
  "sr.hint1": ["Search by session name, zone or one-line summary,", "可以搜会话名、工区名、一句话摘要，", "可以搜尋會話名稱、工作區名稱、一句話摘要，"],
  "sr.hint2": ["or the names of sessions it talks with. Off-duty ones show up too.", "也能搜和它往来的会话名。已下班的也找得到。", "也能搜尋和它往來的會話名稱。已下班的也找得到。"],
  "sr.byName": ["Sessions", "会话", "會話"],
  "sr.bySummary": ["Summaries mentioning “{q}”", "摘要里提到「{q}」", "摘要裡提到「{q}」"],
  "sr.none": ["Nothing found for “{q}”", "没找到「{q}」", "找不到「{q}」"],
  "sr.noneAll": ["Not in session names, zones, summaries or chat history", "会话名、工区、摘要和聊天记录里都没有", "會話名稱、工作區、摘要和聊天紀錄裡都沒有"],
  "sr.noneLite": ["Only session names, zones and summaries are searched, not full chats", "只搜会话名、工区和一句话摘要，不搜对话全文", "只搜尋會話名稱、工作區和一句話摘要，不搜尋對話全文"],
  "gs.head": ["Chat history", "聊天记录", "聊天紀錄"],
  "gs.wait": ["Searching chat history…", "正在搜索聊天记录…", "正在搜尋聊天紀錄…"],
  "gs.err": ["Chat history search failed, try again later", "聊天记录搜索失败，请稍后再试", "聊天紀錄搜尋失敗，請稍後再試"],
  // ---------- app.js: "Me" page ----------
  "me.pushOn": ["On", "已开启", "已開啟"],
  "me.pushDenied": ["Denied", "已拒绝", "已拒絕"],
  "me.pushUnsupported": ["Not supported", "不支持", "不支援"],
  "me.pushOff": ["Off", "未开启", "未開啟"],
  "me.adminName": ["Admin", "管理员", "管理員"],
  "me.adminId": ["Soulgent ID: admin", "Soulgent ID：admin", "Soulgent ID：admin"],
  "app.tagline": ["Give your agents a soul.", "给你的 Agent 一个灵魂。", "給你的 Agent 一個靈魂。"],
  "me.bound": ["Bound to: {name}", "绑定：{name}", "綁定：{name}"],
  "me.unbound": ["Not bound", "未绑定", "未綁定"],
  "me.push": ["Notifications", "通知设置", "通知設定"],
  "me.logout": ["Log out", "退出登录", "登出"],
  "me.guestFoot": ["You can only see this one session here. Everything you send is automatically prefixed with {tag}; questions and approvals are handled by the admin.", "这里只看得到这一个会话。你发出的每句话前面会自动加上 {tag}；提问和批准由管理员处理。", "這裡只看得到這一個會話。你傳出的每句話前面會自動加上 {tag}；提問和核准由管理員處理。"],
  "me.agents": ["Agents started", "已启动 Agent", "已啟動 Agent"],
  "me.hours": ["Agent time", "Agent 工作时长", "Agent 工作時數"],
  "me.today": ["Tokens today", "今日 token", "今日 token"],
  "me.usage": ["Usage", "使用概况", "使用概況"],
  "me.6w": ["Last 6 weeks", "近 6 周", "近 6 週"],
  "me.total": ["Total tokens", "总 token", "總 token"],
  "me.cost": ["Est. cost", "预计成本", "預估成本"],
  "me.costHint": ["At API prices", "按 API 价目估", "依 API 價目估算"],
  "me.days": ["Active days", "活跃天数", "活躍天數"],
  "me.daysN": ["{n}", "{n} 天", "{n} 天"],
  "me.peak": ["Busiest day", "最活跃日", "最活躍日"],
  "me.heat": ["Daily token intensity, last 6 weeks", "近 6 周每日 token 强度", "近 6 週每日 token 強度"],
  "me.less": ["Less", "少", "少"],
  "me.more": ["More", "多", "多"],
  "me.q5h": ["5-hour quota", "5 小时额度", "5 小時額度"],
  "me.qWeek": ["Weekly quota", "本周额度", "本週額度"],
  "me.quota": ["Claude quota", "Claude 额度", "Claude 額度"],
  "me.devices": ["Signed-in devices", "已登录设备", "已登入裝置"],
  "me.disconnected": ["Disconnected", "已断开", "已中斷"],
  "me.seenAll": ["Mark all as seen", "全部标为看过", "全部標為已看"],
  "me.refresh": ["Refresh now", "立即刷新", "立即重新整理"],
  "me.diag": ["Diagnostic log", "诊断日志", "診斷紀錄"],
  "me.footOffline": ["Offline.", "已离线，", "已離線，"],
  "me.foot": ["Data as of {t}: {on} sessions on duty, {off} off duty. Costs are estimated at Anthropic's official API prices, not an actual bill.", "数据截至 {t}，共 {on} 个在班会话、{off} 个下班。成本按 Anthropic 官方 API 价目估算，不是实际账单。", "資料截至 {t}，共 {on} 個值班中的會話、{off} 個下班。成本依 Anthropic 官方 API 價目估算，不是實際帳單。"],
  "me.lang": ["Language", "语言", "語言"],
  "me.langAuto": ["Follow system", "跟随系统", "跟隨系統"],
  "me.langAutoV": ["System", "跟随系统", "跟隨系統"],
  "toast.refreshFail": ["Refresh failed; still showing offline data", "刷新失败，仍是离线数据", "重新整理失敗，仍是離線資料"],
  "toast.refreshed": ["Refreshed", "已刷新", "已重新整理"],
  // ---------- app.js: board page ----------
  "zb.openTb": [", open task board", "，打开任务板", "，開啟任務板"],
  "zb.tb": ["Task board", "任务板", "任務板"],
  "zb.on": ["On duty", "在班", "值班"],
  "zb.notOn": ["Off duty", "不在班", "未值班"],
  "zb.busy": ["Working", "干活中", "工作中"],
  "zb.waiting": ["Waiting", "在等你", "在等你"],
  "zb.today": ["Tokens today", "今日 token", "今日 token"],
  "zb.offList": ["Off-duty list {n}", "下班名单 {n}", "下班名單 {n}"],
  "zb.none": ["No zones in the zone table yet", "工区表里还没有工区", "工作區表裡還沒有工作區"],
  "zb.note": ["Today's tokens are assigned to zones by each session's project folder; ones that don't match aren't counted", "今日 token 按会话所在项目目录归到工区，对不上的不算", "今日 token 依會話所在的專案資料夾歸到工作區，對不上的不計入"],
  "board.asOf": ["as of {t}", "截至 {t}", "截至 {t}"], // suffix after the numbers when the Mac is disconnected on the board page, wrapped by paren() into full-width or ASCII parentheses, e.g. " (as of hh:mm)"
  "zb.unmatched": ["{n} more today weren't assigned", "今天另有 {n} 没归上", "今天另有 {n} 沒歸上"],
  "c.period": [".", "。", "。"],
  // ---------- app.js: monitor page (signed-in devices) ----------
  "mon.thisMac": ["This Mac", "这台 Mac", "這台 Mac"],
  "mon.pushOn": ["Notifications on", "通知已开", "通知已開"],
  "mon.pushOff": ["Notifications off", "通知未开", "通知未開"],
  "mon.orcaDown": ["Orca not running", "Orca 未运行", "Orca 未執行"],
  "mon.orcaUp": ["Orca running", "Orca 运行中", "Orca 執行中"],
  "mon.snap": ["Snapshot {t}", "快照 {t}", "快照 {t}"],
  "mon.q5h": ["5-hour quota", "5 小时额度", "5 小時額度"],
  "mon.q7d": ["7-day quota", "7 天额度", "7 天額度"],
  "mon.orcaUse": ["Orca usage", "Orca 占用", "Orca 用量"],
  "mon.name": ["Name", "名称", "名稱"],
  "mon.mem": ["Memory", "内存", "記憶體"],
  "mon.app": ["Orca app", "Orca 本体", "Orca 主程式"],
  "mon.terms": ["{n} terminals", "{n} 个终端", "{n} 個終端機"],
  "mon.total": ["Total", "合计", "合計"],
  "mon.projects": ["{n} projects", "{n} 个项目", "{n} 個專案"],
  "mon.notListed": [", {n} more not listed", "，另 {n} 个没列出", "，另 {n} 個沒列出"],
  "mon.orcaNotRunning": ["Orca isn't running", "Orca 没在运行", "Orca 沒有在執行"],
  "mon.orcaNoData": ["Can't read Orca's usage data", "读不到 Orca 的占用数据", "讀不到 Orca 的用量資料"],
  "mon.health": ["Mac health", "Mac 健康", "Mac 健康狀態"],
  "mon.pressure": ["Memory pressure", "内存压力", "記憶體壓力"],
  "mon.cached": ["Cached (reclaimable)", "缓存（可回收）", "快取（可回收）"],
  "mon.swapNote": ["Swap doesn't shrink until restart; judge slowness by pressure level and compression", "Swap 重启前不会自动回落；卡不卡看压力等级和压缩量", "Swap 重新開機前不會自動回落；卡不卡看壓力等級和壓縮量"],
  "mon.load": ["Load 1/5/15 min", "负载 1/5/15 分", "負載 1/5/15 分"],
  "mon.disk": ["Disk free", "磁盘剩余", "磁碟剩餘"],
  "mon.battery": ["Battery", "电池", "電池"],
  "mon.footAt": [", this one is from {t}", "，这份是 {t} 的", "，這份是 {t} 的"],
  "mon.foot": ["The helper samples every 10 seconds{at}. Memory rows are colored by the system memory pressure level (same as Activity Monitor); load above the core count{cores} is yellow, above twice is red; disk below 50 GB is yellow, below 20 GB is red.", "小帮手每 10 秒采一次{at}。内存相关几行的颜色跟随系统内存压力等级（和活动监视器同一口径）；负载超过核数{cores}标黄，超过两倍标红；磁盘少于 50 GB 标黄，少于 20 GB 标红。", "小幫手每 10 秒採樣一次{at}。記憶體相關幾行的顏色跟隨系統記憶體壓力等級（和活動監視器同一標準）；負載超過核心數{cores}標黃，超過兩倍標紅；磁碟少於 50 GB 標黃，少於 20 GB 標紅。"],
  // ---------- app.js: task board ----------
  "tb.title": ["{name} task board", "{name} 任务板", "{name} 任務板"],
  "tb.loading": ["Loading…", "正在读取…", "正在讀取…"],
  "tb.fail": ["Couldn't read the task board, try again later", "读不到任务板，稍后再试", "讀不到任務板，稍後再試"],
  "tb.ro": ["Read-only", "只读", "唯讀"],
  "tb.updated": ["· updated {t}", "· 更新于 {t}", "· 更新於 {t}"],
  "tb.cut": ["The task board is over 20 KB; only the first part is shown.", "任务板超过 20 KB，只显示了前面一部分。", "任務板超過 20 KB，只顯示了前面一部分。"],
  "tab.msgAria": ["Messages", "消息", "訊息"],
  "tab.msgAriaN": ["Messages, {n} need your attention", "消息，{n} 个要你看", "訊息，{n} 個要你看"],
  // ---------- Mac-side --dump waitingFor (machine values; known ones translated, unknown kept as-is) ----------
  "wf.permission prompt": ["Needs permission", "等你批准", "等你核准"],
  "wf.permission request": ["Needs permission", "等你批准", "等你核准"],
  "wf.input needed": ["Needs your input", "等你回答", "等你回答"],
  // ---------- Mac-side --dump summaryCode (17 codes; the Simplified template + args must match summary verbatim) ----------
  "sum.wait.ask": ["Asks: {question}", "问你：{question}", "問你：{question}"],
  "sum.wait.ask.n": ["Asks: {question} ({count} questions)", "问你：{question}（共 {count} 个问题）", "問你：{question}（共 {count} 個問題）"],
  "sum.wait.ask.generic": ["Has a question for you", "在等你回答问题", "在等你回答問題"],
  "sum.wait.plan": ["Plan ready for approval", "计划写好了，等你批准", "計畫寫好了，等你核准"],
  "sum.wait.approve.run": ["Approve to run: {command}", "等你批准运行：{command}", "等你核准執行：{command}"],
  "sum.wait.approve.edit": ["Approve edit: {file}", "等你批准修改：{file}", "等你核准修改：{file}"],
  "sum.wait.approve.edit.nofile": ["Approve a file edit", "等你批准修改文件", "等你核准修改檔案"],
  "sum.wait.approve.tool": ["Approve tool: {tool}", "等你批准使用 {tool}", "等你核准使用 {tool}"],
  "sum.wait.approve": ["Needs approval", "等你批准", "等你核准"],
  "sum.wait.answer": ["Needs your answer ({options} options)", "等你回答（{options} 个选项）", "等你回答（{options} 個選項）"],
  "sum.wait.answer.one": ["Needs your answer (1 option)", "等你回答（1 个选项）", "等你回答（1 個選項）"],
  "sum.wait.answer.noopt": ["Needs your answer", "等你回答", "等你回答"],
  "sum.state.paused": ["Paused", "已暂停", "已暫停"],
  "sum.state.stopped": ["Stopped", "已中止", "已中止"],
  "sum.state.error": ["Error", "出错", "出錯"],
  // API errors (args kind/status/text; rate_limit is CC's original text, auth is a fixed sentence, null status writes no code), retrying, unexpected exit
  "sum.state.apiError": ["API error {status}: {text}", "API 出错 {status}：{text}", "API 出錯 {status}：{text}"],
  "sum.state.apiError.limit": ["{text}", "{text}", "{text}"],
  "sum.state.apiError.auth": ["Needs sign-in again", "要重新登录", "需要重新登入"],
  "sum.state.apiError.nostatus": ["API error: {text}", "API 出错：{text}", "API 出錯：{text}"],
  "sum.state.retrying": ["Retrying {attempt}/{max}", "正在重试 {attempt}/{max}", "正在重試 {attempt}/{max}"],
  "sum.state.disconnected": ["Exited unexpectedly", "意外退出", "意外結束"],
  "sum.prompt.you": ["You: {text}", "你：{text}", "你：{text}"],
  "sum.relay.agent": ["Handling a subagent report…", "处理子代理回报…", "處理子代理回報…"],
  "sum.relay.peer": ["Handling a message from another session…", "处理其他会话的消息…", "處理其他會話的訊息…"],
  "sum.relay.from": ["Handling {peer}'s report…", "处理 {peer} 的回报…", "處理 {peer} 的回報…"],
  "name.untitled": ["Untitled", "未命名", "未命名"],
  // ---------- app.js: list action toasts / off duty / notification settings ----------
  "toast.noUnread": ["This session can't be marked unread right now", "这个会话现在标不了未读", "這個會話現在無法標為未讀"],
  "toast.gone": ["That session is gone", "会话已经不在了", "會話已經不在了"],
  "toast.rested": ["Moved to “Resting”; it'll come back by itself when something new happens", "已放进「休息中」，有新动静会自己回来", "已放進「休息中」，有新動靜會自己回來"],
  "off.ask": ["Send {name} off duty?", "让 {name} 下班？", "讓 {name} 下班？"],
  "off.askHint": ["It will exit safely and keep its chat history; you can wake it later from the off-duty list in Agents", "它会安全退出，对话记录都在；之后可以在 Agents 的下班名单里唤醒", "它會安全結束，對話紀錄都在；之後可以在 Agents 的下班名單裡喚醒"],
  "off.going": ["Sending {name} off duty…", "正在让 {name} 下班…", "正在讓 {name} 下班…"],
  "off.done": ["{name} is off duty; wake it from the off-duty list in Agents", "{name} 已下班，可在 Agents 的下班名单里唤醒", "{name} 已下班，可在 Agents 的下班名單裡喚醒"],
  "off.failed": ["Couldn't go off duty: {why}", "没能下班：{why}", "沒能下班：{why}"],
  "toast.waitTop": ["Sessions waiting for you are at the top", "在等你的排在最上面", "在等你的排在最上面"],
  "toast.pinOrder": ["Reply-later ones come after those waiting for you", "稍后回复的排在「在等你」之后", "稍後回覆的排在「在等你」之後"],
  "push.title": ["Notifications", "通知设置", "通知設定"],
  "push.enable": ["Turn on notifications", "开启通知", "開啟通知"],
  "push.test": ["Send a test notification", "发测试通知", "傳送測試通知"],
  "push.enableFail": ["Couldn't turn on: {e}", "开启失败：{e}", "開啟失敗：{e}"],
  "push.sent": ["Sent to {a}/{b} devices", "已发送到 {a}/{b} 台设备", "已傳送到 {a}/{b} 台裝置"],
  "push.devLine": ["This device: {dev} · {state} · {n} on this account", "本机：{dev} · {state} · 这个账户共 {n} 台", "本機：{dev} · {state} · 這個帳號共 {n} 台"],
  "push.devLine0": ["This device: {dev} · {state}", "本机：{dev} · {state}", "本機：{dev} · {state}"],
  "push.devHome": ["{p} Home Screen app", "{p} 主屏 App", "{p} 主畫面 App"],
  "push.devDock": ["{p} Dock app", "{p} 程序坞 App", "{p} Dock App"],
  "push.devWebApp": ["{p} web app", "{p} 网页 App", "{p} 網頁 App"],
  "push.devTab": ["{p} browser", "{p} 浏览器", "{p} 瀏覽器"],
  "push.devThis": ["This device", "这台设备", "這台裝置"],
  "push.plat.iphone": ["iPhone", "iPhone", "iPhone"],
  "push.plat.ipad": ["iPad", "iPad", "iPad"],
  "push.plat.mac": ["Mac", "Mac", "Mac"],
  "push.plat.windows": ["Windows", "Windows", "Windows"],
  "push.plat.android": ["Android", "Android", "Android"],
  "push.sendFailN": ["Send failed ({n})", "发送失败（{n}）", "傳送失敗（{n}）"],
  // Device list: all devices of this account subscribed to push; can be deleted manually
  "push.devList": ["Devices on this account", "这个账户的设备", "這個帳號的裝置"],
  "push.devNone": ["No devices have notifications on", "还没有设备开启通知", "還沒有裝置開啟通知"],
  "push.devSelf": ["This device", "本机", "本機"],
  "push.devActive": ["In use now", "正在用", "正在用"],
  "push.devLast": ["Last active: {t}", "最后活跃：{t}", "最後活躍：{t}"],
  "push.devUnknown": ["Unknown device (old subscription)", "未知设备（旧订阅）", "未知裝置（舊訂閱）"],
  "push.devDel": ["Remove", "删除", "刪除"],
  "push.devDelTitle": ["Remove notifications for {dev}?", "删除「{dev}」的通知？", "刪除「{dev}」的通知？"],
  "push.devDelSelf": ["This will stop notifications on this device. Turn them on again here to get them back.",
    "会停止本机推送，之后要在这里重新开启通知才会再收到", "會停止本機推播，之後要在這裡重新開啟通知才會再收到"],
  "push.devDelOther": ["If that device opens Soulgent again it signs up again on its own, so this only sticks for devices you no longer use.",
    "那台再打开 Soulgent 会自动重新登记，所以只对不再用的设备有效", "那台再開啟 Soulgent 會自動重新登記，所以只對不再使用的裝置有效"],
  "push.devDeleted": ["Removed", "已删除", "已刪除"],
  // ---------- Signed-in devices (login tokens; Me page) ----------
  "me.logins": ["Where you're signed in", "登录管理（各设备）", "登入管理（各裝置）"],
  "signin.title": ["Devices signed in to this account", "这个账户已登录的设备", "這個帳號已登入的裝置"],
  "signin.hint": ["Signing a device out means it has to enter the key again. Changing the key signs out every device.",
    "退出后那台设备要重新输入密钥。换密钥会让所有设备一起退出。", "登出後那台裝置要重新輸入金鑰。更換金鑰會讓所有裝置一起登出。"],
  "signin.none": ["No device list yet (it appears after this device's next sign-in)", "暂无设备列表（本机下次登录后出现）", "暫無裝置清單（本機下次登入後出現）"],
  "signin.self": ["This device", "本机", "本機"],
  "signin.devHere": ["Using it now", "正在使用", "正在使用"],
  "signin.devLast": ["Last used: {t}", "最后使用：{t}", "最後使用：{t}"],
  "signin.devUnknown": ["Unknown device", "未知设备", "未知裝置"],
  "signin.out": ["Sign out", "退出", "登出"],
  "signin.outSelfTitle": ["Sign out this device?", "退出本机登录？", "登出本機？"],
  "signin.outSelfHint": ["You'll go back to the login page and need the key to come back in.", "会回到登录页，之后要用密钥重新登录。", "會回到登入頁，之後要用金鑰重新登入。"],
  "signin.outOtherTitle": ["Sign out {dev}?", "让「{dev}」退出登录？", "讓「{dev}」登出？"],
  "signin.outOtherHint": ["That device will need the key to sign in again.", "那台设备要用密钥重新登录。", "那台裝置要用金鑰重新登入。"],
  "signin.outDone": ["Signed out", "已退出", "已登出"],
  "push.agoNow": ["just now", "刚刚", "剛剛"],
  "push.agoMin": ["{n} min ago", "{n} 分钟前", "{n} 分鐘前"],
  "push.agoHour": ["{n} h ago", "{n} 小时前", "{n} 小時前"],
  "push.agoDay": ["{n} days ago", "{n} 天前", "{n} 天前"],
  "toast.allSeen": ["All marked as seen", "已全部标为看过", "已全部標為已看"],
  "toast.seen": ["Marked as seen", "已标为看过", "已標為已看"],
  "sheet.offN": ["{n} off duty", "{n} 个下班", "{n} 個下班"],
  // ---------- app.js: context panel ----------
  "ctx.ariaNone": ["Context: no data", "上下文：没有数据", "上下文：沒有資料"],
  "ctx.title": ["Context", "上下文", "上下文"],
  "ctx.loading": ["Reading details…", "正在读取明细…", "正在讀取明細…"],
  "ctx.failN": ["Couldn't read details ({n})", "读取明细失败（{n}）", "讀取明細失敗（{n}）"],
  "ctx.net": ["Network down; couldn't read details", "网络不通，读取明细失败", "網路不通，讀取明細失敗"],
  // ---------- app.js: chat page ----------
  "toast.notOff": ["It's no longer on the off-duty list", "它已经不在下班名单里了", "它已經不在下班名單裡了"],
  "toast.noSession": ["That session no longer exists", "会话已不存在", "會話已不存在"],
  "dt.noRecord": ["Can't find the chat history", "找不到对话记录", "找不到對話紀錄"],
  "dt.noRecordSub": ["It may have been woken up, or the roster changed", "它可能已经被唤醒或名册已变", "它可能已經被喚醒，或名冊已變動"],
  "dt.endedSub": ["It may have ended", "它可能已经结束了", "它可能已經結束了"],
  "dt.loadFailSub": ["Network down or the Mac isn't responding", "网络不通或 Mac 没响应", "網路不通或 Mac 沒有回應"],
  "dt.fmtWarn": ["Some messages may not display: unrecognized Claude Code format", "部分消息可能无法显示：Claude Code 格式无法识别", "部分訊息可能無法顯示：Claude Code 格式無法辨識"],
  "dt.noProgress": ["(No progress yet)", "（暂无进度）", "（暫無進度）"],
  "dt.noView": ["Viewing chats isn't supported for this kind of session", "此类会话暂不支持查看对话", "這類會話暫不支援查看對話"],
  "dt.empty": ["No messages yet", "还没有对话", "還沒有對話"],
  "dt.earliest": ["That's the beginning", "已经到最早", "已經到最早"],
  "dt.older": ["Load earlier", "加载更早", "載入更早"],
  "tl.report": ["Subagent report", "子代理回报", "子代理回報"],
  "tl.tools": ["Used tools {n} times", "用了 {n} 次工具", "用了 {n} 次工具"],
  "tl.agent": ["delegated {n} subagents", "派了 {n} 个子代理", "派了 {n} 個子代理"],
  "tl.cmd": ["ran {n} commands", "跑了 {n} 条命令", "執行了 {n} 個指令"],
  "tl.read": ["read {n} files", "读了 {n} 个文件", "讀了 {n} 個檔案"],
  "tl.edit": ["edited files {n} times", "改了 {n} 次文件", "改了 {n} 次檔案"],
  "tl.search": ["searched {n} times", "搜了 {n} 次", "搜尋了 {n} 次"],
  "tl.other": ["used other tools {n} times", "用了 {n} 次其他工具", "用了 {n} 次其他工具"],
  "tl.reports": ["· {n} reports", "· {n} 份回报", "· {n} 份回報"],
  "tl.allOk": ["All done", "都已完成", "都已完成"],
  "tl.hasErr": ["Some failed", "有出错", "有出錯"],
  "md.code": ["Code", "代码", "程式碼"],
  "md.table": ["Table", "表格", "表格"],
  // ---------- app.js: bubbles / subagent page ----------
  "chat.openedFiles": ["opened files", "打开了文件", "開啟了檔案"],
  "chat.replying": ["Replying", "正在回复", "正在回覆"],
  "ag.tapHint": ["Tap to view subagents", "点击查看子代理", "點一下查看子代理"],
  "ag.tapBack": ["Tap to flip back", "点击翻回", "點一下翻回"],
  "ag.ranFor": ["Ran {t}", "已跑 {t}", "已跑 {t}"],
  "ag.loadFailSub": ["Couldn't read the subagent's log; go back and try again", "子代理记录读不到，返回再试", "讀不到子代理紀錄，返回再試"],
  "ag.main": ["Main session · {name}", "主会话 · {name}", "主會話 · {name}"],
  "ag.mainDefault": ["main session", "主会话", "主會話"],
  "ag.noRecord": ["Nothing recorded yet", "还没有记录", "還沒有紀錄"],
  "ag.readOnly": ["Subagent chat, read-only · sent by “{name}”", "子代理对话只读 · 由「{name}」派出", "子代理對話唯讀 · 由「{name}」派出"],
  "chat.attachN": ["[{n} attachments]", "[附件 ×{n}]", "[附件 ×{n}]"],
  "chat.sentWait": ["Sent, waiting for confirmation…", "已发送，等待确认…", "已傳送，等待確認…"],
  "ask.adminApprove": ["Waiting for admin approval", "等管理员批准", "等管理員核准"],
  "ask.youApprove": ["Waiting for your approval", "等你批准", "等你核准"],
  "ask.more": ["{n} more awaiting approval", "还有 {n} 条待批准", "還有 {n} 則待核准"],
  "ask.guestApprove": ["The admin approves this on the Mac; after that you can reply in text", "由管理员在 Mac 上批准，处理完你可以用文字回复", "由管理員在 Mac 上核准，處理完你可以用文字回覆"],
  "ask.answered": ["Answered", "已回答", "已回答"],
  "ask.askAdmin": ["Asking the admin", "在问管理员", "在問管理員"],
  "ask.askYou": ["Asking you", "在问你", "在問你"],
  "ask.guestAnswer": ["The admin answers this; after that you can reply with your thoughts", "由管理员作答；答完后你可以用文字回复你的意见", "由管理員作答；答完後你可以用文字回覆你的意見"],
  "ask.tooMany": ["Too many options; answer in Orca", "选项太多，请到 Orca 回答", "選項太多，請到 Orca 回答"],
  "ask.nq": ["{n} questions", "{n} 题", "{n} 題"],
  "ask.submit": ["Submit", "提交", "送出"],
  "ask.submitN": ["Submit ({n}/{total} answered)", "提交（已答 {n}/{total}）", "送出（已答 {n}/{total}）"],
  "ask.multi": ["Multiple choice", "可多选", "可複選"],
  "ask.addMore": ["Add another…", "再补一项…", "再補一項…"],
  "ask.own": ["Type your own…", "自己填…", "自己填…"],
  "ask.note": ["Note: ", "备注：", "備註："],
  "ask.notePh": ["Add a note…", "附带备注…", "附帶備註…"],
  "orca.copied": ["Copied “{name}”; open Orca manually", "已复制「{name}」，请手动打开 Orca", "已複製「{name}」，請手動開啟 Orca"],
  "orca.downHint": ["Orca isn't open. Messages will queue until it is.", "Orca 没开，消息会排队，开了以后才打进去。", "Orca 沒開，訊息會排隊，開了之後才送進去。"],
  // ---------- app.js: attachments ----------
  "up.tooBig": ["{n} files are over 20 MB and weren't added", "有 {n} 个文件超过 20 MB，没加进来", "有 {n} 個檔案超過 20 MB，沒有加入"],
  "up.tooMany": ["Up to 9 attachments; {n} weren't added", "最多 9 个附件，有 {n} 个没加进来", "最多 9 個附件，有 {n} 個沒有加入"],
  "up.remove": ["Remove attachment", "移除附件", "移除附件"],
  "up.queued": ["Queued, waiting for the previous message…", "排队中，等上一条发完…", "排隊中，等上一則傳完…"],
  "up.processing": ["Processing…", "处理中…", "處理中…"],
  "up.failed": ["Attachments didn't finish uploading; not sent: {why}", "附件没传完，没有发送：{why}", "附件沒傳完，沒有傳送：{why}"],
  "up.noClip": ["No image on the clipboard. After taking a screenshot, tap the thumbnail → “Done” → “Copy and Delete”, then tap “Paste” here", "剪贴板里没有图片。截图后点缩略图 →「完成」→「拷贝并删除」，再来点「粘贴」", "剪貼簿裡沒有圖片。截圖後點縮圖 →「完成」→「拷貝並刪除」，再回來點「貼上」"],
  "c.copyFailAlt": ["Copy failed, try another way", "复制失败，请换种方式", "複製失敗，請換個方式"],
  "bm.copy": ["Copy", "复制", "複製"],
  "bm.copysel": ["Copy selection", "复制所选", "複製所選"],
  "bm.select": ["Select text", "选择文字", "選取文字"],
  "bm.quote": ["Quote", "引用", "引用"],
  "bm.forward": ["Forward", "转发", "轉傳"],
  "bm.recall": ["Unsend", "撤回", "收回"],
  "bm.resend": ["Resend", "重新发送", "重新傳送"],
  "bm.delete": ["Delete", "删除", "刪除"],
  "bm.share": ["Save/Share", "保存/分享", "儲存／分享"],
  "bm.download": ["Download", "下载", "下載"],
  "bm.copypath": ["Copy path", "复制路径", "複製路徑"],
  "sel.title": ["Select text", "选择文字", "選取文字"],
  "sel.copyAll": ["Copy all", "复制全文", "複製全文"],
  "at.loading": ["Loading…", "加载中…", "載入中…"],
  "at.cut": ["Only the first 2 MB is shown", "只显示前 2MB", "只顯示前 2MB"],
  "at.retryTap": ["File is ready, tap again", "文件已准备好，再点一次", "檔案已準備好，再點一次"],
  "at.newTab": ["Open in new tab", "在新标签打开", "在新分頁開啟"],
  "at.goneName": ["File no longer exists · {name}", "文件已不在 · {name}", "檔案已不在 · {name}"],
  "at.moreN": ["{n} more files", "还有 {n} 个文件", "還有 {n} 個檔案"],
  "at.imageN": ["Image {n}", "图片 {n}", "圖片 {n}"],
  "chat.imgRaw": ["[Image]", "[图片]", "[圖片]"],
  // ---------- app.js: receipts / recall / forward ----------
  "rcl.clock": ["Sending, not on the server yet", "发送中，还没到服务器", "傳送中，還沒到伺服器"],
  "rcl.failed": ["Not delivered, tap to resend or delete", "未送达，点一下重新发送或删除", "未送達，點一下重新傳送或刪除"],
  "rcl.sent": ["Delivered — it'll read when free", "已送到，它忙完会读", "已送到，它忙完會讀"],
  "rcl.delivered": ["Delivered — it'll read when free", "已送到，它忙完会读", "已送到，它忙完會讀"],
  "rcl.read": ["Read", "已读", "已讀"],
  "recall.ask": ["Delivered, the agent hasn't read it yet. Unsend this message?", "已送达，Agent 还没读。撤回这条消息？", "已送達，Agent 還沒讀。要收回這則訊息嗎？"],
  "recall.going": ["Unsending…", "正在撤回…", "正在收回…"],
  "recall.mine": ["You unsent a message", "你撤回了一条消息", "你收回了一則訊息"],
  "recall.theirs": ["{name} unsent a message", "{name}撤回了一条消息", "{name}收回了一則訊息"],
  "recall.other": ["The other side", "对方", "對方"],
  "recall.redo": ["Edit again", "重新编辑", "重新編輯"],
  "fwd.title": ["Forward to…", "转发给…", "轉傳給…"],
  "fwd.noMatch": ["No matching sessions", "没有匹配的会话", "沒有符合的會話"],
  "fwd.none": ["No other sessions to forward to", "没有别的可转发的会话", "沒有其他可轉傳的會話"],
  // ---------- app.js: wake / input area / chat page menu ----------
  "wake.going": ["Waking… about 10 s", "唤醒中…约 10 秒", "喚醒中…約 10 秒"],
  "wake.entering": ["Awake, opening…", "已唤醒，正在进入…", "已喚醒，正在進入…"],
  "wake.notYet": ["Awake, but the session hasn't appeared yet; it'll show up on the home page soon", "已唤醒，但会话还没出现，稍后会在主页出现", "已喚醒，但會話還沒出現，稍後會在首頁出現"],
  "dm.refresh": ["Refresh chat", "刷新对话", "重新整理對話"],
  "dm.seen": ["Mark as seen", "标为看过", "標為已看"],
  "dm.orca": ["Open in Orca", "去 Orca", "前往 Orca"],
  "diag.on": ["Diagnostic log on: actions will be sent to the Mac", "诊断日志已开：操作记录会发到 Mac", "診斷紀錄已開啟：操作紀錄會傳到 Mac"],
  "diag.off": ["Diagnostic log off", "诊断日志已关", "診斷紀錄已關閉"],
  // ---------- app.js: pre-window-switch record / find in chat / chat info ----------
  "older.continued": ["Load records from before compaction", "加载压缩续接前的记录", "載入壓縮續接前的紀錄"],
  "older.prev": ["Load records from before the window switch", "加载换窗前的记录", "載入換窗前的紀錄"],
  "toast.loadingWait": ["Loading, try again in a moment", "正在加载，请稍后再点", "正在載入，請稍後再點"],
  "toast.jumpFail": ["Couldn't jump there", "跳转失败", "跳轉失敗"],
  "toast.hitGone": ["Couldn't find that message (it may be folded or changed)", "没找到这条（可能被折叠或已变）", "找不到這則（可能被收合或已變動）"],
  "ch.latest": ["Back to latest", "回到最新", "回到最新"],
  "toast.offNoInfo": ["Not available for off-duty sessions", "已下班的会话暂不支持", "已下班的會話暫不支援"],
  "ch.info": ["Chat info", "聊天信息", "聊天資訊"],
  "ch.find": ["Search chat", "查找聊天内容", "搜尋聊天內容"],
  "ch.mute": ["Mute messages", "消息免打扰", "訊息勿擾"],
  "ch.top": ["Pin chat", "置顶聊天", "釘選聊天"],
  "toast.topped": ["Pinned", "已置顶", "已釘選"],
  "toast.untopped": ["Unpinned", "已取消置顶", "已取消釘選"],
  "toast.muted": ["Muted", "已开启消息免打扰", "已開啟訊息勿擾"],
  "toast.unmuted": ["Unmuted", "已关闭消息免打扰", "已關閉訊息勿擾"],
  "ch.searching": ["Searching…", "正在搜索…", "正在搜尋…"],
  "ch.searchFail": ["Search failed, try again later", "搜索失败，请稍后再试", "搜尋失敗，請稍後再試"],
  "ch.none": ["Nothing found for “{q}”", "没有找到「{q}」", "找不到「{q}」"],
  "ch.count": ["{n} results", "共 {n} 条", "共 {n} 則"],
  "ch.countPrev": ["({n} before window switch)", "（换窗前 {n} 条）", "（換窗前 {n} 則）"],
  "ch.count50": [", showing the latest 50 only", "，只列最近 50 条", "，只列出最近 50 則"],
  "ch.prevTag": ["Before window switch ·", "换窗前 ·", "換窗前 ·"],
  // ---------- app.js: edit profile ----------
  "pf.title": ["Edit profile", "编辑资料", "編輯個人資料"],
  "pf.change": ["Change avatar", "更换头像", "更換大頭貼"],
  "pf.remove": ["Remove avatar", "移除头像", "移除大頭貼"],
  "pf.badImg": ["Can't read this image, try another", "这张图读不了，换一张试试", "這張圖讀不了，換一張試試"],
  "pf.name": ["Nickname", "昵称", "暱稱"],
  "pf.saveFail": ["Save failed, try again later", "保存失败，请稍后再试", "儲存失敗，請稍後再試"],
  "pf.noteGuest": ["Your avatar and nickname show next to your bubbles, in search results, chat info and here; the admin sees your messages with these too.", "头像和昵称显示在你的气泡旁、搜索结果、聊天信息和这里；管理员那边看你的消息也用这份。", "大頭貼和暱稱顯示在你的對話泡泡旁、搜尋結果、聊天資訊和這裡；管理員那邊看你的訊息也用這份。"],
  "pf.note": ["Your avatar and nickname show next to your bubbles, in search results, chat info and here; {guest} can't see them.", "头像和昵称显示在你的气泡旁、搜索结果、聊天信息和这里；{guest}那边看不到。", "大頭貼和暱稱顯示在你的對話泡泡旁、搜尋結果、聊天資訊和這裡；{guest}那邊看不到。"],
  "vw.share": ["Share", "分享", "分享"],
  // @@END-STR
};

// ---------- Language detection ----------
export function detectLang(list) {
  const first = Array.isArray(list) ? list.find((x) => x) : list;
  const l = String(first || "").toLowerCase().replace(/_/g, "-");
  if (!l.startsWith("zh")) return "en";
  if (/^zh-hans/.test(l)) return "hans";
  if (/^zh-(hant|tw|hk|mo)\b/.test(l)) return "hant";
  return "hans";
}
function storedPref() {
  try {
    const v = globalThis.localStorage && globalThis.localStorage.getItem(LANG_KEY);
    return COL[v] != null ? v : "";
  } catch (e) { return ""; }
}
function sysLangs() {
  const n = globalThis.navigator;
  if (!n) return [];
  return n.languages && n.languages.length ? n.languages : [n.language];
}
let cur = storedPref() || detectLang(sysLangs());

export function lang() { return cur; }
// the language currently chosen on the "Me" page switch: "auto" follows the system, or en / hans / hant
export function langPref() { return storedPref() || "auto"; }
// only changes this page's current language (for tests and startup); does not write localStorage
export function setLang(l) {
  cur = COL[l] != null ? l : detectLang(sysLangs());
  return cur;
}
// "Me" page switch: writes localStorage (auto = delete it, back to following the system); the caller reloads the page afterwards
export function saveLangPref(p) {
  try {
    if (COL[p] != null) globalThis.localStorage.setItem(LANG_KEY, p);
    else globalThis.localStorage.removeItem(LANG_KEY);
  } catch (e) { /* ignore if private mode blocks the write */ }
  return setLang(COL[p] != null ? p : "");
}
export function isEn() { return cur === "en"; }
// language names in the "Me" page language switch: written in their own script, independent of UI language
export const LANG_NAMES = { hans: "简体中文", hant: "繁體中文", en: "English" };
// region code for Intl / localeCompare; also written to <html lang>
export function locale() { return cur === "en" ? "en-US" : cur === "hant" ? "zh-TW" : "zh-CN"; }

export function has(key) { return Object.prototype.hasOwnProperty.call(STR, key); }
export function t(key, vars) {
  const row = has(key) ? STR[key] : null;
  let s = row ? (row[COL[cur]] || (cur === "hant" ? row[1] : "") || row[0]) : "";
  if (!s) return key;
  if (vars) s = s.replace(/\{(\w+)\}/g, (m, k) => (vars[k] != null ? String(vars[k]) : m));
  return s;
}
// look up by code: key = prefix + code; if missing, return fallback (the server's original text, or empty)
export function tCode(prefix, code, fallback) {
  return code != null && has(prefix + code) ? t(prefix + code) : fallback;
}
// for tests: the whole table (read-only)
export function table() { return STR; }

// ---------- Static page replacement ----------
// <x data-i18n="key"> replaces textContent; <x data-i18n-attr="aria-label:key;placeholder:key2"> replaces attributes
export function applyI18n(root) {
  const doc = root || globalThis.document;
  if (!doc || !doc.querySelectorAll) return;
  for (const el of doc.querySelectorAll("[data-i18n]")) el.textContent = t(el.getAttribute("data-i18n"));
  for (const el of doc.querySelectorAll("[data-i18n-attr]")) {
    for (const pair of el.getAttribute("data-i18n-attr").split(";")) {
      const i = pair.indexOf(":");
      if (i > 0) el.setAttribute(pair.slice(0, i).trim(), t(pair.slice(i + 1).trim()));
    }
  }
  if (doc.documentElement) {
    doc.documentElement.lang = locale();
    doc.documentElement.setAttribute("data-i18n-done", "1"); // shown only after replacement is done (index.html header styles hide the page until then, so Chinese phones don't flash English first)
  }
}

// ---------- Dates ----------
// Chinese (Simplified/Traditional) uses relative dates; English uses Intl
const enFmt = (o) => new Intl.DateTimeFormat("en-US", o);
// month-day: Chinese "month/day" form or e.g. Oct 12
export function fmtMD(d) {
  return cur === "en" ? enFmt({ month: "short", day: "numeric" }).format(d) : (d.getMonth() + 1) + "月" + d.getDate() + "日";
}
// year-month-day: Chinese "year/month/day" form or e.g. Oct 12, 2025
export function fmtYMD(d) {
  return cur === "en" ? enFmt({ year: "numeric", month: "short", day: "numeric" }).format(d) : d.getFullYear() + "年" + (d.getMonth() + 1) + "月" + d.getDate() + "日";
}
// weekday (long): Chinese long weekday name or e.g. Monday
export function fmtWeekday(d) {
  return cur === "en" ? enFmt({ weekday: "long" }).format(d) : "星期" + "日一二三四五六"[d.getDay()];
}
// weekday (short): Chinese short weekday name (Traditional uses a different first character) or e.g. Mon
export function fmtWeekdayShort(d) {
  return cur === "en" ? enFmt({ weekday: "short" }).format(d) : (cur === "hant" ? "週" : "周") + "日一二三四五六"[d.getDay()];
}
// English 12-hour clock time: 1:42 PM
export function fmtClockEn(d) { return enFmt({ hour: "numeric", minute: "2-digit" }).format(d); }
// Chinese day periods (small hours / early morning / morning / noon / afternoon / evening); Traditional uses the same characters
export function dayPart(h) {
  return h < 6 ? "凌晨" : h < 9 ? "早上" : h < 12 ? "上午" : h < 13 ? "中午" : h < 18 ? "下午" : "晚上";
}
// "Me" page heatmap header: Chinese weekday initials, Monday first, or M T W T F S S
export function weekHeads() { return cur === "en" ? ["M", "T", "W", "T", "F", "S", "S"] : "一二三四五六日".split(""); }
// list separator: Chinese enumeration comma or ", "
export function joinList(arr) { return arr.join(cur === "en" ? ", " : "、"); }
// Chinese and English colons and parentheses (used when composing "label：content" and "（note）")
export function colon() { return cur === "en" ? ": " : "："; }
export function comma() { return cur === "en" ? ", " : "，"; }
export function paren(s) { return cur === "en" ? " (" + s + ")" : "（" + s + "）"; }
// quotes: Chinese corner brackets or curly double quotes
export function quote(s) { return cur === "en" ? "“" + s + "”" : "「" + s + "」"; }

// ---------- Server / Agent original-text matching (not translated, only used to recognize text) ----------
// These are Chinese original texts sent by the server or Agent, which the frontend compares / strips. Current servers send codes / empty values; these are kept to recognize older backends and archived data
export const RAW = {
  guest: "访客",        // api/profile.py default value (when .env has no GUEST_NAME): if equal, display the localized guest name for the current language
  me: "我",              // legacy api/profile.py DEFAULT_NAME (now an empty string; archived data may hold the Chinese word for "me")
  unzoned: "未分区",      // legacy zone name helper/snapshot.py gave to unzoned sessions (now an empty string; the frontend treats a code mismatch as unzoned)
  compacted: "（上下文已压缩）", // legacy compaction notice text from api/transcript.py (now {role:"notice", code:"compacted"})
  fromRe: /^\s*来自\s*[^\n：:]{1,40}[：:]\s*/,                 // leading "from <name>:" prefix (Chinese wording) of subagent / inter-session messages
  forceRe: /[（(]加 --force 强制[)）]/,                         // command-line hint ("add --force") in the original off-duty failure text
  bracketRe: /^[\[【(（<](.+)[\]】)）>]$/,                      // whole-segment bracketed labels in ASCII or full-width brackets
};
