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
local DEFAULT_SIZE = { Mine = 15, Salvage = 15, Trade = 17, Travel = 1 }   -- ★ Trade 与 tradePlan 保持一致（29 会换一张商品表 ✗）

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

    -- ★★ 0) 先自己**同步**跑一遍分析 ✓✓（2026-10-16 实测的坑 ✓）
    --
    -- 起因：DSH 给的 goodName 可能属于**另一个区域** ✗ ——
    --   实测就是如此：tradePlan 用 17×17 拿到 "Antigrav Unit" ✓，
    --   而这里默认 29×29 → 商品表完全不同 ✗ →
    --   游戏回 **"No route selected."** ✓（tradecommand.lua:762 ✓）
    --
    -- `run` 是**同步**的（areaanalysis.lua 末尾直接 return ✓），所以这里能立刻
    -- 拿到本区域**真实存在**的路线表 ✓，用来校验并兜底 ✓✓。
    local routeNames = {}
    do
        local okInc = pcall(function() return include("areaanalysis") end)
        if okInc and type(run) == "function" then
            local okPre, _s, _ty, _ar, preResults = pcall(function()
                return run(player.index, ship, ctype, area, player.index)
            end)
            if okPre and type(preResults) == "table" and type(preResults.routes) == "table" then
                for _, r in ipairs(preResults.routes) do
                    if type(r) == "table" and type(r.name) == "string" then
                        routeNames[#routeNames + 1] = r.name
                    end
                end
            end
        end
    end
    CopilotRpc.trace(string.format("onOrder 预算：%s 在 [%d,%d]-[%d,%d] 里有 %d 条路线: %s",
        ship, area.lower.x, area.lower.y, area.upper.x, area.upper.y,
        #routeNames, table.concat(routeNames, ", ")))

    -- ① 异步分析
    local ok1, err1 = invokeSimulation("startAreaAnalysis", ship, ctype, area)
    if not ok1 then
        return false, "ANALYSIS_FAILED", tostring(err1)
    end

    self.lastOrder = data
    self.orders = (self.orders or 0) + 1

    -- ② 排队第二阶段（等分析落地 ✓ —— 给 6 秒）
    -- ★ tradecommand 只认这三个字段（源码核实 ✓）：
    --     config.goodName  = 选哪条贸易路线（routes 里的 name ✓）
    --     config.deposit   = 预付金（**必须 > 0**，否则 "Error starting command." ✓）
    --     config.escorts   = 护航舰艇（★ 必须与行动船同星系 ✓）
    local config = {
        duration = tonumber(data.duration) or 1,
        safeMode = data.safeMode == true,
        immediateDelivery = data.immediateDelivery == true,
    }
    -- ★★ 注意：**只有 Trade 才有"路线"** ✗✓（2026-10-16 实测）
    --   本鱼原先把这段校验放在**所有动作**上 ✗ → 下 Mine 时也被判
    --   "this area has no trade routes at all" ✓（Mine 的 routes 当然是空的 ✓）。
    --   所以整段用 `if ctype == COMMAND_TYPES.Trade then` 圈起来 ✓✓。

    -- ★ goodName 必须落在**本区域的**路线表里 ✓，否则**自动挑一条** ✓✓
    --   （原版把最好的排在最前 ✓ —— 它按 profitPerSize 排序 ✓）
    if ctype == COMMAND_TYPES.Trade then
    local wantGood = (type(data.goodName) == "string" and data.goodName ~= "") and data.goodName or nil
    if wantGood ~= nil then
        local found = false
        for _, n in ipairs(routeNames) do
            if n == wantGood then found = true; break end
        end
        if found then
            config.goodName = wantGood
        else
            CopilotRpc.trace(string.format(
                "onOrder：goodName「%s」不在本区域路线里 → 自动改选 ✓", tostring(wantGood)))
            wantGood = nil
        end
    end
    if config.goodName == nil and #routeNames > 0 then
        config.goodName = routeNames[1]
    end
    if config.goodName == nil then
        return false, "NO_ROUTE", "this area has no trade routes at all — try another area"
    end
    end   -- ★ 结束"仅 Trade"的范围 ✓
    local dep = tonumber(data.deposit)
    if dep ~= nil and dep > 0 then
        config.deposit = math.floor(dep)
    else
        -- ★ 兜底：收不到预付金时**不能留 nil** ✗✓
        --   实测：config.deposit 为 nil 会让命令在
        --   "tradecommand.lua:797: attempt to perform arithmetic on field 'deposit'" 处炸掉 ✓，
        --   而且那是**静默失败**——船干脆不动 ✗。所以给一个"付得起"的默认值 ✓。
        local want = 1000000
        local okPay, canPay = pcall(function() return player:canPay(want) end)
        if okPay and canPay ~= true then
            for _, cand in ipairs({ 500000, 200000, 100000, 50000, 20000, 10000, 5000, 1000 }) do
                local ok2, can2 = pcall(function() return player:canPay(cand) end)
                if ok2 and can2 == true then want = cand; break end
            end
        end
        config.deposit = want
        CopilotRpc.trace("onOrder：未给预付金 → 兜底 " .. tostring(want))
    end
    if type(data.escorts) == "table" then config.escorts = data.escorts end

    -- ★ Mine/Salvage 还要一个 `collected` 表 ✗✓（2026-10-16 实测）
    --   源码：minecommand.lua:964 `if materialProperties.dps > 0 and config.collected[material - 1] then`
    --   缺了它 → "attempt to index field 'collected' (a nil value)" ✓，命令直接起不来 ✗。
    --   MaterialType 从 0 起，取够 16 个位置、全填 true（所有材料都收 ✓）。
    if ctype == COMMAND_TYPES.Mine or ctype == COMMAND_TYPES.Salvage then
        if type(config.collected) ~= "table" then
            local collected = {}
            for i = 0, 15 do collected[i] = true end
            config.collected = collected
        end
    end
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

-- ===========================================================================
-- ★★★ 决策总目标（主人 2026-10-17 钦定，**原文照抄**，后人不得丢失 ✓✓）
--
--    「应从**多区域**、**多商品**、**净收益**去决策，
--      应在尽可能**低的风险**下，获取尽可能**高**的利润。」
--
-- 落到代码上 = **三维搜索** ✓：
--   ① 区域 (area)        —— 多个候选方框，每个都**必须含船** ✓（原版硬约束 ✓）
--   ② 商品/路线 (route)  —— 每个区域最多 4 条（原版只给 4 条 ✓），条条都算预测 ✓
--   ③ 参数 (params)      —— 预付金（按**装满货舱**算 ✓）+ 护航（只给**过不了闸门**的
--      路线补算一次带护航的预测 ✓）
-- 排序口径 = **净收益** ✓：profitPerFlight.from × flights.to（保守 ✓，用它排）
--   与 profitPerFlight.to × flights.to（乐观 ✓，一起返回给人看 ✓）——
--   原版窗口那两列「利润/航班」×「航班」的乘积，就是这趟活赚到的钱 ✓。
-- 风险闸门 = attackChance ≤ maxAttackChance（默认 0.10 ✓）**是硬线** ✗：
--   一条都不达标时必须**明说**（riskWarning ✓），绝不偷偷挑一条高风险的 ✓。
-- 并列处理：净收益相差 ≤10% 时**风险低的优先** ✓（"尽可能低的风险" ✓）。
-- ===========================================================================

local SCAN_STEP = 4            -- 候选区域中心的偏移步长（星区 ✓）
local SCAN_MAX_AREAS = 9       -- 默认最多扫几个区域（3×3 ≈ 船可及范围 ✓）
local SCAN_BUDGET_MS = 20000   -- 默认时间预算 ms（RPC 有 120 秒，留足余量 ✓）
local SCAN_DETAIL = 4          -- 每个区域最多回传几条候选（控 RPC 载荷 ✓）
local NET_PROFIT_BAND = 0.10   -- 净收益差 ≤10% → 改比风险 ✓

-- 原版在 startCommand 时会**核对区域尺寸**（simulation.lua:528 ✓）：
--   尺寸不在 getAreaSize 列表里 → 直接拒绝 "Area size for X changed." ✗
-- 所以候选区域**只能用合法模板** ✓✓（Trade 的合法形状：17x17 / 29x11 / 11x29 ✓）。
-- ★ 本实现只用其中的**正方形** ✓ —— order 通道只接受 (x, y, size)（正方形 ✓），
--   非正方形区域下不回去 ✗（要改 onOrder 才支持，见本轮回复里的待办 ✓）。
local function legalAreaSizes(command, player, ship)
    local out = {}
    local ok, a, b, c = pcall(function() return command:getAreaSize(player.index, ship) end)
    if not ok then return out end
    for _, t in ipairs({ a, b, c }) do
        local tx = (type(t) == "table") and tonumber(t.x) or nil
        local ty = (type(t) == "table") and tonumber(t.y) or nil
        if tx ~= nil and ty ~= nil and tx > 0 and ty > 0 then
            out[#out + 1] = { x = math.floor(tx), y = math.floor(ty) }
        end
    end
    return out
end

-- 尺寸：没给 → 17（与原实现一致 ✓）；给了 → 合法就用 ✓；不合法 → 用原版第一个正方形 ✓；
-- 连合法尺寸都问不到 → 就照请求的来（note 里说明 ✓）。
local function pickSquareSize(templates, requested)
    local want = tonumber(requested)
    if want == nil then return 17 end
    for _, t in ipairs(templates) do
        if t.x == want and t.y == want then return want end
    end
    for _, t in ipairs(templates) do
        if t.x == t.y then return t.x end
    end
    return want
end

-- 与 vanilla 一致地夹进星系范围 ✓（areaanalysis.lua:36 `math.min(500, math.max(-499, x))` ✓）
local function clampCoord(v)
    return math.min(500, math.max(-499, v))
end

local function buildArea(cx, cy, size)
    local half = math.floor((size - 1) / 2)
    return {
        lower = { x = clampCoord(cx - half), y = clampCoord(cy - half) },
        upper = { x = clampCoord(cx - half + size - 1), y = clampCoord(cy - half + size - 1) },
    }
end

local function areaHasSector(area, sx, sy)
    return sx >= area.lower.x and sx <= area.upper.x and sy >= area.lower.y and sy <= area.upper.y
end

-- 候选偏移：{0, ±step, ±2step …}（两轴都封顶在 half ✓），按到中心的距离排序 →
-- **offset (0,0) 永远排第一** ✓（它必含船 → 保证至少扫到一个合法区域 ✓✓）
local function scanOffsets(half, step)
    local vals = { 0 }
    local d = step
    while d <= half do
        vals[#vals + 1] = d
        vals[#vals + 1] = -d
        d = d + step
    end
    local out = {}
    for _, dx in ipairs(vals) do
        for _, dy in ipairs(vals) do
            out[#out + 1] = { x = dx, y = dy }
        end
    end
    table.sort(out, function(a, b)
        local da, db = a.x * a.x + a.y * a.y, b.x * b.x + b.y * b.y
        if da == db then
            if a.y == b.y then return a.x < b.x end
            return a.y < b.y
        end
        return da < db
    end)
    return out
end

local function flightsOf(c)
    local f = c.flights
    if type(f) == "table" then return tonumber(f.to) end
    return tonumber(f)
end

-- 退化口径：profitPerSize（原版自己算的"每体积利润" ✓），再退到绝对毛利 ✓
local function fallbackMetric(c)
    local pps = tonumber(c.profitPerSize)
    if pps ~= nil then return pps end
    local up = tonumber(c.unitProfit)
    if up ~= nil then return up end
    return -1
end

-- ★ 净收益（主人钦定的口径 ✓）：profitPerFlight × flights ✓
--   返回 保守值, 乐观值, 口径名 ✓（缺预测 → 退回 profitPerSize 并**说明** ✓）
local function netProfit(c)
    local fl = flightsOf(c)
    local pf = c.profitPerFlight
    if type(pf) == "table" and fl ~= nil and fl > 0 then
        local low, high = tonumber(pf.from), tonumber(pf.to)
        if low ~= nil and high ~= nil then
            return low * fl, high * fl, "netProfit"
        end
    end
    local m = fallbackMetric(c)
    return m, m, "profitPerSize(fallback)"
end

local function basisRank(c)
    return (c.profitBasis == "netProfit") and 1 or 0
end

-- 风险：未知概率按**最差**参与排序（9 ✓）；但**闸门**对未知是放行的 ✓
-- （与 lib/copilottrade.lua 里 `chance == nil or chance <= maxChance` 一致 ✓✓）
local function chanceOf(c)
    local v = tonumber(c.attackChanceEffective)
    if v == nil then v = tonumber(c.attackChance) end
    if v == nil then return 9 end
    return v
end

-- 排序：先按**保守净收益**降序 ✓，再做一遍"10% 带宽内风险优先"的插入调整 ✓
--   ⚠️ 不能把"带宽比较器"直接喂 table.sort ✗ —— 那不是一致的大小关系，
--      会触发 "invalid order function for sorting" ✓（所以用插入调整 ✓）。
local function rankByNetProfit(list, gate)
    table.sort(list, function(a, b)
        local ba, bb = basisRank(a), basisRank(b)
        if ba ~= bb then return ba > bb end
        local na, nb = netProfit(a), netProfit(b)
        if na ~= nb then return na > nb end
        local ca, cb = chanceOf(a), chanceOf(b)
        if ca ~= cb then return ca < cb end
        return tostring(a.name) < tostring(b.name)
    end)
    for i = 2, #list do
        local j = i
        while j > 1 do
            local cur, prev = list[j], list[j - 1]
            if basisRank(cur) ~= basisRank(prev) then break end
            local np = netProfit(prev)
            local nc = netProfit(cur)
            if np <= 0 then break end
            if nc < np * (1 - NET_PROFIT_BAND) then break end
            if not (chanceOf(cur) < chanceOf(prev) - 1e-9) then break end
            if gate ~= nil and chanceOf(cur) > gate and chanceOf(prev) <= gate then
                break                       -- 别把"不达标"的顶到"达标"的前面 ✗
            end
            list[j], list[j - 1] = prev, cur
            j = j - 1
        end
    end
    return list
end

-- 区域排序 ✓：达标的在前 ✓；按该区域最优路线的**净收益**降序 ✓；带宽内风险优先 ✓
local function rankAreasByNet(recs)
    table.sort(recs, function(a, b)
        if a.acceptable ~= b.acceptable then return a.acceptable end
        local na, nb = tonumber(a.bestNetLow) or -1, tonumber(b.bestNetLow) or -1
        if na ~= nb then return na > nb end
        local ca, cb = tonumber(a.bestChance) or 9, tonumber(b.bestChance) or 9
        if ca ~= cb then return ca < cb end
        return tostring(a.bestRouteName) < tostring(b.bestRouteName)
    end)
    for i = 2, #recs do
        local j = i
        while j > 1 do
            local cur, prev = recs[j], recs[j - 1]
            if cur.acceptable ~= prev.acceptable then break end
            local np, nc = tonumber(prev.bestNetLow), tonumber(cur.bestNetLow)
            if np == nil or nc == nil or np <= 0 then break end
            if nc < np * (1 - NET_PROFIT_BAND) then break end
            local cc, pc = tonumber(cur.bestChance), tonumber(prev.bestChance)
            if cc == nil or pc == nil or not (cc < pc - 1e-9) then break end
            recs[j], recs[j - 1] = prev, cur
            j = j - 1
        end
    end
    return recs
end

-- 基准价 ✓（原版按 profitPerSize 排 ✓；本鱼还要算绝对 C/u ✓）
local function attachGoodsPrices(goodsLib, routes)
    if type(goodsLib) ~= "table" then return end
    for _, r in ipairs(routes) do
        local okG, g = pcall(function() return goodsLib[r.name]:good() end)
        if okG and type(g) == "table" and tonumber(g.price) then
            r.basePrice = tonumber(g.price)
            if tonumber(g.size) then r.unitSize = tonumber(g.size) end
        end
    end
end

-- ★ 参数维度①：预付金 —— 按"**装满货舱**"算 ✓✓（不是拍脑袋的 1e6 ✗）
--   依据：原版 profitPerFlight 直接取决于 config.deposit（tradecommand.lua:797 ✓），
--   而 attackChance 也随 deposit 上升（tradecommand.lua:849 那个 lerp ✓）
--   → 用**真要下的那个** deposit 去算预测，收益与风险两个口径才自洽 ✓✓。
local function depositForRoute(cand, opts)
    local space = tonumber(opts.freeCargoSpace)
    local bp = tonumber(cand.basePrice)
    -- 拿不到货舱（API 失败）或货舱已满（=0）→ 一律用兜底探测金 ✓
    -- ★ 绝不能让预付金落到 1 ✗（那会让预测算出 0 利润，把整张榜带偏 ✓）
    if space == nil or space <= 0 or bp == nil or bp <= 0 then
        return opts.fallbackDeposit
    end
    local buy = bp * (1 + (tonumber(cand.lowest) or 0))
    local d = opts.Trade.planDeposit(space, tonumber(cand.unitSize) or 1, buy,
        opts.budget, opts.maxDeposit)
    d = tonumber(d) or 0
    if d < 1 then d = 1 end
    return math.floor(d)
end

local function fillPrediction(cand, pred)
    cand.attackChance = pred.attackChance and tonumber(pred.attackChance.value) or nil
    cand.profitPerFlight = pred.profitPerFlight
    cand.flights = pred.flights
    cand.flightTime = pred.flightTime and tonumber(pred.flightTime.value) or nil
    cand.maxAvailable = pred.maxAvailable and tonumber(pred.maxAvailable.value) or nil
    cand.transportedPerFlight = pred.transportedPerFlight
    cand.predictionError = pred.error
    local lo, hi, basis = netProfit(cand)
    cand.netProfitLow, cand.netProfitHigh, cand.profitBasis = lo, hi, basis
end

-- 扫**一个**区域：分析（pcall ✓）+ 每条路线算预测（pcall ✓）
-- ★ 任何一步失败都只写进 rec.error / cand.predictionFailed，**绝不中断整轮扫描** ✓✓
local function scanOneArea(command, player, ship, ctype, area, opts)
    local rec = {
        area = area, offset = { x = 0, y = 0 }, routeCount = 0,
        candidates = {}, predictions = {}, predictionsWithEscorts = {},
        routes = {}, acceptable = false,
    }

    local okRun, rShipName, _rType, rArea, rResults = pcall(function()
        return run(player.index, ship, ctype, area, player.index)
    end)
    if not okRun then
        rec.error = "area analysis failed: " .. tostring(rShipName)
        return rec
    end
    local results = rResults or rArea
    if type(rArea) == "table" then rec.area = rArea end
    if type(results) ~= "table" then
        rec.error = "area analysis returned nothing"
        return rec
    end

    local routes = (type(results.routes) == "table") and results.routes or {}
    rec.results = results
    rec.routes = routes
    rec.routeCount = #routes
    if #routes == 0 then
        rec.error = "no trade routes in this area"
        return rec
    end

    attachGoodsPrices(opts.goodsLib, routes)

    -- ★★ 必须把分析结果挂回 area 上 ✓（否则 tradecommand.lua:743 报 analysis nil ✓✓）
    rec.area.analysis = results

    local aArea = rec.area
    for _, r in ipairs(routes) do
        local cand = {
            name = r.name, lowest = r.lowest, highest = r.highest,
            basePrice = r.basePrice, unitSize = r.unitSize,
            profitPerSize = r.profitPerSize, from = r.from, to = r.to,
        }
        cand.unitProfit = (r.basePrice and r.basePrice * ((r.highest or 0) - (r.lowest or 0))) or nil

        local deposit = opts.depositProbe
        if deposit == nil then deposit = depositForRoute(cand, opts) end
        cand.deposit = deposit

        local okP, pred = pcall(function()
            return command:calculatePrediction(player.index, ship, aArea,
                { goodName = r.name, deposit = deposit, escorts = {} })
        end)
        if okP and type(pred) == "table" then
            fillPrediction(cand, pred)
            rec.predictions[r.name] = pred
        else
            cand.predictionFailed = tostring(pred)
        end
        rec.candidates[#rec.candidates + 1] = cand
    end

    -- ★ 参数维度②：护航 —— 只给**过不了闸门**的路线补算一次带护航的预测 ✓✓
    --   护航不改货物经济性 ✓，只降伏击概率 ✓ → 只有它能把"高风险高收益"救回闸门内 ✓
    --   没有护航候选 → 整段跳过（零额外开销 ✓）
    if #opts.escorts > 0 then
        for _, cand in ipairs(rec.candidates) do
            local ch = tonumber(cand.attackChance)
            if ch == nil or ch > opts.gate then
                local ok2, p2 = pcall(function()
                    return command:calculatePrediction(player.index, ship, aArea,
                        { goodName = cand.name, deposit = cand.deposit, escorts = opts.escorts })
                end)
                if ok2 and type(p2) == "table" and p2.attackChance ~= nil then
                    cand.attackChanceWithEscorts = tonumber(p2.attackChance.value)
                    rec.predictionsWithEscorts[cand.name] = p2
                end
            end
        end
    end

    -- 每条的有效风险：带护航更低就用带护航的 ✓（护航只用来**降风险** ✓）
    for _, cand in ipairs(rec.candidates) do
        local base = tonumber(cand.attackChance)
        local we = tonumber(cand.attackChanceWithEscorts)
        if we ~= nil and (base == nil or we < base) then
            cand.attackChanceEffective = we
            cand.escortsForGate = opts.escorts
        else
            cand.attackChanceEffective = base
            cand.escortsForGate = {}
        end
    end
    return rec
end

-- 一个区域算完：plan（复用纯函数库 ✓）+ 该区域的**最优路线** ✓
local function summariseArea(rec, Trade, factsBase, opts)
    local f = {}
    for k, v in pairs(factsBase) do f[k] = v end
    f.predictions = rec.predictions
    rec.plan, rec.planError = Trade.plan(rec.routes, f, { maxAttackChance = opts.gate })

    local pass, any = {}, {}
    for _, c in ipairs(rec.candidates) do
        any[#any + 1] = c
        local ch = tonumber(c.attackChanceEffective)
        if ch == nil or ch <= opts.gate then pass[#pass + 1] = c end
    end
    rankByNetProfit(pass, nil)
    rankByNetProfit(any, nil)

    rec.acceptable = (#pass > 0)
    rec.best = pass[1] or any[1]
    rec.candidatesByProfit = any
    if rec.best ~= nil then
        local lo, hi, basis = netProfit(rec.best)
        rec.bestNetLow, rec.bestNetHigh, rec.bestBasis = lo, hi, basis
        rec.bestRouteName = rec.best.name
        rec.bestChance = tonumber(rec.best.attackChanceEffective)
        rec.bestChanceBase = tonumber(rec.best.attackChance)
        rec.bestMetric = fallbackMetric(rec.best)
        rec.bestFlights = flightsOf(rec.best)
        rec.bestFlightTime = tonumber(rec.best.flightTime)
        rec.bestDeposit = rec.best.deposit
    end
    return rec
end

-- 回传给 DSH 的区域榜（**裁掉**重字段 ✓ —— area 不带 .analysis ✓，候选只留前 4 条 ✓）
local function buildRanking(scanned)
    local out = {}
    for _, rec in ipairs(scanned) do
        local a = rec.area
        local entry = {
            area = {
                lower = { x = a.lower.x, y = a.lower.y },
                upper = { x = a.upper.x, y = a.upper.y },
                offset = { x = rec.offset.x, y = rec.offset.y },
            },
            routeCount = rec.routeCount,
            bestRouteName = rec.bestRouteName,
            netProfitLow = rec.bestNetLow,
            netProfitHigh = rec.bestNetHigh,
            netProfitBasis = rec.bestBasis,
            attackChance = rec.bestChance,
            attackChanceBase = rec.bestChanceBase,
            profitPerSize = rec.bestMetric,
            flights = rec.bestFlights,
            flightTime = rec.bestFlightTime,
            deposit = rec.bestDeposit,
            escortsNeeded = (rec.best and rec.best.escortsForGate) or {},
            acceptable = rec.acceptable,
            candidates = {},
        }
        if rec.best and rec.best.attackChanceWithEscorts ~= nil then
            entry.attackChanceWithEscorts = rec.best.attackChanceWithEscorts
        end
        local list = rec.candidatesByProfit or rec.candidates
        for i = 1, math.min(SCAN_DETAIL, #list) do
            entry.candidates[i] = list[i]
        end
        if rec.error ~= nil then entry.error = rec.error end
        if rec.planError ~= nil then entry.planError = rec.planError end
        if rec.plan ~= nil and rec.plan.config ~= nil then
            entry.plannedGoodName = rec.plan.config.goodName
            entry.plannedDeposit = rec.plan.config.deposit
        end
        out[#out + 1] = entry
    end
    return out
end

function CopilotLinkIn.tradePlan(player, data)
    local t0 = os.clock()          -- ★ 扫描耗时基准（scanMs ✓ —— 同一个时钟本文件已在用 ✓）
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

    -- ★ ① 船在哪 —— 所有候选区域**必须含船** ✓✓
    --   原版硬约束：simulation.lua:546 `isShipRequiredInArea` → 船不在区域内直接拒绝 ✓
    --   → 所以候选区域一律**围绕船的星区**生成 ✓（显式给的 x,y 也要能含住船 ✓）
    local okPos, px, py = pcall(function() return player:getShipPosition(ship) end)
    if not okPos or tonumber(px) == nil or tonumber(py) == nil then
        return false, "NO_POSITION", "cannot read ship position for " .. ship .. "; pass x,y"
    end
    local shipX, shipY = math.floor(tonumber(px)), math.floor(tonumber(py))

    -- ★ ② 自己跑区域分析（**同步** ✓ —— run 直接返回 results ✓）
    --
    -- ⚠️ 坑：`areaanalysis.lua` 是**引擎脚本**，不是 lib ✗✓
    --   → 文件末尾**没有 return** ✗（它的 `run` 是**全局函数** ✓，是给 asyncf 调的 ✓）
    --   → 所以 `include("areaanalysis")` 返回 **nil** ✗
    --   正确做法：include 一下把文件**执行掉**（定义全局 run ✓），然后**直接调全局 run** ✓✓。
    -- ⚠️ 坑：`pcall` 会在最前面**多返回一个 true** ✗✓ —— 漏算它就会整体错位一格 ✓
    --   （run 的真实返回值: shipName, type, area, results, callingPlayer ✓）
    local okInc, incErr = pcall(function() return include("areaanalysis") end)
    if not okInc then return false, "NO_ANALYSIS_SCRIPT", tostring(incErr) end
    if type(run) ~= "function" then
        return false, "NO_ANALYSIS_RUN", "areaanalysis.lua did not define a global run()"
    end

    -- ★ ③ 命令实例：问合法区域尺寸 + 算每条路线的**真实预测** ✓✓
    --   （原版是把分析结果**挂回 area 上**再算预测的 ✓ —— 见 scanOneArea ✓）
    local okF, factory = pcall(function() return include("commandfactory") end)
    if not okF or type(factory) ~= "table" then
        return false, "NO_COMMAND_FACTORY", tostring(factory)
    end
    local okCmd, command = pcall(function() return factory.makeCommand(ctype) end)
    if not okCmd or command == nil then
        return false, "NO_COMMAND", tostring(command)
    end

    local Trade = include("copilottrade")
    local okGoods, goodsLib = pcall(function() return include("goods") end)
    if not okGoods then goodsLib = nil end

    -- 尺寸 / 偏移 / 预算（全部可用 data 覆盖，方便主人自己调 ✓）
    local templates = legalAreaSizes(command, player, ship)
    local reqSize = tonumber(data.size)
    local size = pickSquareSize(templates, reqSize)
    local sizeAdjusted = (reqSize ~= nil and reqSize ~= size)
    local half = math.floor((size - 1) / 2)
    local step = math.floor(tonumber(data.step) or SCAN_STEP)
    if step < 1 then step = 1 end
    local maxAreas = math.floor(tonumber(data.maxAreas) or SCAN_MAX_AREAS)
    if maxAreas < 1 then maxAreas = 1 end
    if maxAreas > 25 then maxAreas = 25 end
    local budgetMs = math.floor(tonumber(data.maxScanMs) or SCAN_BUDGET_MS)
    if budgetMs < 0 then budgetMs = 0 end
    local gate = tonumber(data.maxAttackChance) or Trade.MAX_ATTACK_CHANCE

    local offsets = scanOffsets(half, step)
    local used = {}
    for i = 1, #offsets do
        if #used >= maxAreas then break end
        used[#used + 1] = offsets[i]
    end

    -- 中心：默认船的星区 ✓；显式给了 x,y 就围绕它 —— 但**必须含船** ✓，
    -- 含不住就退回船的位置 ✓✓（否则那些区域原版根本不收 ✓）
    local baseX, baseY, usedShipCentre = shipX, shipY, false
    if tonumber(data.x) ~= nil and tonumber(data.y) ~= nil then
        baseX, baseY = math.floor(tonumber(data.x)), math.floor(tonumber(data.y))
    end

    local function collectAreas(bx, by)
        local list, miss = {}, 0
        for _, off in ipairs(used) do
            local a = buildArea(bx + off.x, by + off.y, size)
            if areaHasSector(a, shipX, shipY) then
                list[#list + 1] = { area = a, offset = { x = off.x, y = off.y } }
            else
                miss = miss + 1
            end
        end
        return list, miss
    end

    local areaList, dropped = {}, 0
    do
        local list, miss = collectAreas(baseX, baseY)
        areaList, dropped = list, dropped + miss
        if #areaList == 0 then
            baseX, baseY = shipX, shipY
            usedShipCentre = true
            list, miss = collectAreas(baseX, baseY)
            areaList, dropped = list, dropped + miss
        end
    end
    if #areaList == 0 then
        return false, "NO_AREAS", "no candidate area contains the ship"
    end

    -- 货舱剩余空间（预付金要用 ✓ —— 与 copilotcard 用的是同一套已验证 API ✓）
    local freeCargoSpace = nil
    do
        local okC, cs = pcall(function()
            return ShipDatabaseEntry(player.index, ship):getFreeCargoSpace()
        end)
        if okC then freeCargoSpace = tonumber(cs) end
    end

    local opts = {
        gate = gate,
        Trade = Trade,
        goodsLib = goodsLib,
        escorts = {},
        freeCargoSpace = freeCargoSpace,
        budget = tonumber(data.budget),
        maxDeposit = tonumber(data.maxDeposit),
        depositProbe = tonumber(data.depositProbe),
        fallbackDeposit = tonumber(data.depositProbe) or 1000000,
    }
    if type(data.escorts) == "table" then
        for _, n2 in ipairs(data.escorts) do
            if type(n2) == "string" and n2 ~= "" then opts.escorts[#opts.escorts + 1] = n2 end
        end
    end
    local wantedEscorts = opts.escorts

    local factsBase = {
        shipSector = { x = shipX, y = shipY },     -- ★ 真的船所在星区 ✓（旧版错填 area.lower ✗）
        actionShip = ship,
        freeCargoSpace = freeCargoSpace,
        escorts = wantedEscorts,
        budget = tonumber(data.budget),
        maxDeposit = tonumber(data.maxDeposit),
    }

    -- ★★★ 三维扫描：区域 × 商品 × 参数 ✓✓（目标见本段上方的「决策总目标」✓）
    --   scanMs 用 os.clock（进程 CPU 时间 —— 本 mod 的 order 排队也用同一个时钟 ✓）；
    --   预算是**软**的：只在两个区域之间检查 ✓，所以最多多跑一个区域 ✓。
    local scanned = {}
    local stoppedEarly = false
    local scanMs = 0
    for _, item in ipairs(areaList) do
        scanMs = math.floor((os.clock() - t0) * 1000)
        if #scanned > 0 and budgetMs > 0 and scanMs > budgetMs then
            stoppedEarly = true
            break
        end
        local rec = scanOneArea(command, player, ship, ctype, item.area, opts)
        rec.offset = item.offset
        rec.index = #scanned + 1
        summariseArea(rec, Trade, factsBase, opts)
        scanned[#scanned + 1] = rec
    end
    scanMs = math.floor((os.clock() - t0) * 1000)

    rankAreasByNet(scanned)
    local chosen = scanned[1]
    local analysedArea = chosen.area
    local results = chosen.results
    local routes = chosen.routes
    local candidates = chosen.candidates
    local predictions = chosen.predictions

    -- 所有区域都**没有路线** → 保持旧版的"空"形状 ✓（并补上新字段 ✓）
    if #routes == 0 then
        return true, {
            ship = ship, area = analysedArea, routes = {},
            routeCount = 0, candidates = {},
            plan = nil,
            planError = chosen.error,
            note = "no trade routes in this area — a different area may have some",
            escortsOffered = wantedEscorts,
            planNeededEscorts = false,
            -- ★ 旧版这个分支**也会**带上 analysis ✓ → 照旧保留（分析炸掉时才为 nil ✓）
            analysis = results and {
                sectors = results.sectors, reachable = results.reachable,
                unreachable = results.unreachable,
                biggestFactionInArea = results.biggestFactionInArea,
            } or nil,
            recommendation = nil,
            riskWarning = string.format(
                "扫了 %d 个区域，一条贸易路线都没有 ✗ —— 本鱼**不推荐**下单 ✓（换一片星区再来 ✓）",
                #scanned),
            areaRanking = buildRanking(scanned),
            areasScanned = #scanned,
            scanMs = scanMs,
            scanNote = string.format("多区域扫描：%d 个区域 / 步长 %d / 共 %d ms / 无路线",
                #scanned, step, scanMs),
            orderHint = {
                ship = ship, action = action, size = size,
                x = baseX + chosen.offset.x, y = baseY + chosen.offset.y,
                note = "no route found here — nothing to order",
            },
            scan = {
                step = step, size = size, sizeRequested = reqSize, legalSizes = templates,
                maxAreas = maxAreas, budgetMs = budgetMs, stoppedEarly = stoppedEarly,
                usedShipCentre = usedShipCentre, droppedNoShip = dropped,
                shipSector = { x = shipX, y = shipY }, maxAttackChance = gate,
                freeCargoSpace = freeCargoSpace, escortsConsidered = wantedEscorts,
                objective = "多区域 × 多商品 × 净收益 —— 在尽可能低的风险下取尽可能高的利润",
            },
        }
    end

    -- ★★★ 最终推荐：在**全部区域的全部路线**里取闸门内**净收益最高**的那条 ✓✓
    --   这就是主人那句「从多区域、多商品、净收益去决策」的落点 ✓
    local pool = {}
    for _, rec in ipairs(scanned) do
        for _, c in ipairs(rec.candidates) do
            local ch = tonumber(c.attackChanceEffective)
            if ch == nil or ch <= gate then
                c.areaIndex = rec.index
                c.areaOffset = { x = rec.offset.x, y = rec.offset.y }
                pool[#pool + 1] = c
            end
        end
    end
    rankByNetProfit(pool, gate)

    local recommendation, riskWarning = nil, nil
    local top = pool[1]
    if top ~= nil then
        local recTop = scanned[top.areaIndex]
        local aTop = recTop.area
        local lo, hi, basis = netProfit(top)
        recommendation = {
            area = {
                lower = { x = aTop.lower.x, y = aTop.lower.y },
                upper = { x = aTop.upper.x, y = aTop.upper.y },
                offset = { x = recTop.offset.x, y = recTop.offset.y },
            },
            x = baseX + recTop.offset.x,
            y = baseY + recTop.offset.y,
            size = size,
            action = action,
            goodName = top.name,
            deposit = top.deposit,
            escorts = top.escortsForGate or {},
            attackChance = top.attackChanceEffective,
            attackChanceBase = top.attackChance,
            attackChanceWithEscorts = top.attackChanceWithEscorts,
            maxAttackChance = gate,
            netProfitLow = lo,
            netProfitHigh = hi,
            profitBasis = basis,
            profitPerSize = top.profitPerSize,
            flights = top.flights,
            flightTime = top.flightTime,
            maxAvailable = top.maxAvailable,
            transportedPerFlight = top.transportedPerFlight,
            from = top.from,
            to = top.to,
        }
        recommendation.reason = string.format(
            "净收益 C%d~%d（保守~乐观，口径 %s／航班 %s 次）；伏击概率 %s ≤ %.0f%%；区域偏移 (%+d,%+d)；商品「%s」；预付金 %d；护航 %s",
            math.floor((lo or 0) + 0.5), math.floor((hi or 0) + 0.5), tostring(basis),
            tostring(flightsOf(top)),
            top.attackChanceEffective and string.format("%.1f%%", top.attackChanceEffective * 100) or "未知",
            gate * 100, recTop.offset.x, recTop.offset.y, tostring(top.name),
            math.floor(tonumber(top.deposit) or 0),
            (#(top.escortsForGate or {}) > 0) and table.concat(top.escortsForGate, ",") or "无")
    else
        -- ★ 一条都没过闸门 → **明说**，绝不偷偷挑一条高风险的 ✓✓
        local anyTop = nil
        for _, rec in ipairs(scanned) do
            if rec.best ~= nil
                and (anyTop == nil or (tonumber(rec.bestNetLow) or -1) > (tonumber(anyTop.bestNetLow) or -1)) then
                anyTop = rec
            end
        end
        if anyTop ~= nil then
            riskWarning = string.format(
                "没有任何路线通过风险闸门（伏击概率 ≤ %.0f%%）✗ —— 本鱼**不推荐**下单 ✓。最好的候选是「%s」（区域偏移 %+d,%+d，伏击概率 %s）；可派护航重算 / 缩小区域范围 / 换一艘更快更安全的船 ✓",
                gate * 100, tostring(anyTop.bestRouteName), anyTop.offset.x, anyTop.offset.y,
                anyTop.bestChance and string.format("%.1f%%", anyTop.bestChance * 100) or "未知")
        else
            riskWarning = "扫过的区域里没有任何可用路线 ✗ —— 本鱼**不推荐**下单 ✓"
        end
    end

    -- 下单坐标提示 ✓（有推荐 → 指向推荐的那个区域；没有 → 指向扫描的中心区域 ✓）
    local orderHint = {
        ship = ship, action = action, size = size,
        x = baseX + chosen.offset.x, y = baseY + chosen.offset.y,
        note = "order here — the ship is already inside this area",
    }
    if recommendation ~= nil then
        orderHint.x, orderHint.y = recommendation.x, recommendation.y
        orderHint.goodName = recommendation.goodName
        orderHint.deposit = recommendation.deposit
        orderHint.escorts = recommendation.escorts
    end

    -- ★ ④ 纯函数决策（lib/copilottrade.lua ✓ —— 有离线自检 ✓✓）
    --   每个区域在 summariseArea 里已经各算过一份 ✓ → 这里取**选中区域**那份 ✓
    local facts = {}
    for k, v in pairs(factsBase) do facts[k] = v end
    facts.predictions = predictions
    local plan, perr = chosen.plan, chosen.planError

    CopilotRpc.trace(string.format(
        "tradePlan %s area=[%d,%d]-[%d,%d] routes=%d plan=%s 扫描=%d区域/%dms",
        ship, analysedArea.lower.x, analysedArea.lower.y, analysedArea.upper.x, analysedArea.upper.y,
        #routes, plan and plan.config.goodName or ("none(" .. tostring(perr) .. ")"),
        #scanned, scanMs))

    -- ★★★ 护航重算 ✓✓（2026-10-16 加；2026-10-17 改为**复用扫描阶段的结果** ✓✓）
    --
    -- 病因：原来 `escorts = {}` 永远为空 ✗ → 模型看到"加护航能降风险"这句话 ✓，
    --   却**无法验证加完能不能压到 10% 以下** ✗ → 它只能保守拒绝 ✓✓（实测连续答 None ✓）。
    -- 修法：把 DSH 传来的**同星系护航候选**代入 ✓：
    --   ① 扫描阶段已经给"过不了闸门"的路线各算过一次带护航预测 ✓
    --      （rec.predictionsWithEscorts ✓）→ 这里**不再重算**，省一整轮 calculatePrediction ✓✓
    --   ② 基础预测全超标但加护航达标 → 用护航版**重算计划** ✓✓
    local planWithEscorts = false
    local predsWith = chosen.predictionsWithEscorts or {}
    if #wantedEscorts > 0 then
        for _, c in ipairs(candidates) do
            local p2 = predsWith[c.name]
            if type(p2) == "table" and p2.attackChance ~= nil then
                c.attackChanceWithEscorts = c.attackChanceWithEscorts or tonumber(p2.attackChance.value)
            end
        end

        -- 基础预测全超标、但加护航后达标 → 用护航版**重算计划** ✓✓
        if plan == nil and next(predsWith) ~= nil then
            local facts2 = {}
            for k, v in pairs(facts) do facts2[k] = v end
            facts2.predictions = predsWith
            facts2.escorts = wantedEscorts
            local p2, e2 = Trade.plan(routes, facts2, { maxAttackChance = gate })
            if p2 ~= nil then
                plan, perr = p2, nil
                p2.config.escorts = wantedEscorts
                p2.reason = tostring(p2.reason) .. "  ★（加护航 " .. table.concat(wantedEscorts, ",") .. " 后才达标）"
                planWithEscorts = true
                CopilotRpc.trace("tradePlan 护航版达标 ✓ escorts=" .. table.concat(wantedEscorts, ","))
            else
                perr = e2
            end
        end
    end

    -- ★★ 把 plan.config 对齐到**净收益最优**的那条路线 ✓✓（主人要的是净收益 ✓）
    --   纯函数库 M.plan 用的是它自己的排法（毛利 × 航班），与主人钦定的"净收益"口径
    --   可能不同 → 最终 config 一律以**净收益榜**为准 ✓✓。
    --   顺带修一处旧病：M.plan 拿不到货舱/货价时预付金会退化成 1 ✗（= 几乎不装货 ✗），
    --   这里用**该路线自己的"装满货舱"预付金**改回来 ✓✓。
    if plan ~= nil and chosen.best ~= nil then
        local b = chosen.best
        local lo, hi, basis = netProfit(b)
        plan.config.goodName = b.name
        plan.config.deposit = b.deposit
        plan.config.escorts = b.escortsForGate or {}
        plan.netProfitLow, plan.netProfitHigh, plan.profitBasis = lo, hi, basis
        plan.attackChance = tonumber(b.attackChanceEffective)
        plan.reason = tostring(plan.reason) .. string.format(
            "  ★ 按主人钦定的**净收益**口径重排：本区域最优是「%s」（净收益 C%d~%d，伏击概率 %s）",
            tostring(b.name), math.floor(lo + 0.5), math.floor(hi + 0.5),
            b.attackChanceEffective and string.format("%.1f%%", b.attackChanceEffective * 100) or "未知")
        if #(b.escortsForGate or {}) > 0 then planWithEscorts = true end
    end

    -- 扫描说明（人看的 ✓；第一句**与旧版一字不差** ✓✓，后面追加扫描信息 ✓）
    local scanNote = string.format("多区域扫描：%d 个区域 / 步长 %d / 共 %d ms", #scanned, step, scanMs)
    local notes = { "plan only — nothing was issued (order is a separate call)", scanNote }
    if sizeAdjusted then
        notes[#notes + 1] = string.format("data.size=%s 不是 %s 的合法区域尺寸 → 改用 %dx%d",
            tostring(data.size), tostring(action), size, size)
    end
    if #offsets > #used then
        notes[#notes + 1] = string.format("候选区域共 %d 个，按 maxAreas=%d 只扫了最近的 %d 个",
            #offsets, maxAreas, #used)
    end
    if dropped > 0 then
        notes[#notes + 1] = string.format("其中 %d 个候选区域含不住船的星区（已跳过 ✓）", dropped)
    end
    if stoppedEarly then
        notes[#notes + 1] = string.format("扫描提前结束：已用 %d ms > 预算 %d ms（调大 data.maxScanMs 可扫更多）",
            scanMs, budgetMs)
    end
    if usedShipCentre then
        notes[#notes + 1] = string.format("给的 x,y 周围没有能含住船的合法区域 → 改以船所在星区 (%d,%d) 为中心",
            shipX, shipY)
    end
    if recommendation ~= nil then
        notes[#notes + 1] = string.format("推荐「%s」净收益 C%d~%d，伏击概率 %s ≤ %.0f%%",
            tostring(recommendation.goodName),
            math.floor((recommendation.netProfitLow or 0) + 0.5),
            math.floor((recommendation.netProfitHigh or 0) + 0.5),
            recommendation.attackChance and string.format("%.1f%%", recommendation.attackChance * 100) or "未知",
            gate * 100)
    elseif riskWarning ~= nil then
        notes[#notes + 1] = riskWarning        -- ★ 一条都没过闸门 → note 里也**明说** ✓✓
    end

    -- ★★★ 只**组装**，不发起 ✓✓（主人 2026-10-16 指定 ✓）
    return true, {
        ship = ship,
        area = analysedArea,
        routeCount = #routes,
        candidates = candidates,
        plan = plan,                       -- 含 config + reason ✓；nil 表示本轮不建议下单 ✓
        planError = perr,
        note = table.concat(notes, "；"),
        escortsOffered = wantedEscorts,
        planNeededEscorts = planWithEscorts == true,
        analysis = {
            sectors = results.sectors, reachable = results.reachable,
            unreachable = results.unreachable,
            biggestFactionInArea = results.biggestFactionInArea,
        },

        -- ★★★ 2026-10-17 新增：多区域 × 多商品 × 净收益 ✓✓
        --   recommendation = 三维搜索的最优解（闸门内**净收益最高** ✓）；
        --   nil 表示**一条都没过闸门** ✗ → 看 riskWarning（明说不推荐 ✓，绝不偷偷挑 ✓）
        recommendation = recommendation,
        riskWarning = riskWarning,
        areaRanking = buildRanking(scanned),   -- 区域榜：达标在前 ✓ 每区只回前 4 条候选 ✓
        areasScanned = #scanned,
        scanMs = scanMs,
        scanNote = scanNote,
        orderHint = orderHint,
        scan = {
            step = step, size = size, sizeRequested = reqSize, legalSizes = templates,
            maxAreas = maxAreas, budgetMs = budgetMs, stoppedEarly = stoppedEarly,
            usedShipCentre = usedShipCentre, droppedNoShip = dropped,
            shipSector = { x = shipX, y = shipY }, maxAttackChance = gate,
            depositProbe = opts.depositProbe, freeCargoSpace = freeCargoSpace,
            escortsConsidered = wantedEscorts,
            objective = "多区域 × 多商品 × 净收益 —— 在尽可能低的风险下取尽可能高的利润",
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
-- recall：把船从后台命令里叫回来 ✓✓（2026-10-16 加，为主人"随时看决策"服务 ✓）
--
-- 原版能力：`Simulation.forceRecall(shipName)` —— **已注册 callable** ✓
--   （simulation.lua:759 `callable(Simulation, "forceRecall")` ✓）
-- 用途：后台命令会被 BGS 从存档恢复 ✓，所以重启游戏也叫不回来 ✗；
--   有了它，主人随时能把船叫回空闲态 → 立刻触发新一轮 decide ✓✓。
function CopilotLinkIn.onRecall(data)
    data = data or {}
    local ship = data.ship
    if type(ship) ~= "string" or ship == "" then
        return false, "BAD_REQUEST", "recall needs data.ship"
    end
    local ok, err = invokeSimulation("forceRecall", ship)
    if not ok then
        return false, "RECALL_FAILED", tostring(err)
    end
    -- 叫回来后应该转入"新的一轮空闲" ✓ —— 顺手清掉记账，让它下轮立刻发起决策 ✓
    if CopilotFleet ~= nil and type(CopilotFleet.idleSeen) == "table" then
        CopilotFleet.idleSeen[ship] = false
        CopilotFleet.decided[ship] = nil
    end
    CopilotRpc.trace("onRecall " .. ship .. "（已发 forceRecall ✓）")
    return true, { ship = ship, recalled = true, note = "forceRecall sent; the ship returns to idle shortly" }
end

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
    CopilotRpc.handle("recall",  bind("onRecall"))   -- ★ 召回（随时把船叫回空闲 ✓）
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
