-- _rpc_query_timing_selftest.lua —— **慢查询探针**的回归（2026-10-24 加 ✓✓）
--
-- 主人原话：「注意不要再加之前那种超高消耗的操作了」✓✓
--   → 光有规矩不够 ✗，还得**看得见**：单次 RPC 超过 100 ms 必须留一行 ✓（G4 ✓）。
--   本自检钉住 `net/rpc.lua` 的 handler 计时 + `lib/copilot/perf.lua` 的阈值/节流 ✓。
--
-- 钉住的四件事：
--   ① 慢 handler（> 阈值）→ perf.log 留一行，**名字带 what** + 毫秒 ✓
--   ② 快 handler（< 阈值）→ 一条都不写 ✓（探针自己不许变成负载 ✗）
--   ③ 非 query 命令 → 名字是 `rpc.<cmd>`（不带 what ✓）
--   ④ handler **报错也记**（ERR 前缀 ✓）—— 慢 + 错同样要能看见 ✓
--   另外：阈值可调（`QUERY_THRESHOLD_MS` 缺省 100 ✓）、节流按名字（同一名字 30 秒一条 ✓）、
--        包装不改变答复契约（ok/payload/HANDLER_ERROR 原样 ✓）。
--
-- 跑法（在仓库根执行）：
--   build\harness\lua.exe native\harness\_rpc_query_timing_selftest.lua

package.path = package.path .. ";data/scripts/lib/?.lua"
package.path = package.path .. ";data/scripts/?.lua"

local failures, checks = 0, 0
local function check(name, ok, extra)
    checks = checks + 1
    if ok then
        print(string.format("  PASS  %s", name))
    else
        failures = failures + 1
        print(string.format("  FAIL  %s   -> %s", name, tostring(extra)))
    end
end

-- ---------------------------------------------------------------------------
-- 替身：可控时钟（rpc.lua 与 perf.lua 都取全局 os.clock ✓）+ 传输层
-- ---------------------------------------------------------------------------
local CLOCK = 0
local realClock = os.clock
os.clock = function() return CLOCK end

local Perf = dofile("data/scripts/lib/copilot/perf.lua")
Perf.LOG_PATH = "build/_perf_rpc_timing.log"
os.remove(Perf.LOG_PATH)

include = function(name)
    if name == "copilot/perf" then return Perf end
    error("unexpected include: " .. tostring(name))
end

local REPLIES = {}
CopilotOut = {
    sendReply = function(id, cmd, ok, payload, message)
        REPLIES[#REPLIES + 1] = { id = id, cmd = cmd, ok = ok, payload = payload, message = message }
    end,
    request = function() return { id = 0 } end,
    send = function() return true end,
}
CopilotNet = { emit = function() end, report = function() end }

-- 加载被测框架（**原样** ✓）
CopilotRpc = nil
dofile("data/scripts/net/rpc.lua")
local Rpc = CopilotRpc
Rpc.tracing = false                      -- ★ 自检不写 rpc_trace.log（不碰主人真实日志 ✓）

-- 探针账本
local function lineCount()
    local fh = io.open(Perf.LOG_PATH, "r")
    if fh == nil then return 0 end
    local n = 0
    for _ in fh:lines() do n = n + 1 end
    fh:close()
    return n
end

local function logText()
    local fh = io.open(Perf.LOG_PATH, "r")
    if fh == nil then return "" end
    local text = fh:read("*a") or ""
    fh:close()
    return text
end

-- 唯一一个 query handler：按 what 决定"这次跑多久"（模拟慢/快）✓
Rpc.handle("query", function(data)
    local what = tostring(data and data.what)
    if what == "ship" then
        CLOCK = CLOCK + 0.01                    -- 10 ms（远低于 100 ms ✓）
    elseif what == "slowError" then
        CLOCK = CLOCK + 0.25                    -- 250 ms 然后**报错** ✓
        error("kaboom")
    else
        CLOCK = CLOCK + 0.25                    -- 250 ms（慢查询 ✓）
    end
    return true, { ok = true, what = what }
end)

Rpc.handle("order", function()
    CLOCK = CLOCK + 0.3                         -- 300 ms（非 query 命令 ✓）
    return true, { accepted = true }
end)

local function request(cmd, data)
    return Rpc.onRequest({ id = #REPLIES + 1, type = "request", cmd = cmd, data = data })
end

-- ---------------------------------------------------------------------------
-- ⓪ 常量与名字
-- ---------------------------------------------------------------------------
print("== ⓪ 阈值缺省 100 ms；探针名字带 what ==")
do
    check("⓪ QUERY_THRESHOLD_MS 缺省 = 100 ms（G4 那道闸 ✓）",
        Perf.QUERY_THRESHOLD_MS == 100, tostring(Perf.QUERY_THRESHOLD_MS))
    check("⓪ query 的名字是 `rpc.query:<what>` ✓",
        Rpc.queryLabel("query", { what = "predict" }) == "rpc.query:predict",
        Rpc.queryLabel("query", { what = "predict" }))
    check("⓪ 非 query 的名字是 `rpc.<cmd>`（不带 what ✓）",
        Rpc.queryLabel("order", { what = "x" }) == "rpc.order",
        Rpc.queryLabel("order", { what = "x" }))
    check("⓪ 还没有任何记录（平时一条都不写 ✓）", lineCount() == 0, tostring(lineCount()))
end

-- ---------------------------------------------------------------------------
-- ① 慢 query（250 ms）→ 留一行，带 what + 毫秒
-- ---------------------------------------------------------------------------
print("== ① 慢 query（250 ms）：留一行 `rpc.query:predict` + 毫秒 ==")
do
    request("query", { what = "predict" })
    local text = logText()
    check("① 写了一条 ✓", lineCount() == 1, tostring(lineCount()))
    check("① 名字带 what（rpc.query:predict ✓）",
        text:find("rpc.query:predict", 1, true) ~= nil, text)
    check("① 带毫秒数字（250.0 ms ✓）", text:find("250.0 ms", 1, true) ~= nil, text)
    check("① 答复契约不变（ok=true / payload 原样 ✓）",
        #REPLIES == 1 and REPLIES[1].ok == true and type(REPLIES[1].payload) == "table"
        and REPLIES[1].payload.ok == true, tostring(REPLIES[1] and REPLIES[1].ok))
end

-- ---------------------------------------------------------------------------
-- ② 快 query（10 ms）→ 一条都不写（探针自己不许变成负载 ✓）
-- ---------------------------------------------------------------------------
print("== ② 快 query（10 ms）：不写（阈值 100 ms ✓）==")
do
    request("query", { what = "ship" })
    check("② 亚阈值：没有新增一行 ✓", lineCount() == 1, tostring(lineCount()))
end

-- ---------------------------------------------------------------------------
-- ③ 另一个慢 query（不同 what）→ 按名字各自记一份（不被前一条挤掉 ✓）
-- ---------------------------------------------------------------------------
print("== ③ 另一个慢 query（tradeRoutes）：按名字各自记一份 ✓ ==")
do
    request("query", { what = "tradeRoutes" })
    local text = logText()
    check("③ 新增一条 ✓", lineCount() == 2, tostring(lineCount()))
    check("③ 两条名字不同（predict / tradeRoutes ✓）",
        text:find("rpc.query:predict", 1, true) ~= nil
        and text:find("rpc.query:tradeRoutes", 1, true) ~= nil, text)
end

-- ---------------------------------------------------------------------------
-- ④ 非 query 命令（order）→ 名字是 `rpc.order`
-- ---------------------------------------------------------------------------
print("== ④ 非 query（order 300 ms）：名字是 `rpc.order` ✓ ==")
do
    request("order", { ship = "x" })
    local text = logText()
    check("④ 新增一条 ✓", lineCount() == 3, tostring(lineCount()))
    check("④ 名字是 rpc.order（没有 what 尾巴 ✓）",
        text:find("rpc.order", 1, true) ~= nil and text:find("rpc.order:", 1, true) == nil, text)
end

-- ---------------------------------------------------------------------------
-- ⑤ 同一名字 30 秒内再来一次 → 被节流挡住（不刷屏 ✓）
-- ---------------------------------------------------------------------------
print("== ⑤ 同一名字立刻再来：30 秒节流挡住 ✓ ==")
do
    request("query", { what = "predict" })
    check("⑤ 同一名字 30 秒内不重复写（总条数仍是 3 ✓）", lineCount() == 3, tostring(lineCount()))
end

-- ---------------------------------------------------------------------------
-- ⑥ handler 报错也记（ERR 前缀 ✓）—— 慢 + 错同样要能看见
-- ---------------------------------------------------------------------------
print("== ⑥ 慢且报错：留一行带 ERR，答复仍是 HANDLER_ERROR ✓ ==")
do
    request("query", { what = "slowError" })
    local text = logText()
    local last = REPLIES[#REPLIES]
    check("⑥ 故障也记了一条 ✓", lineCount() == 4, tostring(lineCount()))
    check("⑥ 名字带 what（rpc.query:slowError ✓）",
        text:find("rpc.query:slowError", 1, true) ~= nil, text)
    check("⑥ 带 ERR 前缀 + 原因 ✓", text:find("ERR", 1, true) ~= nil and text:find("kaboom", 1, true) ~= nil, text)
    check("⑥ 答复契约不变（ok=false + HANDLER_ERROR ✓）",
        last ~= nil and last.ok == false and tostring(last.payload) == "HANDLER_ERROR"
        and tostring(last.message):find("kaboom", 1, true) ~= nil,
        tostring(last and last.payload))
end

-- ---------------------------------------------------------------------------
-- ⑦ 阈值可调：调到 1000 ms → 同样的 250 ms 不写了 ✓
-- ---------------------------------------------------------------------------
print("== ⑦ 阈值可调：QUERY_THRESHOLD_MS=1000 → 250 ms 不再写 ✓ ==")
do
    local old = Perf.QUERY_THRESHOLD_MS
    Perf.QUERY_THRESHOLD_MS = 1000
    request("query", { what = "tradeEvaluate" })
    check("⑦ 阈值调高后不写 ✓", lineCount() == 4, tostring(lineCount()))
    Perf.QUERY_THRESHOLD_MS = old
end

-- ---------------------------------------------------------------------------
-- 收尾
-- ---------------------------------------------------------------------------
os.clock = realClock
os.remove(Perf.LOG_PATH)
check("⑧ 自检用的日志已清理（不污染仓库 ✓）", io.open(Perf.LOG_PATH, "r") == nil)

print("")
print(string.format("%d checks, %d failures", checks, failures))
if failures > 0 then os.exit(1) end
print("OK")
