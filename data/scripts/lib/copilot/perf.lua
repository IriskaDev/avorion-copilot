package.path = package.path .. ";data/scripts/lib/?.lua"
package.path = package.path .. ";data/scripts/?.lua"
-- copilotperf —— **周期任务的耗时探针**（2026-10-22 加 ✓✓）
--
-- 为什么要有它 ✗→✓：
--   主人报的现象是「画面不卡，但有一种超高延迟的感觉」✓ —— 这是**服务端模拟掉帧**
--   的典型形态 ✓。它**不在** clientlog 里（那边零 Lua 报错 ✓）、也不在帧计数器里 ✓，
--   唯一能看见它的地方就是「我们自己的周期函数跑了多久」✓✓
--
-- 设计取舍（每一条都是为了**别让排查本身变成负载** ✗✓）：
--   · **只在超过阈值时写** ✗ —— 正常这台机器上这些函数是亚毫秒级，平时一条都不写 ✓
--   · 阈值 **20 ms**（周期任务：一次吃掉 20 ms 主线程 = 掉 ≥1 帧，够说明问题了 ✓）；
--     RPC handler 用 **100 ms**（`QUERY_THRESHOLD_MS` ✓ —— 规矩见 interface-atomicity.md G4 ✓）
--   · **每个名字每 30 秒最多写一条** ✓ —— 哪怕一直超阈值，也不会把日志自己刷成风暴 ✓
--     （★ 2026-10-24 从「整个 VM 一条」改成「每个名字一条」✗→✓：否则一个慢查询会把
--      fleet.scan / net.pump 的记录挤掉 ✗；名字数有界 → 仍然不刷屏 ✓）
--   · 全程 pcall ✓ —— 探针写失败绝不影响主流程 ✓（与 net/rpc.lua 的 trace 同一套规矩 ✓）
--   · 写完就 close ✓ —— 与 rpc.lua 一样（游戏侧 io.open 只允许 moddata/ 开头 ✓）
--
-- 打点覆盖面（★ 2026-10-24 补齐 ✓✓）：
--   `ops.updateServer`（player/ai/ops.lua ✓）/ `fleet.scan`（net/fleet.lua ✓）/
--   `net.pump`（net/net.lua ✓）/ `rpc.query:<what>`、`rpc.<cmd>`（net/rpc.lua ✓）
--
-- 输出：`moddata/copilot/perf.log`（在 %APPDATA%\Avorion\moddata\copilot\ 下 ✓）
--   `20:31:07  ops.updateServer          23.4 ms  ships=6`
--
-- ★ 本文件是 lib：只 return 命名空间表，**不许**定义全局生命周期回调 ✓
-- ★ 状态（lastAt）是**每个 include 它的 VM 各一份** ✓ —— 排查服务端掉帧时这足够了 ✓
--   （ops.lua 与 net/fleet.lua 在不同 VM 里，各自节流、各自 append 同一个文件 ✓）

local M = {}

-- 超过多少毫秒才记一笔 ✓（周期任务）
M.THRESHOLD_MS = 20

-- ★ RPC handler 的阈值（2026-10-24 加 ✓✓）：单次 RPC > 100 ms 就必须留一行 ✓
--   规矩：docs/dev/interface-atomicity.md §★★★ 性能硬闸 G4 ✓
M.QUERY_THRESHOLD_MS = 100

-- 两次记录之间的最小间隔（秒）✓
M.MIN_INTERVAL = 30

M.LOG_PATH = "moddata/copilot/perf.log"

-- ★ 节流按**名字**各记一份（2026-10-24 改 ✓✓ —— 旧版是整个 VM 共用一个时间戳 ✗）
local lastWriteAt = {}
local written = 0

-- 返回本次耗时（毫秒，**不管有没有写日志** ✓ —— 调用方可以自己用）
-- startedAt 是调用方在进入被测代码前取的 os.clock() ✓
-- ★ thresholdMs 可选：不传 = 周期任务阈值（`THRESHOLD_MS` 20 ms ✓）；
--   RPC 传 `QUERY_THRESHOLD_MS`（100 ms ✓）—— 阈值可调，规矩不变 ✓
function M.log(name, startedAt, detail, thresholdMs)
    local elapsed = (os.clock() - startedAt) * 1000
    local threshold = thresholdMs or M.THRESHOLD_MS
    if elapsed < threshold then return elapsed end

    local key = tostring(name)
    local now = os.clock()
    local last = lastWriteAt[key]
    if last ~= nil and (now - last) < M.MIN_INTERVAL then return elapsed end
    lastWriteAt[key] = now

    pcall(function()
        local fh = io.open(M.LOG_PATH, "a")
        if fh == nil then return end
        fh:write(string.format("%s  %-22s %8.1f ms  %s\n",
            os.date("%H:%M:%S"), tostring(name), elapsed, tostring(detail or "")))
        fh:close()
        written = written + 1
    end)

    return elapsed
end

-- 诊断用：这一份 VM 里记过几条 ✓
function M.count()
    return written
end

-- 让一个函数被计时：返回包装函数（同名、**同返回值** ✓）
--
-- ★ 只在"整段函数"计时时用它 ✓；函数内部的返回点不受影响 ✓（不必在每个 return 前后加一行 ✗）
-- ★★ 2026-10-22：这里踩过一次 —— 只取 `local ok, err = pcall(fn, ...)` 会把
--    **被调函数的返回值全丢掉** ✗（自检当场抓到：`wrap(sum)(2,3)` 返回 nil ✗→✓）。
--    所以用表接住 pcall 的**全部**返回值，再原样 `unpack` 出去 ✓✓
function M.wrap(name, fn)
    return function(...)
        local t0 = os.clock()
        local results = { pcall(fn, ...) }
        M.log(name, t0)
        if not results[1] then error(results[2], 0) end        -- ★ 重新抛出：绝不静默吞错 ✓
        return table.unpack(results, 2, #results)
    end
end

return M
