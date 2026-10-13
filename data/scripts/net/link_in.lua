package.path = package.path .. ";data/scripts/lib/?.lua"
package.path = package.path .. ";data/scripts/?.lua"
-- CopilotLinkIn —— **游戏侧提供的能力**（对面可以调我什么）。
--
-- 本质（主人点透的那句）：**让 DSH 能调游戏的功能，游戏也能调 DSH 的功能。**
-- 所以本文件只做一件事：把「游戏能提供什么功能」注册进 RPC 框架 ✓
--
--   CopilotRpc.handle(cmd, fn)   →   fn(data) 返回 ok, payload, message
--
-- 信封、id、答复、超时全部由框架负责（见 net/rpc.lua ✓）。
-- 必须被 net.lua **include**（和泵同一个 VM ✓），否则注册不到同一条链上 ✗。
--
-- 命名空间脚本：表不能清空
-- namespace CopilotLinkIn
CopilotLinkIn = CopilotLinkIn or {}

local self = CopilotLinkIn

-- 对端在 hello 里声明的能力（DSH 能处理哪些 cmd ✓）
self.peerCaps = self.peerCaps or {}
self.peerSide = self.peerSide or nil

-- ---------------------------------------------------------------------------
-- 我提供的能力（对面调我）
-- ---------------------------------------------------------------------------

-- hello：握手。两边各收到对方一次 hello ✓
function CopilotLinkIn.onHello(data)
    data = data or {}
    self.peerSide = data.side
    self.peerCaps = data.caps or {}

    -- 协议 §7：版本不等时按最低版运行，不崩不断连 ✓
    if data.ver ~= CopilotOut.VER then
        CopilotNet.emit("error", "peer ver=" .. tostring(data.ver) .. " (mine " .. tostring(CopilotOut.VER) .. ")")
    end

    return true, { side = "game", ver = CopilotOut.VER, caps = CopilotRpc.caps() }
end

-- query：**这就是"眼睛"** ✓ —— DSH 靠它拿游戏事实，不需要截图 ✓✓
function CopilotLinkIn.onQuery(data)
    data = data or {}
    local what = data.what

    local player = Player()
    if player == nil then return false, "NO_PLAYER", "no player object" end

    local Card = include("copilotcard")     -- 与 ops.lua 共用同一份读取逻辑 ✓（跨 VM 的唯一办法 ✓）

    if what == "fleet" then
        return true, Card.fleetSnapshot(player)

    elseif what == "ship" then
        local name = data.ship
        if type(name) ~= "string" or name == "" then
            return false, "BAD_REQUEST", "query ship needs data.ship"
        end
        return true, Card.shipCard(player, name)

    elseif what == "caps" then
        -- 我支持哪些 what（**自我声明** ✓，DSH 不用猜 ✓）
        return true, { what = Card.WHATS }

    elseif what == "orderSchema" then
        -- ★ 协议 §10 第 8 条：形状**不定死**，返回**不透明表**给 DSH 透传。
        -- 但取参数的原版 API（getConfigurableValues）**本 agent 还没实测过** ✗，
        -- 所以这一版**诚实地报未实现** ✓ —— 而不是编一个假形状出来 ✗✓
        return false, "NOT_IMPLEMENTED",
            "orderSchema not wired yet (needs a verified getConfigurableValues probe)"

    else
        return false, "UNSUPPORTED", "unknown what: " .. tostring(what)
    end
end

-- order：DSH 让游戏下单。
-- ★ 真正下单必须走战略层 ops.lua，而那是**另一个 VM** ✗ —— 需要 player value 或
-- callable 中转 ✓。这是下一增量，现在诚实报未实现 ✓，绝不静默吞掉 ✗。
function CopilotLinkIn.onOrder(data)
    data = data or {}
    self.lastOrder = data
    return false, "NOT_IMPLEMENTED",
        "order routing to the ops layer is not wired yet (ship=" .. tostring(data.ship) .. ")"
end

-- decide（协议 §11）：按设计**由游戏侧发起** ✓（见 link_out.askDecide）。
-- 这里保留一个入口：DSH 若反过来问"要不要我现在给建议"，也走它 ✓。
function CopilotLinkIn.onDecide(data)
    return false, "NOT_IMPLEMENTED", "decide is initiated by the game side (see link_out)"
end

-- reload：热重载。
-- ★ 只能重载**本 VM 里**的文件（net/ 那一层 ✓）；player 脚本在别的 VM ✗。
function CopilotLinkIn.onReload(data)
    self.reloadRequested = true
    return false, "PARTIAL",
        "reload from this VM can only cover the net layer; player scripts need a restart"
end

-- ping：最便宜的往返，用来确认链路活着 ✓（§6：任何帧都要求 ack ✓）
function CopilotLinkIn.onPing(data)
    return true, { pong = true, clock = os.clock() }
end

-- ---------------------------------------------------------------------------
-- 安装：把自己注册进 RPC 框架 ✓
-- ---------------------------------------------------------------------------

function CopilotLinkIn.install()
    if self.installed then return end
    self.installed = true

    CopilotRpc.handle("hello",  CopilotLinkIn.onHello)
    CopilotRpc.handle("query",  CopilotLinkIn.onQuery)
    CopilotRpc.handle("order",  CopilotLinkIn.onOrder)
    CopilotRpc.handle("decide", CopilotLinkIn.onDecide)
    CopilotRpc.handle("reload", CopilotLinkIn.onReload)
    CopilotRpc.handle("ping",   CopilotLinkIn.onPing)
end

function CopilotLinkIn.status()
    return "in: peer=" .. tostring(self.peerSide)
        .. " peerCaps=[" .. table.concat(self.peerCaps or {}, ",") .. "]"
end

return CopilotLinkIn
