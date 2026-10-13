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

-- state 推送开关：协议 §10 第 9 条 —— **默认关** ✓（纯 query 按需拉更干净 ✓）。
-- DSH 想要实时流时，由上层把它打开即可 ✓。
self.autoState = self.autoState or false
self.stateInterval = self.stateInterval or 10     -- 秒
self.lastStateAt = self.lastStateAt or 0

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

function CopilotLinkOut.pushState()
    local player = Player()
    if player == nil then return false, "no player" end

    local Card = include("copilotcard")
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

-- 由 tick 泵调用：只有 autoState 打开时才真的推 ✓
function CopilotLinkOut.maybePushState()
    if not self.autoState then return end
    if os.clock() - self.lastStateAt < self.stateInterval then return end
    CopilotLinkOut.pushState()
end

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
        .. " autoState=" .. tostring(self.autoState)
end

return CopilotLinkOut
