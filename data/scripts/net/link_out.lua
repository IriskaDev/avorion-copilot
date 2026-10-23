package.path = package.path .. ";data/scripts/lib/?.lua"
package.path = package.path .. ";data/scripts/?.lua"
-- CopilotLinkOut —— **游戏侧发起的那些事**（游戏调 DSH）。
--
-- 与 link_in.lua 正好对称 ✓：
--   link_in.lua   CopilotRpc.handle(...)  —— 我提供功能，等你来调
--   link_out.lua  CopilotRpc.call(...)    —— 我调你，等你的答复
--
-- 必须被 net.lua **include**（和泵同一个 VM ✓）。
--
-- 命名空间脚本：表不能清空
-- namespace CopilotLinkOut
CopilotLinkOut = CopilotLinkOut or {}

local self = CopilotLinkOut

self.stats = self.stats or { helloSent = 0, stateSent = 0, decideSent = 0 }

-- ★★ 2026-10-24：**state 自动推送 → 不接** ✗✓（协议 §10 第 9 条本来就是「默认关」✓）
--
--   病历：`autoState` / `stateInterval` 这两个开关**从来没有被任何代码打开过** ✗，
--   唯一读它们的 `maybePushState()` 也**从没进过 tick 泵**（全仓零调用 ✗✓）
--   → 一段永远不跑、却看起来像"有实时流"的死码 ✓。
--
--   现在：三个字段连同 `maybePushState` 一起删掉 ✓；
--   `pushState()` **仍在** —— 它是**一次性手动入口**（谁要推就显式调一次 ✓），
--   日常数据由 DSH 侧按需 `query` 拉，比推流干净 ✓。
self.lastStateAt = self.lastStateAt or 0     -- 最近一次手动推送的时刻（诊断用 ✓）

-- ---------------------------------------------------------------------------
-- 握手：连上就报身份 + **声明我能处理哪些 cmd** ✓（协议 §8：两端各发一次 ✓）
-- ---------------------------------------------------------------------------

function CopilotLinkOut.sendHello()
    -- 握手本身也是一次普通 RPC ✓ —— 它会拿到一个 id 相同的 hello 答复 ✓
    local ok, errOrId = CopilotRpc.call("hello", {
        ver = CopilotOut.VER,
        side = "game",
        caps = CopilotRpc.caps(),      -- ★ 我提供的能力（自我声明 ✓，对面不用猜 ✓）
    }, function(ok2, payload, why)
        if ok2 then
            CopilotNet.emit("hello_ok", payload)
        else
            CopilotNet.emit("error", "hello rejected: " .. tostring(why))
        end
    end, 10)

    if ok then
        self.stats.helloSent = self.stats.helloSent + 1
    else
        CopilotNet.emit("error", "hello send failed: " .. tostring(errOrId))
    end
    return ok, errOrId
end

-- ---------------------------------------------------------------------------
-- 主动推送舰队快照（可选 ✓）
-- ---------------------------------------------------------------------------

-- ★ 一次性手动入口：**没有自动调用方** ✓（旧的 `maybePushState()` 定时自动推已删 ✗✓）
function CopilotLinkOut.pushState()
    local player = Player()
    if player == nil then return false, "no player" end

    local Card = include("copilot/card")
    local snap = Card.fleetSnapshot(player)

    -- 推送也走 RPC ✓（§2 铁律 3：每个 request 都要有 response ✓）
    -- 回调留空 —— 我们只要那个 ack 确认，不处理它的内容 ✓
    local ok, err = CopilotRpc.call("state", snap, nil, 10)
    if ok then
        self.stats.stateSent = self.stats.stateSent + 1
        self.lastStateAt = os.clock()
    end
    return ok, err
end

-- ★ 2026-10-24：「由 tick 泵调用、只有 autoState 打开时才真的推」的 `maybePushState()`
--   **已删** ✗✓ —— 它从未被任何 tick 泵/代码调用（全仓零调用方 ✓），
--   连同 `autoState` / `stateInterval` 两个永不为真的开关一起退役 ✓。
--   要推就显式调 `pushState()` 一次 ✓（不再有"自动推"这条路 ✗）。

-- ---------------------------------------------------------------------------
-- ★ decide（协议 §11）：**游戏问 DSH 要决策** —— 双向设计的核心用法 ✓
-- ---------------------------------------------------------------------------

-- card    能力卡（Card.shipCard 的产物 ✓）
-- options 候选命令（由游戏侧生成 ✓ —— 于是答复一定落在合法命令集里 ✓✓）
-- callback(ok, data, why): ok 时 data = {action=..., params=...}
function CopilotLinkOut.askDecide(ship, card, options, callback)
    local ok, err = CopilotRpc.call("decide", {
        ship = ship,
        card = card,
        options = options,
    }, callback, 30)     -- ★ 等模型，超时给足 ✓（协议 §11：绝不许阻塞主循环 ✓）

    if ok then
        self.stats.decideSent = self.stats.decideSent + 1
    else
        CopilotNet.emit("error", "decide send failed: " .. tostring(err))
    end
    return ok, err
end

-- ---------------------------------------------------------------------------
-- ping：确认链路（也是 §6 的心跳手段 ✓）
-- ---------------------------------------------------------------------------

function CopilotLinkOut.ping(callback)
    return CopilotRpc.call("ping", { clock = os.clock() }, callback, 5)
end

-- ---------------------------------------------------------------------------
-- 安装
-- ---------------------------------------------------------------------------

function CopilotLinkOut.install()
    if self.installed then return end
    self.installed = true

    CopilotNet.on("connected", function()
        self.connectedAt = os.time()
        CopilotLinkOut.sendHello()
    end)

    CopilotNet.on("disconnected", function()
        self.connectedAt = nil
        self.lastStateAt = 0
    end)
end

function CopilotLinkOut.status()
    return "out: hello=" .. tostring(self.stats.helloSent)
        .. " state=" .. tostring(self.stats.stateSent)
        .. " decide=" .. tostring(self.stats.decideSent)
        .. " statePush=manual"          -- ★ 自动推已退役（见文件上方 ✓）
end

return CopilotLinkOut
