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
    CopilotRpc.trace("onQuery what=" .. tostring(data and data.what))
    data = data or {}
    local what = data.what

    local player = Player()
    if player == nil then return false, "NO_PLAYER", "no player object" end

    CopilotRpc.trace("  include copilotcard…")
    local Card = include("copilotcard")     -- 与 ops.lua 共用同一份读取逻辑 ✓（跨 VM 的唯一办法 ✓）
    CopilotRpc.trace("  copilotcard 就绪，开始读舰队…")

    if what == "fleet" then
        CopilotRpc.trace("  调 fleetSnapshot…")
        local snap = Card.fleetSnapshot(player)
        CopilotRpc.trace("  fleetSnapshot 返回，船数=" .. tostring(#(snap.ships or {})))
        return true, snap

    elseif what == "ship" then
        local name = data.ship
        if type(name) ~= "string" or name == "" then
            return false, "BAD_REQUEST", "query ship needs data.ship"
        end
        return true, Card.shipCard(player, name)

    elseif what == "tradePlan" then
        -- ★★★ 贸易决策的**数据获取 + 组装**（只算不下单 ✓ —— 主人 2026-10-16 指定 ✓）
        --
        -- 走的路线（全部由本 mod 自己完成 ✓，不需要原版开洞 ✗✓）：
        --   ① include("areaanalysis") → run(…) **同步**返回 results（含 results.routes ✓✓）
        --   ② include("commandfactory") → makeCommand(Trade) → calculatePrediction(…, config) ✓
        --   ③ lib/copilottrade.lua 的纯函数 → 挑路线 + 定预付金 + 挑护卫 ✓
        --
        -- 为什么可行 ✗✓：areaanalysis.run 的末尾是
        --     return shipName, type, area, results, callingPlayer
        --   —— 它把结果交出来了 ✓✓（见该文件 line 138 ✓）
        -- ⚠️ 这里**不要**放任何顶层可执行语句 ✗（2026-10-16 实测 ✓）：
--   `/copilot reload` 是用**命令脚本那个 VM 的 _ENV** 去 load 本文件的 ✗，
--   而那个 VM 里没有 CopilotRpc → 顶层语句一执行就
--   "attempt to index global 'CopilotRpc' (a nil value)" ✗✓✓。
--   （也就是说：**net 链的改动热重载不了，必须重启游戏** ✓ —— 见 AGENTS.md ✓）
return CopilotLinkIn.tradePlan(player, data)

    elseif what == "goal" then
        local name = data.ship
        if type(name) ~= "string" or name == "" then
            return false, "BAD_REQUEST", "query goal needs data.ship"
        end
        local Goal = include("copilotgoal")
        return true, Goal.describe(player, name)

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

-- order：DSH 让游戏下单 —— **真正下单**（两段式异步 ✓）。
--
-- 原版流程（mapcommands.lua ✓）：
--   ① startAreaAnalysis(shipName, type, area)   ← 异步分析，游戏内部记下结果 ✓
--   ② 分析完成后 startCommand(shipName, type, config)   ← 真正开始后台命令 ✓
--
-- 本实现用 tick 泵排队完成第 ② 步（Lua 没有定时器 ✓）。
--
-- 硬约束（原版 startAreaAnalysis 内部检查 ✓，写错了只会被静默拒绝 ✗）：
--   * 船必须 `Available`（忙的船会被拒 ✓）
--   * Mine/Salvage/Trade 要求船**已经在目标区域内** ✓
--   * area 用**普通 table**（lower/upper ✓）—— 跨 VM 传参必须可序列化 ✓
--
-- 没写 area 时：以船当前所在星区为中心，按命令允许的最大尺寸自动取一个方块 ✓。

-- 命令类型（取自原版 commandtype.lua 的 UUID ✓ —— 千万不要改 ✗）
local COMMAND_TYPES = {
    Mine    = "c367bdbc-15c1-4aac-b691-cf92b6c541a0",
    Salvage = "1cbc94e6-aea3-4d1f-8159-d9e27d6b5d92",
    Trade   = "0c21be5b-d6a9-47ca-a1b3-200b11d2af4b",
    Travel  = "bbcf8ba1-a1e0-4a34-8174-15caebd11fed",
}

-- 各命令的默认区域边长（与 LLM-OPS.md 的调研一致 ✓）
local DEFAULT_SIZE = { Mine = 15, Salvage = 15, Trade = 29, Travel = 1 }

-- 排队中的第二阶段：{ {at=时刻, ...}, ... }
CopilotLinkIn.pendingOrders = CopilotLinkIn.pendingOrders or {}

local function simulationPath()
    return "data/scripts/player/background/simulation/simulation.lua"
end

-- 调玩家自己的 simulation 脚本（它上面有 callable ✓）
local function invokeSimulation(fn, ...)
    -- ⚠️ Lua 5.2：`...` 不能用在**非 vararg 的内层闭包**里 ✗
    --    （实测报 "cannot use '...' outside a vararg function" ✓）→ 先收进表 ✓
    local args = { ... }
    local player = Player()
    if player == nil then return false, "no player" end
    local ok, err = pcall(function()
        player:invokeFunction(simulationPath(), fn, table.unpack(args, 1, #args))
    end)
    if not ok then return false, tostring(err) end
    return true
end

function CopilotLinkIn.onOrder(data)
    data = data or {}
    local ship = data.ship
    local action = data.action

    if type(ship) ~= "string" or ship == "" then
        return false, "BAD_REQUEST", "order needs data.ship"
    end
    if type(action) ~= "string" or action == "" then
        return false, "BAD_REQUEST", "order needs data.action"
    end

    local ctype = COMMAND_TYPES[action]
    if ctype == nil then
        return false, "UNKNOWN_ACTION",
            "known actions: Mine, Salvage, Trade, Travel (got '" .. tostring(action) .. "')"
    end

    local player = Player()
    if player == nil then return false, "NO_PLAYER", "no player object" end

    -- 船可用吗（忙的船必然被原版拒绝 ✓ —— 这里先给个清楚的错误 ✓）
    local okAvail, avail = pcall(function() return player:getShipAvailability(ship) end)
    if okAvail and avail ~= nil and avail ~= ShipAvailability.Available then
        return false, "SHIP_NOT_AVAILABLE",
            "ship is not available (probably busy with another command)"
    end

    -- 组 area ✓（未指定则以船当前星区为中心，按默认尺寸取方块 ✓）
    local size = tonumber(data.size) or DEFAULT_SIZE[action] or 15
    local cx, cy = tonumber(data.x), tonumber(data.y)
    if cx == nil or cy == nil then
        local okPos, px, py = pcall(function() return player:getShipPosition(ship) end)
        if not okPos or px == nil then
            return false, "NO_POSITION", "cannot read ship position; pass x,y explicitly"
        end
        cx, cy = px, py
    end

    local half = math.floor((size - 1) / 2)
    local area = {
        lower = { x = cx - half, y = cy - half },
        upper = { x = cx - half + size - 1, y = cy - half + size - 1 },
    }

    -- ① 异步分析
    local ok1, err1 = invokeSimulation("startAreaAnalysis", ship, ctype, area)
    if not ok1 then
        return false, "ANALYSIS_FAILED", tostring(err1)
    end

    self.lastOrder = data
    self.orders = (self.orders or 0) + 1

    -- ② 排队第二阶段（等分析落地 ✓ —— 给 6 秒）
    local config = {
        duration = tonumber(data.duration) or 1,
        safeMode = data.safeMode == true,
        immediateDelivery = data.immediateDelivery == true,
    }
    table.insert(CopilotLinkIn.pendingOrders, {
        at = os.clock() + 6,
        ship = ship,
        ctype = ctype,
        action = action,
        config = config,
    })

    CopilotRpc.trace(string.format(
        "onOrder 真下单：%s action=%s area=[%d,%d]-[%d,%d] duration=%s（分析已发起，6 秒后下令 ✓）",
        ship, action, area.lower.x, area.lower.y, area.upper.x, area.upper.y, tostring(config.duration)))

    return true, {
        accepted = true,
        executed = true,
        ship = ship,
        action = action,
        area = area,
        config = config,
        note = "area analysis started; startCommand is queued ~6s later",
        count = self.orders,
    }
end

-- ===========================================================================
-- tradePlan：把"贸易该怎么做"完整算出来（**不发起** ✓）
-- ===========================================================================
--
-- 返回给 DSH 的结构 ✓：
--   { plan = { config = {...}, reason = "..." }, candidates = {...}, analysis = {...} }
-- 失败则 ok=false + 明确原因 ✓。

local function makeTradeArea(ship, data)
    local size = tonumber(data.size) or 17          -- 原版 Trade 的合法边长 17 / 29 / 11 ✓
    local cx, cy = tonumber(data.x), tonumber(data.y)
    if cx == nil or cy == nil then
        local okPos, px, py = pcall(function() return Player():getShipPosition(ship) end)
        if not okPos or px == nil then return nil, "cannot read ship position; pass x,y" end
        cx, cy = px, py
    end
    local half = math.floor((size - 1) / 2)
    return {
        lower = { x = cx - half, y = cy - half },
        upper = { x = cx - half + size - 1, y = cy - half + size - 1 },
    }
end

function CopilotLinkIn.tradePlan(player, data)
    local ship = data.ship
    if type(ship) ~= "string" or ship == "" then
        return false, "BAD_REQUEST", "tradePlan needs data.ship"
    end
    local action = data.action or "Trade"
    local ctype = COMMAND_TYPES[action]
    if ctype == nil then
        return false, "BAD_ACTION", "tradePlan only supports trade actions (got " .. tostring(action) .. ")"
    end
    if player == nil then return false, "NO_PLAYER", "no player object" end

    local area, aerr = makeTradeArea(ship, data)
    if area == nil then return false, "BAD_AREA", aerr end

    -- ★ ① 自己跑区域分析（**同步** ✓ —— run 直接返回 results ✓）
    --
    -- ⚠️ 坑：`areaanalysis.lua` 是**引擎脚本**，不是 lib ✗✓
    --   → 文件末尾**没有 return** ✗（它的 `run` 是**全局函数** ✓，是给 asyncf 调的 ✓）
    --   → 所以 `include("areaanalysis")` 返回 **nil** ✗
    --     （实测报 "attempt to index upvalue 'AreaAnalysis' (a nil value)" ✓）
    --   正确做法：include 一下把文件**执行掉**（定义全局 run ✓），然后**直接调全局 run** ✓✓。
    local okInc, incErr = pcall(function() return include("areaanalysis") end)
    if not okInc then return false, "NO_ANALYSIS_SCRIPT", tostring(incErr) end
    if type(run) ~= "function" then
        return false, "NO_ANALYSIS_RUN", "areaanalysis.lua did not define a global run()"
    end

    local okRun, r1, r2, r3, results, r5 = pcall(function()
        return run(player.index, ship, ctype, area, player.index)
    end)
    if not okRun then
        return false, "ANALYSIS_FAILED", tostring(r1)
    end
    -- run 的返回值: shipName, type, area, results, callingPlayer ✓
    results = results or r2                       -- 容错：万一签名不同 ✓
    local analysedArea = r2 or area
    if type(results) ~= "table" then
        return false, "ANALYSIS_EMPTY", "area analysis returned nothing for " .. ship
    end

    local routes = results.routes or {}
    if #routes == 0 then
        return true, {
            ship = ship, area = analysedArea, routes = {},
            plan = nil,
            note = "no trade routes in this area — a different area may have some",
            analysis = {
                sectors = results.sectors, reachable = results.reachable,
                unreachable = results.unreachable,
                biggestFactionInArea = results.biggestFactionInArea,
            },
        }
    end

    -- ★ ② 给每条候选补**基准价**（原版按 profitPerSize 排 ✓，本鱼要算绝对 C/u ✓）
    local okGoods, goodsLib = pcall(function() return include("goods") end)
    if okGoods and type(goodsLib) == "table" then
        for _, r in ipairs(routes) do
            local okG, g = pcall(function() return goodsLib[r.name]:good() end)
            if okG and type(g) == "table" and tonumber(g.price) then
                r.basePrice = tonumber(g.price)
                if tonumber(g.size) then r.unitSize = tonumber(g.size) end
            end
        end
    end

    -- ★ ③ 造一个 TradeCommand 实例，用它算每条路线的**真实预测** ✓✓
    local okF, factoryOrErr = pcall(function() return include("commandfactory") end)
    if not okF then return false, "NO_COMMAND_FACTORY", tostring(factoryOrErr) end
    local okCmd, command = pcall(function() return factoryOrErr.makeCommand(ctype) end)
    if not okCmd or command == nil then
        return false, "NO_COMMAND", tostring(command)
    end

    local predictions = {}
    local candidates = {}
    for _, r in ipairs(routes) do
        local cfg = { goodName = r.name, deposit = tonumber(data.depositProbe) or 1000000, escorts = {} }
        local okP, pred = pcall(function()
            return command:calculatePrediction(player.index, ship, analysedArea, cfg)
        end)
        if okP and type(pred) == "table" then
            predictions[r.name] = pred
            candidates[#candidates + 1] = {
                name = r.name,
                lowest = r.lowest, highest = r.highest, basePrice = r.basePrice,
                unitProfit = (r.basePrice and r.basePrice * ((r.highest or 0) - (r.lowest or 0))) or nil,
                attackChance = pred.attackChance and pred.attackChance.value or nil,
                profitPerFlight = pred.profitPerFlight,
                flights = pred.flights,
                flightTime = pred.flightTime and pred.flightTime.value or nil,
                maxAvailable = pred.maxAvailable and pred.maxAvailable.value or nil,
                error = pred.error,
            }
        else
            candidates[#candidates + 1] = { name = r.name, predictionFailed = tostring(pred) }
        end
    end

    -- ★ ④ 纯函数决策（lib/copilottrade.lua ✓ —— 有离线自检 ✓✓）
    local Trade = include("copilottrade")
    local facts = {
        shipSector = { x = analysedArea.lower.x, y = analysedArea.lower.y },
        actionShip = ship,
        predictions = predictions,
        escorts = data.escorts or {},
        budget = data.budget,
        maxDeposit = data.maxDeposit,
    }
    local plan, perr = Trade.plan(routes, facts, {
        maxAttackChance = tonumber(data.maxAttackChance) or Trade.MAX_ATTACK_CHANCE,
    })

    CopilotRpc.trace(string.format(
        "tradePlan %s area=[%d,%d]-[%d,%d] routes=%d plan=%s",
        ship, analysedArea.lower.x, analysedArea.lower.y, analysedArea.upper.x, analysedArea.upper.y,
        #routes, plan and plan.config.goodName or ("none(" .. tostring(perr) .. ")")))

    -- ★★★ 只**组装**，不发起 ✓✓（主人 2026-10-16 指定 ✓）
    return true, {
        ship = ship,
        area = analysedArea,
        routeCount = #routes,
        candidates = candidates,
        plan = plan,                       -- 含 config + reason ✓；nil 表示本轮不建议下单 ✓
        planError = perr,
        note = "plan only — nothing was issued (order is a separate call)",
        analysis = {
            sectors = results.sectors, reachable = results.reachable,
            unreachable = results.unreachable,
            biggestFactionInArea = results.biggestFactionInArea,
        },
    }
end

-- 由 tick 泵驱动：把到点的第二阶段发出去 ✓
function CopilotLinkIn.tickOrders()
    if #CopilotLinkIn.pendingOrders == 0 then return end
    local now = os.clock()
    local i = 1
    while i <= #CopilotLinkIn.pendingOrders do
        local job = CopilotLinkIn.pendingOrders[i]
        if now >= job.at then
            table.remove(CopilotLinkIn.pendingOrders, i)
            local ok, err = invokeSimulation("startCommand", job.ship, job.ctype, job.config)
            CopilotRpc.trace(string.format("onOrder 第二阶段 startCommand %s -> ok=%s %s",
                job.ship, tostring(ok), ok and "" or tostring(err)))
        else
            i = i + 1
        end
    end
end

-- setGoal：DSH 设定/清除某船的运营目标（真实现 ✓，用 lib/copilotgoal）
function CopilotLinkIn.onSetGoal(data)
    data = data or {}
    local ship = data.ship
    if type(ship) ~= "string" or ship == "" then
        return false, "BAD_REQUEST", "setGoal needs data.ship"
    end

    local player = Player()
    if player == nil then return false, "NO_PLAYER", "no player object" end

    local Goal = include("copilotgoal")

    if data.clear == true then
        Goal.clear(player, ship)
        CopilotRpc.trace("setGoal CLEAR ship=" .. ship)
        return true, { ship = ship, cleared = true }
    end

    if data.text ~= nil then Goal.setText(player, ship, data.text) end
    if data.options ~= nil then Goal.setOptions(player, ship, data.options) end

    local d = Goal.describe(player, ship)
    CopilotRpc.trace(string.format("setGoal ship=%s text=[%s] options=%d", ship, d.text, #d.options))
    return true, d
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

-- ★★★ 注册必须走**间接调用**（2026-10-16 实测的坑 ✓✓）
--
-- 原来写的是 `CopilotRpc.handle("query", CopilotLinkIn.onQuery)` ✗
--   —— 那抓的是**函数对象**（函数指针 ✗）。
--   于是 `/copilot reload link_in` 重执行本文件后，**新函数定义好了 ✓，
--   但派发表里还是旧指针 ✗** → 新加的 what=tradePlan 分支根本不会被调用 ✗✓。
--   （实测现象：DSH 发 query{tradePlan} → 游戏回 "unknown what: tradePlan" ✓）
--
-- 这正好违背本仓库的既有教训（AGENTS.md）✗：
--   「引擎是按名字查表调用，不是抓函数指针」—— 重载靠的就是这一条 ✓。
--   守卫（installed）让 install 只跑一次 ✓，所以旧指针会一直留着 ✗。
--
-- 修法：包一层，**每次调用时现场查表** ✓✓ —— 这样重载立即生效，无需重启游戏 ✓✓。
local function bind(name)
    return function(data)
        local fn = CopilotLinkIn[name]
        if type(fn) ~= "function" then
            return false, "NO_HANDLER", "handler '" .. name .. "' is missing"
        end
        return fn(data)
    end
end

-- ★★ 不带"只跑一次"的守卫 ✗→✓：
--   旧版有 `if self.installed then return end` ✗ —— 那让**重载后新的 bind 注册永远跑不到** ✗✓，
--   派发表里就一直留着最初那批指针 ✗（实测：改完 bind 后重载一次仍报 unknown what ✓）。
--   而 `handle(cmd, fn)` 是**覆盖**语义 ✓，重复注册无害 ✓ → 所以每次重载都重新注册 ✓✓。
function CopilotLinkIn.install()
    self.installed = true

    CopilotRpc.handle("hello",   bind("onHello"))
    CopilotRpc.handle("query",   bind("onQuery"))
    CopilotRpc.handle("order",   bind("onOrder"))
    CopilotRpc.handle("setGoal", bind("onSetGoal"))
    CopilotRpc.handle("decide",  bind("onDecide"))
    CopilotRpc.handle("reload",  bind("onReload"))
    CopilotRpc.handle("ping",    bind("onPing"))
end

function CopilotLinkIn.status()
    return "in: peer=" .. tostring(self.peerSide)
        .. " peerCaps=[" .. table.concat(self.peerCaps or {}, ",") .. "]"
end

-- ⚠️ 这里**不要**放任何顶层可执行语句 ✗（2026-10-16 实测 ✓）：
--   `/copilot reload` 是用**命令脚本那个 VM 的 _ENV** 去 load 本文件的 ✗，
--   而那个 VM 里没有 CopilotRpc → 顶层语句一执行就
--   "attempt to index global 'CopilotRpc' (a nil value)" ✗✓✓。
--   （也就是说：**net 链的改动热重载不了，必须重启游戏** ✓ —— 见 AGENTS.md ✓）
return CopilotLinkIn
