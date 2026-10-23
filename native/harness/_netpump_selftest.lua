-- _netpump_selftest.lua —— RPC/接收泵的**时间预算**回归（2026-10-24 加 ✓✓）
--
-- 起因（主人报告 + 真机取证 ✗）：
--   `moddata/copilot/rpc_trace.log` 里
--     01:35:54  onQuery what=dossier
--     01:36:25  hb ...                ← **31 秒无心跳**
--   病根不是 DLL，是 `net.lua` 的接收泵：一拍最多 32 帧、逐帧**同步**跑 handler，
--   于是队里排一个 21 秒级的 tradePlan/dossier，整拍（心跳 / 超时扫描 / 下单 /
--   空闲扫描）全被拖停 ✗✓。
--
-- 本自检钉住三件事：
--   ① **有预算**：`RECV_MAX_FRAMES` ∈ {1,2}，`RECV_BUDGET_SEC` ≤ 0.05 ✓
--   ② **不丢帧**：帧留在 DLL 队列里，停手后下一拍照样取得到，**顺序不乱、不重复** ✓
--   ③ **超预算就停手**：一帧跑了 0.5 s → 本拍只跑这 1 帧，剩下的下一拍继续 ✓
--
-- 跑法（在仓库根执行）：
--   build\harness\lua.exe native\harness\_netpump_selftest.lua

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
-- 引擎 / 网络替身（只给 updateServer 要用的那一小撮 ✓）
-- ---------------------------------------------------------------------------

-- ★ 可控时钟：net.lua 每次都用**全局 os.clock()** 取时间 ✓ → 换掉它就能演「跑得慢」
local CLOCK = 0
local realClock = os.clock
os.clock = function() return CLOCK end

function onServer() return true end

local CHAT = {}
function Player()
    return {
        getValue = function() return "" end,
        sendChatMessage = function(_, who, ctype, text) CHAT[#CHAT + 1] = tostring(text) end,
    }
end
ChatMessageType = { Information = 0 }

-- ★ RPC 替身：trace 只记条数（不写盘 ✓）
local TRACE = { n = 0 }
CopilotRpc = {
    trace = function() TRACE.n = TRACE.n + 1 end,
    tick = function() end,
    reset = function() end,
}
CopilotLinkIn = nil
CopilotFleet = nil

-- ★ DLL 接收队列替身：recv() 非阻塞、没帧就返回 nil（和真模块同一语义 ✓）
local QUEUE = {}
local CP = {
    connected = function() return true end,
    recv = function()
        local text = table.remove(QUEUE, 1)
        return text
    end,
}

-- ★ 2026-10-24：`net.pump` 周期探针本体（真 perf.lua ✓，只换日志路径 ✓）
--   ⓪~③ 先把阈值拉到天上（**不写盘** ✓），④ 再放开，专测「超阈值真的留一行」✓
local Perf = dofile("data/scripts/lib/copilot/perf.lua")
Perf.LOG_PATH = "build/_perf_netpump.log"
os.remove(Perf.LOG_PATH)
Perf.THRESHOLD_MS = 1e9
include = function(name)
    if name == "copilot/perf" then return Perf end
    error("unexpected include: " .. tostring(name))
end

local Net = dofile("data/scripts/net/net.lua")
Net.getModule = function() return CP end       -- 跳过原生模块 ✓

-- 收到的帧（emit("message", text) 的原样文本）
-- ★ 一帧的「handler 耗时」由 FRAME_COST 扮演：它是**在 emit 里面**烧掉的 ✓
--   —— 预算必须量到这段，才叫"跑完一帧就核账" ✓
local GOT = {}
local FRAME_COST = 0
Net.on("message", function(text)
    GOT[#GOT + 1] = text
    CLOCK = CLOCK + FRAME_COST          -- 模拟同步跑 handler 的耗时 ✓
end)

local function queue(...)
    QUEUE = {}
    for i = 1, select("#", ...) do QUEUE[i] = (select(i, ...)) end
end

local function tickOnce()
    Net.updateServer()
    return Net.lastPump
end

-- ---------------------------------------------------------------------------
-- ⓪ 常量：预算存在且真的很小 ✓
-- ---------------------------------------------------------------------------
print("== ⓪ 泵有预算（不是旧的『一拍 32 帧、无时间上限』✗） ==")
do
    local mf, budget = Net.RECV_MAX_FRAMES, Net.RECV_BUDGET_SEC
    check("⓪ RECV_MAX_FRAMES ∈ {1,2}（每拍最多 1~2 帧 ✓）",
        type(mf) == "number" and mf >= 1 and mf <= 2, tostring(mf))
    check("⓪ RECV_BUDGET_SEC ∈ (0, 0.05]（~30 ms ✓）",
        type(budget) == "number" and budget > 0 and budget <= 0.05, tostring(budget))
    check("⓪ lastPump 有三项取证字段（frames / ms / hitBudget）",
        type(Net.lastPump) == "table" and Net.lastPump.frames ~= nil
        and Net.lastPump.ms ~= nil and Net.lastPump.hitBudget ~= nil,
        type(Net.lastPump))
end

-- ---------------------------------------------------------------------------
-- ① 快帧：一拍跑满上限就停；**帧一帧不少**
-- ---------------------------------------------------------------------------
print("== ① 5 个快帧（每帧 1 ms）：一拍最多 2 帧，5 帧全部送到、顺序不乱 ==")
do
    GOT = {}
    FRAME_COST = 0.001                             -- 一帧 1 ms（远低于预算 ✓）
    queue("F1", "F2", "F3", "F4", "F5")
    local perTick = {}
    local guard = 0
    while #QUEUE > 0 and guard < 20 do
        guard = guard + 1
        local p = tickOnce()
        perTick[#perTick + 1] = p.frames
        check("① 本拍不超过 RECV_MAX_FRAMES（frames=" .. tostring(p.frames) .. "）",
            p.frames <= Net.RECV_MAX_FRAMES, tostring(p.frames))
    end
    check("① 第一拍就用满上限（hitCap ✓，且不是 32 ✗）",
        perTick[1] == Net.RECV_MAX_FRAMES, tostring(perTick[1]))
    check("① 5 帧全部送达（不丢帧 ✓）", #GOT == 5, table.concat(GOT, ","))
    check("① 顺序不变（F1..F5 ✓）",
        table.concat(GOT, ",") == "F1,F2,F3,F4,F5", table.concat(GOT, ","))
    check("① 没有重复（5 帧 = 5 次 emit ✓）", #GOT == 5, tostring(#GOT))
    check("① 队列被真取空（下一拍 recv 拿到 nil ✓）", #QUEUE == 0, tostring(#QUEUE))
end

-- ---------------------------------------------------------------------------
-- ② 慢帧：一帧 0.5 s ≫ 30 ms → 本拍**只跑这一帧**就停手，剩下的下一拍继续
-- ---------------------------------------------------------------------------
print("== ② 3 个慢帧（每帧 0.5 s）：每拍只跑 1 帧、hitBudget=true，3 帧照样全到 ==")
do
    GOT = {}
    FRAME_COST = 0.5                           -- 这一帧 handler 跑了 0.5 s（模拟 dossier ✗）
    queue("S1", "S2", "S3")
    local ticks, perTick = 0, {}
    while #QUEUE > 0 and ticks < 20 do
        ticks = ticks + 1
        local p = tickOnce()
        perTick[#perTick + 1] = p.frames
        check("② 超预算的那一拍只跑 1 帧（frames=" .. tostring(p.frames) .. " ✓）",
            p.frames == 1, tostring(p.frames))
        check("② hitBudget=true（留痕 ✓）", p.hitBudget == true, tostring(p.hitBudget))
    end
    check("② 3 帧全部送达（超预算不丢帧 ✓）", #GOT == 3, table.concat(GOT, ","))
    check("② 顺序不变（S1,S2,S3 ✓）",
        table.concat(GOT, ",") == "S1,S2,S3", table.concat(GOT, ","))
    check("② 没有拍是空的（不饿死：每拍都在推进 ✓）", ticks == 3, tostring(ticks))
end

-- ---------------------------------------------------------------------------
-- ③ 空队：一拍 0 帧、不报错、hitBudget=false
-- ---------------------------------------------------------------------------
print("== ③ 队空：0 帧 / 不报错 ==")
do
    GOT = {}
    local p = tickOnce()
    check("③ frames == 0", p.frames == 0, tostring(p.frames))
    check("③ hitBudget == false", p.hitBudget == false, tostring(p.hitBudget))
    check("③ 没有 emit 任何帧", #GOT == 0, tostring(#GOT))
end

-- ---------------------------------------------------------------------------
-- ④ ★ 2026-10-24：`net.pump` 打点 —— 周期三件套齐了（ops.updateServer / fleet.scan / net.pump ✓）
-- ---------------------------------------------------------------------------
print("== ④ net.pump 探针：慢一拍留一行（名字 + 毫秒 ✓），平时不写 ✓ ==")
do
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

    check("④ ⓪~③ 全程一条都没写（平时不刷屏 ✓）", lineCount() == 0, tostring(lineCount()))

    Perf.THRESHOLD_MS, Perf.MIN_INTERVAL = 0, 0
    GOT = {}
    FRAME_COST = 0.01                       -- 一帧 10 ms（远低于 30 ms 预算 ✓）
    queue("P1")
    local p = tickOnce()
    check("④ 本拍真的跑了一帧（frames=1 ✓）", p.frames == 1, tostring(p.frames))
    check("④ 超阈值 → 写了一条 ✓", lineCount() == 1, tostring(lineCount()))
    local text = logText()
    check("④ 名字是 net.pump ✓", text:find("net.pump", 1, true) ~= nil, text)
    check("④ 带毫秒数字 ✓", text:find("ms", 1, true) ~= nil, text)
    check("④ 带 frames 明细 ✓", text:find("frames=1", 1, true) ~= nil, text)

    os.remove(Perf.LOG_PATH)
end

os.clock = realClock

print(string.format("\n%d 项断言 / 失败 %d", checks, failures))
if failures > 0 then os.exit(1) end
print("OK")
