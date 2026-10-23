-- _trace_io_selftest.lua —— **trace 的 I/O 契约**回归（2026-10-24 加 ✓✓）
--
-- 主人原话（第二步 2.3）：`rpc.lua:30-46` 每行 open+write+close ✗（≈0.97 ms/行 × 6~8 行）
--   → 改成**句柄常开 + 缓冲**，**每行仍带时间戳** ✓，**加大小上限/轮转** ✓（现 3.4 MB / 81701 行 ✓）
--
-- 本自检钉住四件事（每一条都是真机量出来的病 ✗）：
--   ① **不按行开关文件**：连写 N 行 → `io.open` 只被调 **1 次** ✓（旧版 N 次 ✗）
--   ② **每行都落盘**：每行一次 `flush` ✓ —— 这日志的用途是「猝死前最后一句」，
--      攒缓冲 = 证据消失 ✗（用第二个 `io.open` 独立读回验证 ✓）
--   ③ **格式没变**：每行仍是 `HH:MM:SS  文本` ✓（老日志还能对 ✓）
--   ④ **上限与轮转**：超 `TRACE_MAX_BYTES` → 旧文件挪成 `.1`（只留一代）、新文件重新开始 ✓
--   ⑤ 写不进去时**不抛错**、关追踪、并**说出来**（`CopilotNet.report` ✓）
--
-- 跑法（在仓库根执行）：
--   build\harness\lua.exe native\harness\_trace_io_selftest.lua

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
-- 替身：传输层（trace 失败时要 report ✓）
-- ---------------------------------------------------------------------------
local REPORTS = {}
CopilotNet = {
    emit = function() end,
    report = function(msg) REPORTS[#REPORTS + 1] = tostring(msg) end,
}

CopilotRpc = nil
dofile("data/scripts/net/rpc.lua")
local Rpc = CopilotRpc

local PATH = "build/_trace_io_test.log"
Rpc.TRACE_PATH = PATH
os.remove(PATH)
os.remove(PATH .. ".1")

-- io.open 计数（只算被追踪路径 ✓ —— 自检自己读回不算）
local realOpen = io.open
local opens, flushes = 0, 0
io.open = function(path, mode)
    if tostring(path) ~= PATH then return realOpen(path, mode) end
    opens = opens + 1
    local fh = realOpen(path, mode)
    if fh == nil then return nil end
    local wrapper = {}
    function wrapper:write(s) return fh:write(s) end
    function wrapper:flush() flushes = flushes + 1; return fh:flush() end
    function wrapper:seek(...) return fh:seek(...) end
    function wrapper:close() return fh:close() end
    return wrapper
end

local function readAll(path)
    local fh = realOpen(path, "r")
    if fh == nil then return nil end
    local text = fh:read("*a") or ""
    fh:close()
    return text
end

local function sizeOf(path)
    local fh = realOpen(path, "r")
    if fh == nil then return 0 end
    local s = fh:seek("end") or 0
    fh:close()
    return s
end

local function countLines(text)
    local n = 0
    for _ in tostring(text or ""):gmatch("[^\n]+") do n = n + 1 end
    return n
end

-- ★ 时间戳形状：`HH:MM:SS  文本`（与本文件头的旧格式**逐字一致** ✓）
local function allLinesStamped(text)
    local n = 0
    for line in tostring(text or ""):gmatch("[^\n]+") do
        n = n + 1
        if line:match("^%d%d:%d%d:%d%d  .+$") == nil then return false, line end
    end
    return n > 0, n
end

-- ---------------------------------------------------------------------------
-- ① + ② + ③ 句柄常开 / 每行 flush / 格式不变
-- ---------------------------------------------------------------------------
print("== ① 句柄常开 + ② 每行落盘 + ③ 格式不变 ==")
do
    Rpc.TRACE_MAX_BYTES = 1e9            -- 本段不触发轮转 ✓
    Rpc.tracing = true
    Rpc.traceClose()

    local N = 10
    for i = 1, N do Rpc.trace("line-" .. i) end

    check("① io.open 只调 1 次（旧版每行一次 ✗）", opens == 1, tostring(opens))
    check("② flush 次数 = 行数（每行落盘 ✓）", flushes == N, tostring(flushes))

    local text = readAll(PATH)
    check("② 独立读回能看到全部行（缓冲没吃掉证据 ✓）", countLines(text) == N,
        tostring(countLines(text)))
    local okStamp, n = allLinesStamped(text)
    check("③ 每行带 HH:MM:SS 时间戳 ✓", okStamp, tostring(n))
    check("③ 内容原样保留", tostring(text):find("line-10", 1, true) ~= nil, "")

    -- ②b **同一次会话继续写**：句柄仍在，open 计数不再增长 ✓
    Rpc.trace("line-11")
    check("②b 后续写入复用同一句柄（open 仍为 1 ✓）", opens == 1, tostring(opens))
    check("②b 新增那一行也立刻可见", countLines(readAll(PATH)) == N + 1,
        tostring(countLines(readAll(PATH))))
end

-- ---------------------------------------------------------------------------
-- ④ 大小上限 + 轮转（`rpc_trace.log` → `.1`，只留一代）
-- ---------------------------------------------------------------------------
print("== ④ 超上限轮转：旧文件挪成 .1、新文件重新开始 ==")
do
    Rpc.traceClose()
    os.remove(PATH)
    os.remove(PATH .. ".1")
    local big = string.rep("A", 90)       -- 每行 > 100 字节
    Rpc.TRACE_MAX_BYTES = 250             -- 3 行左右就超 ✓
    opens = 0
    Rpc.trace(big .. "-1")
    Rpc.trace(big .. "-2")
    Rpc.trace(big .. "-3")                -- 本行写完即超上限 → 轮转
    local rotated = readAll(PATH .. ".1")
    check("④ 旧文件已挪成 .1（历史留一代 ✓）", rotated ~= nil and #rotated > 0,
        tostring(rotated and #rotated))
    check("④ .1 里有刚写的内容", tostring(rotated):find("-3", 1, true) ~= nil, "")

    Rpc.trace("fresh-after-rotate")
    local current = readAll(PATH)
    check("④ 轮转后新文件从空开始 + 只有新行",
        countLines(current) == 1 and tostring(current):find("fresh%-after%-rotate") ~= nil,
        tostring(countLines(current)))
    local okStamp = allLinesStamped(current)
    check("④ 轮转后仍带时间戳 ✓", okStamp, tostring(current))

    -- ④b 打开时也查大小：句柄丢了（模拟重载）→ 重开时若已超限，立刻轮转 ✓
    Rpc.traceClose()
    os.remove(PATH)
    local fh = realOpen(PATH, "w")
    fh:write(string.rep("B", 400))        -- 已经超 250
    fh:close()
    Rpc.trace("after-big-open")
    check("④b 重开时先看大小：超限立刻轮转（旧内容进 .1 ✓）",
        (readAll(PATH .. ".1") or ""):find("BBBB", 1, true) ~= nil, tostring(#(readAll(PATH .. ".1") or "")))
    check("④b 新文件只有新行", countLines(readAll(PATH)) == 1, tostring(countLines(readAll(PATH))))
end

-- ---------------------------------------------------------------------------
-- ⑤ 写失败：不抛错、关追踪、说出来（trace 绝不许拖垮主流程 ✓）
-- ---------------------------------------------------------------------------
print("== ⑤ 写不进去 → 不抛错 + 关追踪 + 报一句 ==")
do
    Rpc.traceClose()
    Rpc.tracing = true
    io.open = function(path, mode)
        if tostring(path) == PATH then error("sandbox says no") end
        return realOpen(path, mode)
    end
    local okRun, err = pcall(function() Rpc.trace("must not throw") end)
    check("⑤ trace 不抛错", okRun, tostring(err))
    check("⑤ 失败后 tracing 关掉（不再反复撞墙 ✓）", Rpc.tracing == false, tostring(Rpc.tracing))
    check("⑤ 说出去了（CopilotNet.report 收到警告 ✓）", #REPORTS >= 1, tostring(#REPORTS))
    io.open = realOpen
end

-- 收尾
Rpc.traceClose()
os.remove(PATH)
os.remove(PATH .. ".1")
io.open = realOpen

print(string.format("\n%d checks, %d failures", checks, failures))
if failures == 0 then print("OK") end
os.exit(failures == 0 and 0 or 1)
