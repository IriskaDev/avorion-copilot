package.path = package.path .. ";data/scripts/lib/?.lua"
package.path = package.path .. ";data/scripts/?.lua"
-- CopilotNet —— 对外链路的**传输层与事件源**。
--
-- 职责边界（很重要，别在这层写业务）：
--   * 只负责：连/断、把 DLL 收到的完整帧变成事件、把消息交出去
--   * **不解析业务**（那是 net/inbound.lua、net/outbound.lua 的事）
--   * **不处理业务**（那是 commands/ 下两个监听者的事）
--
-- 为什么是"tick 泵"而不是真异步：
--   Lua 这边没有真正的异步回调（引擎不会因为我们而回调）✗，
--   DLL 的 recv 又是非阻塞的 ✓，所以唯一形态是"每 tick 拉一次"。
--   对外仍然表现为事件：上层只管 CopilotNet.on(...)，不用关心轮询。
--
-- 命名空间脚本：表不能清空（否则 /copilot reload 会重载即失忆）
-- namespace CopilotNet
CopilotNet = CopilotNet or {}

local self = CopilotNet

-- 事件总线 -------------------------------------------------------------------

self.listeners = self.listeners or {}      -- [event] = { fn, ... }

function CopilotNet.on(event, fn)
    self.listeners[event] = self.listeners[event] or {}
    table.insert(self.listeners[event], fn)
end

-- 派发时逐个 pcall：一个监听者出错不能拖垮其他监听者，也不能中断本 tick
function CopilotNet.emit(event, payload)
    local list = self.listeners[event]
    if not list then return end
    for _, fn in ipairs(list) do
        local ok, err = pcall(fn, payload)
        if not ok then
            print("[copilot net] listener for '" .. tostring(event) .. "' failed: " .. tostring(err))
        end
    end
end

-- 配置 -----------------------------------------------------------------------

self.host = self.host or "127.0.0.1"
self.port = self.port or 8765

self.state = self.state or "idle"          -- idle / connecting / ready / dead
self.handlersReady = self.handlersReady or false

-- 连接 -----------------------------------------------------------------------

function CopilotNet.getModule()
    local ok, cp = pcall(require, "copilot")
    if ok and type(cp) == "table" then return cp end
    return nil
end

function CopilotNet.connect()
    local cp = CopilotNet.getModule()
    if cp == nil then
        CopilotNet.emit("error", "native module 'copilot' unavailable")
        return false
    end
    local ok, err = cp.connect(self.host, self.port)
    if not ok then
        CopilotNet.emit("error", "connect failed: " .. tostring(err))
        return false
    end
    self.state = "connecting"
    return true
end

function CopilotNet.isConnected()
    local cp = CopilotNet.getModule()
    if cp == nil then return false end
    return cp.connected() and true or false
end

-- ★ 懒加载耗时探针（2026-10-24 加 ✓✓ —— net.pump 打点用）
--   写法与 `net/fleet.lua` / `player/ai/ops.lua` **同一套** ✓：
--   失败一次就记住失败（值是 false ✓），别每一拍都重试 include ✗。
function CopilotNet.perfModule()
    if self._perf ~= nil then return self._perf or nil end
    local ok, mod = pcall(include, "copilot/perf")
    self._perf = (ok and type(mod) == "table") and mod or false
    return self._perf or nil
end

-- 发送：这里只做"交出去"，不决定发什么
function CopilotNet.send(text)
    local cp = CopilotNet.getModule()
    if cp == nil then return false, "no module" end
    return cp.send(text)
end

-- 事件泵 ---------------------------------------------------------------------

function CopilotNet.getUpdateInterval()
    return 1                                -- 每秒拉一次；决策是秒级场景，够用
end

-- ★★ 接收泵的**时间预算**（2026-10-24 修 ✓✓）
--
-- 病根（真机 `moddata/copilot/rpc_trace.log` 铁证 ✗）：一拍**最多 32 帧**，而且
-- **逐帧同步**跑 handler ——
--   01:35:54  dispatch type=request ... onQuery what=dossier
--   01:36:25  hb connected=...            ← 中间**一条日志都没有**，31 秒 ✗✓
-- 也就是：只要队里排着一个 tradePlan/dossier（21 秒级），这一拍就把
-- 心跳、RPC 超时扫描、两段式下单、空闲扫描**全部拖停** ✗✓（画面不卡、逻辑卡 ✓）。
--
-- 现在：一拍**最多处理 1~2 帧** ✓，且**每跑完一帧看表，超 ~30 ms 就停手** ✓✓。
-- ★ 不丢帧 ✓：帧不是「本函数取走再自己排队」，而是**留在 DLL 的接收队列里** ——
--   本拍少取两帧，下一拍 `recv()` 照样拿得到 ✓（所以不需要 Lua 侧游标 ✓）。
self.RECV_MAX_FRAMES = self.RECV_MAX_FRAMES or 2      -- ★ 每拍最多跑 1~2 帧 ✓
self.RECV_BUDGET_SEC = self.RECV_BUDGET_SEC or 0.03   -- ★ 每拍最多占用 ~30 ms ✓

-- 上一拍的实际用量（诊断 / 自检取证用 ✓；不是业务状态）
self.lastPump = self.lastPump or { frames = 0, ms = 0, hitBudget = false, hitCap = false }

function CopilotNet.updateServer()
    if not onServer() then return end

    local cp = CopilotNet.getModule()
    if cp == nil then return end

    local connected = cp.connected() and true or false

    -- 连接状态变化 → 事件（"connected" / "disconnected"）
    if connected and self.state ~= "ready" then
        self.state = "ready"
        CopilotNet.report("已连接 ✓ 开始发 hello")
        CopilotNet.emit("connected", nil)
    elseif not connected and self.state == "ready" then
        self.state = "dead"
        CopilotNet.report("连接断开 ✗ 将自动重连")
        if CopilotRpc ~= nil then CopilotRpc.reset() end   -- 待答复全部作废 ✓
        CopilotNet.emit("disconnected", nil)
    end

    if not connected then
        -- ★ BUG 修复：断开后必须**再连一次** ✗→✓
        -- 原先只在 initialize 里连一次，于是掉线后再也连不上（实测：对端第二次 hello 超时 ✗）。
        -- 协议 §6：重连是**本侧（DLL 侧）的职责** ✓ —— 每 5 秒试一次 ✓。
        local now = os.clock()
        if now - (self.lastConnectAt or 0) > 5 then
            self.lastConnectAt = now
            CopilotNet.connect()
        end
        return
    end
    self.lastConnectAt = nil

    -- 把 DLL 里已到的完整帧取出来，一条一条 emit 出去。
    -- ★ **有预算**：最多 RECV_MAX_FRAMES 帧，且跑完一帧就核账（超 ~30 ms 停手）✓✓
    --   停手 ≠ 丢帧：没取的帧**仍躺在 DLL 队列里**，下一拍接着取 ✓
    --   （旧写法 `for _ = 1, 32` 无预算 → 队里有长 handler 就整拍拖停 ✗）
    local t0 = os.clock()
    local frames = 0
    local hitBudget, hitCap = false, false
    for _ = 1, self.RECV_MAX_FRAMES do
        local text = nil
        if not CopilotNet.SKIP_RECV then text = cp.recv() end   -- ★ 二分：跳过 recv ✓
        if text == nil then break end
        frames = frames + 1
        CopilotRpc.trace("收到一帧 " .. tostring(#text) .. " 字节")
        CopilotNet.emit("message", text)    -- 原始文本；解析交给 inbound
        if os.clock() - t0 >= self.RECV_BUDGET_SEC then
            hitBudget = true
            break                           -- ★ 本拍超预算 → 剩下的留到下一拍 ✓
        end
        if frames >= self.RECV_MAX_FRAMES then hitCap = true end
    end
    local pumpMs = (os.clock() - t0) * 1000
    self.lastPump = { frames = frames, ms = pumpMs, hitBudget = hitBudget, hitCap = hitCap }
    if hitBudget then
        -- ★ 只在**真超预算**时留痕：这是排查「心跳为什么变慢/变快」的锚点 ✓
        CopilotRpc.trace(string.format("泵：本拍 %d 帧 / %.1f ms 超预算 → 若队里还有帧，下一拍继续 ✓",
            frames, pumpMs))
    end

    -- ★★ 2026-10-24：**周期任务探针**（net.pump ✓✓）—— 与 `ops.updateServer` / `fleet.scan`
    --   同一套规矩 ✓：超阈值才写、每个名字 30 秒最多一行 ✓（见 lib/copilot/perf.lua ✓）。
    --   一拍最多 1~2 帧 + ~30 ms 预算 ✓ → 正常远低于 20 ms 阈值，平时一条都不写 ✓。
    do
        local Perf = CopilotNet.perfModule()
        if Perf ~= nil then
            Perf.log("net.pump", t0, string.format("frames=%d", frames))
        end
    end

    -- ★ 扫 RPC 超时（Lua 没有定时器 → 由这个 tick 泵驱动 ✓，和 recv 同一个 1 Hz 节拍）
    if CopilotRpc ~= nil then
        CopilotRpc.tick()
    end

    -- ★ 下单第二阶段：到点的 startCommand 发出去 ✓（两段式异步 ✓）
    if CopilotLinkIn ~= nil then
        CopilotLinkIn.tickOrders()
    end

    -- ★ 空闲扫描：名单里有目标的船一空闲就发起 decide ✓（自己控节奏 ✓）
    if CopilotFleet ~= nil then
        CopilotFleet.maybeScan()
    end

    -- ★★ 排查心跳（2026-10-15）：每 5 秒落一条，**泵一停日志立刻断** ✓
    -- 起因：游戏进程活着、画面正常、socket 也 Established，但 Lua 不再被 tick ✗——
    -- 需要知道它**断在哪一秒**、断之前名单有几艘 ✓
    if os.clock() - (self.lastHb or 0) > 5 then
        self.lastHb = os.clock()
        local roster = 0
        local pl = Player()
        if pl ~= nil then
            for _ in tostring(pl:getValue("copilot_auto_ships") or ""):gmatch("[^\n]+") do
                roster = roster + 1
            end
        end
        CopilotRpc.trace("hb connected=" .. tostring(connected) .. " roster=" .. roster)
    end
end

-- ★ 状态汇报：走 chat，因为 chat **一定**进客户端日志 ✓（已实测 ✓），
-- 而 io.open 写文件可能被静默拦掉 ✗ —— 排查期间必须用看得见的通道 ✓。
function CopilotNet.report(text)
    local ok = pcall(function()
        local p = Player()
        if p ~= nil then
            p:sendChatMessage("Server", ChatMessageType.Information, "[net] " .. text)
        end
    end)
    return ok
end

function CopilotNet.initialize()
    if self.handlersReady then return end
    self.handlersReady = true

    -- 把整条链装进**同一个 VM**：解析层与监听者都必须和泵在一起，
    -- 否则它们注册到的事件总线不是同一条，事件永远不会到监听者手里。
    self.rpc = include("net/rpc")            -- ★ 对称 RPC 框架（我先 include，inbound 才能用）
    self.inbound = include("net/inbound")
    self.outbound = include("net/outbound")
    self.linkOut = include("net/link_out")
    self.linkIn = include("net/link_in")
    self.fleet = include("net/fleet")          -- ★ 空闲扫描 + 自动发起 decide ✓

    self.inbound.install()          -- 自己挂到 net 上：net 一有消息就解包并转发
    self.linkOut.install()          -- game -> DSH
    self.linkIn.install()           -- DSH -> game

    CopilotNet.report("initialize：即将连接 127.0.0.1:" .. tostring(self.port))
    local okc = CopilotNet.connect()
    CopilotNet.report("connect() 返回 " .. tostring(okc) .. "  state=" .. tostring(self.state))
end

return CopilotNet
