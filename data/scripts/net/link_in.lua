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

    CopilotRpc.trace("  include copilot/card…")
    local Card = include("copilot/card")     -- 与 ops.lua 共用同一份读取逻辑 ✓（跨 VM 的唯一办法 ✓）
    CopilotRpc.trace("  copilot/card 就绪，开始读舰队…")

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
        --   ③ lib/copilot/trade.lua 的纯函数 → 挑路线 + 定预付金 + 挑护卫 ✓
        --
        -- 为什么可行 ✗✓：areaanalysis.run 的末尾是
        --     return shipName, type, area, results, callingPlayer
        --   —— 它把结果交出来了 ✓✓（见该文件 line 138 ✓）
        -- ⚠️ 这里**不要**放任何顶层可执行语句 ✗（2026-10-16 实测 ✓）：
--   `/copilot reload` 是用**命令脚本那个 VM 的 _ENV** 去 load 本文件的 ✗，
--   而那个 VM 里没有 CopilotRpc → 顶层语句一执行就
--   "attempt to index global 'CopilotRpc' (a nil value)" ✗✓✓。
--   （也就是说：**net 链的改动热重载不了，必须重启游戏** ✓ —— 见 AGENTS.md ✓）
return CopilotLinkIn.informOnly(CopilotLinkIn.tradePlan(player, data), data)

    elseif what == "minePlan" then
        -- ★★★ 采矿决策的**数据获取 + 组装**（只算不下单 ✓）—— 见 jobPlan ✓
        --   与 tradePlan 同构：多区域 × 参数 × 层级加权 + 同一道 0.10 风险闸门 ✓✓
        return CopilotLinkIn.informOnly(CopilotLinkIn.jobPlan(player, data, "Mine"), data)

    elseif what == "salvagePlan" then
        -- ★★★ 打捞决策：装备件数 × E[稀有度层级]，次级键 = 残骸场材料层级均值 ✓
        return CopilotLinkIn.informOnly(CopilotLinkIn.jobPlan(player, data, "Salvage"), data)

    elseif what == "jobPlan" then
        -- 一个入口两种活（data.action = Mine | Salvage ✓）；缺省按 Mine ✓
        return CopilotLinkIn.informOnly(CopilotLinkIn.jobPlan(player, data, data.action), data)

    elseif what == "sellPlan" then
        -- ★★★ 卖货决策（2026-10-17 加，Issue B ✓✓）：把**船上的货**变现 ✓
        --   为什么需要：Trader 被伏击召回时**只退押金、不发利润**，货还留在船上 ✓
        --   （原版 tradecommand.lua:456-490 ✓），此时再下 Trade 会**装不进新货** ✗
        --   → 必须先 Sell ✓✓（主人的场景 ✓）
        return CopilotLinkIn.informOnly(CopilotLinkIn.sellPlan(player, data), data)

    elseif what == "scoutPlan" then
        -- 勘察（主人的战略前提 ✓）：没有已探索星区，就没有"往里推"的方向 ✓
        return CopilotLinkIn.informOnly(CopilotLinkIn.scoutPlan(player, data), data)

    elseif what == "sectorFacts" then
        -- ★★ 任意星区的**事实**（2026-10-17 补 ✓✓）
        --
        --   主人原则（原话）：「你只给她一个大目标，以及游戏当前的机制，让她自己判断」
        --   「不是往中心两跳，而是评估威胁后当前是否支持往中心走，支持的话又往中心走多少」
        --   → 所以这里**只给可比的数字** ✓✓，**不给任何"该不该去/去多远"的结论** ✗✗。
        --
        --   同一组原版函数与卡片 depth 段一致（证据见 MECHANICS.md §0 ✓）：
        --     Balancing_GetSectorRichnessFactor(x,y)  富饶度 ✓
        --     Balancing_GetMaterialProbability(x,y)   材料概率 ✓
        --     Balancing_InsideRing(x,y)               是否在中心屏障环内 ✓
        --   全部 pcall 包裹 ✓：签名不符只会少字段，绝不崩 ✗✓
        local sx = tonumber(data.x)
        local sy = tonumber(data.y)
        if sx == nil or sy == nil then
            return false, "BAD_REQUEST", "query sectorFacts needs data.x and data.y"
        end

        local MATERIAL_NAMES = { "Iron", "Titanium", "Naonite", "Trinium", "Xanion", "Ogonite", "Avorion" }
        local function probe(ax, ay)
            local out = {
                x = ax, y = ay,
                distanceFromCentre = math.floor(math.sqrt(ax * ax + ay * ay) + 0.5),
                manhattanToCentre = math.abs(ax) + math.abs(ay),
            }
            local okR, rich = pcall(Balancing_GetSectorRichnessFactor, ax, ay)
            if okR then out.richness = tonumber(rich) else out.richnessError = tostring(rich) end
            local okG, ring = pcall(Balancing_InsideRing, ax, ay)
            if okG then out.insideCentreRing = ring else out.ringError = tostring(ring) end
            local okP, probs = pcall(Balancing_GetMaterialProbability, ax, ay)
            if okP and type(probs) == "table" then
                local list = {}
                local n = 0
                if NumMaterials ~= nil then n = NumMaterials() end
                if n <= 0 then n = #probs end
                for i = 1, n do
                    -- 原版用法是 probabilities[i - 1]（resourcetrader.lua:152 ✓）；两种索引都试 ✓
                    local v = tonumber(probs[i - 1])
                    if v == nil then v = tonumber(probs[i]) end
                    if v ~= nil and v > 0 then
                        list[#list + 1] = {
                            materialIndex = i,
                            material = MATERIAL_NAMES[i] or ("Material" .. tostring(i)),
                            probability = v,
                        }
                    end
                end
                table.sort(list, function(a, b) return a.probability > b.probability end)
                for i = #list, 5, -1 do list[i] = nil end   -- 只留前 4 个，控制体积 ✓
                out.materialProbabilities = list
            else
                out.materialProbabilityError = tostring(probs)
            end
            return out
        end

        local res = { what = "sectorFacts", sector = probe(sx, sy) }

        -- 朝中心方向取样（同一口径 ✓，便于横向比较 ✓）
        local sgnX = (sx > 0 and -1) or (sx < 0 and 1) or 0
        local sgnY = (sy > 0 and -1) or (sy < 0 and 1) or 0
        res.towardCentre = {
            probe(sx + sgnX * 8, sy + sgnY * 8),
            probe(sx + sgnX * 16, sy + sgnY * 16),
            probe(sx + sgnX * 28, sy + sgnY * 28),
        }

        -- 若指定了船：把那艘船的能力事实也带上（含护航判据需要的航程 ✓✓）
        if type(data.ship) == "string" and data.ship ~= "" then
            local cardOk, card = pcall(Card.shipCard, player, data.ship)
            if cardOk and type(card) == "table" then
                res.ship = {
                    name = data.ship,
                    sector = card.sector,
                    hyperspace = card.hyperspace,          -- ★ 护航判据要它 ✓
                    captainClass = card.captainClass,
                    turretCount = card.turretCount,
                    freeCargoSpace = card.freeCargoSpace,
                    holdHasGoods = card.holdHasGoods,
                    actions = card.actions,
                }
            else
                res.shipError = tostring(card)
            end
        end

        -- ★ 如实说明**算不出什么** ✓（不许让决策方以为这里有产量预测 ✗）
        res.cannotCompute = {
            planNumbers = "该星区的原版产量/伏击预测这里**算不出来** ✗ —— 原版预测要求船**已经在那个区域内** ✓（所有动作的区域都必须含船 ✓）。要那里的数字，得先 Travel / Scout 过去 ✓。",
        }
        res.note = "这里只有**事实**（富饶度 / 材料概率 / 环侧 / 离中心距离）✓ —— 没有任何'该不该去'的结论 ✓；要不要走、什么时候走、走多远，由决策方自己判断 ✓。"
        return true, res

    elseif what == "goal" then
        local name = data.ship
        if type(name) ~= "string" or name == "" then
            return false, "BAD_REQUEST", "query goal needs data.ship"
        end
        local Goal = include("copilot/goal")
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
    -- ★★ Sell（2026-10-17 加，Issue B ✓✓）：UUID **实读**自原版
    --   data/scripts/commandtype.lua（`Sell = "6bf2d9af-…"` ✓），不是猜的 ✓
    Sell    = "6bf2d9af-255b-4108-a1e1-dc83ace49819",
    --   · CommandType.Scout = "7619ca9c-3f26-4b89-a4a4-10fd9aca5c60"（commandtype.lua L? ✓ 实读核对 ✓）
    Scout   = "7619ca9c-3f26-4b89-a4a4-10fd9aca5c60",
}

-- 各命令的默认区域边长（与 LLM-OPS.md 的调研一致 ✓）
local DEFAULT_SIZE = { Mine = 15, Salvage = 15, Trade = 17, Travel = 1, Sell = 15, Scout = 21 }   -- ★ Scout 原版 getAreaSize = 21x21（scoutcommand.lua:416 ✓ 实读）

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

-- ★ 这三个 helper **上移**到这里（2026-10-17 ✓）：因为 `onOrder`（下文，早于 sellPlan）
--   也要读货舱 ✓，而 Lua 的 local 是**词法作用域** ✗ —— 放在 sellPlan 旁边 onOrder 看不到 ✓✓。-- 读船上的货（返回 goodsToSell, used ✓）；读不到就 nil, err ✓
local function readHoldGoods(player, ship)
    local okE, entry = pcall(function() return ShipDatabaseEntry(player.index, ship) end)
    if not okE or entry == nil then return nil, "no ShipDatabaseEntry for " .. tostring(ship) end
    local okG, cargo = pcall(function() return entry:getCargo() end)
    if not okG or type(cargo) ~= "table" then
        return nil, "cannot read hold: " .. tostring(cargo)
    end
    local list, used = {}, 0
    for g, amount in pairs(cargo) do
        local a = tonumber(amount) or 0
        if a > 0 then
            local name = nil
            local okN, nm = pcall(function() return g.name end)
            if okN and type(nm) == "string" and nm ~= "" then name = nm end
            if name == nil then
                local okS, s = pcall(function() return tostring(g) end)
                if okS and type(s) == "string" and s ~= "" then name = s end
            end
            if name ~= nil then
                local stolen = false
                local okSt, st = pcall(function() return g.stolen == true end)
                if okSt then stolen = st end
                list[#list + 1] = { goodName = name, amount = math.floor(a), stolen = stolen }
                used = used + a
            end
        end
    end
    return list, nil, used
end

-- 取一个"数值"（原版 yield 可能是 number，也可能是 {from,to} 或 {value} ✓ —— 三种都兜 ✓）
local function numericRange(v)
    if type(v) == "number" then return v, v end
    if type(v) == "table" then
        local lo = tonumber(v.from)
        local hi = tonumber(v.to)
        if lo == nil then lo = tonumber(v.value) end
        if hi == nil then hi = lo end
        if lo ~= nil then return lo, hi or lo end
    end
    return nil, nil
end

-- 被伏击时**卖掉的比例**（证据见文件头 ✓）：返回 keepFraction ✓
local function attackKeepFraction(duration)
    local d = tonumber(duration)
    if d == nil or d <= 0 then return 0 end                -- 读不到时长 → 最保守：一点都卖不掉 ✓
    local attackAt = 0.425 * d                             -- random(0.1,0.75) 的期望 ✓
    local sells = (attackAt >= 11 * 60) or (attackAt > d * 0.8)
    if not sells then return 0 end                          -- 还没到 11 分钟就被打断 → 一点不卖 ✓
    return 0.425
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
    --     config.escorts   = 护航舰艇（★ 原版判据：与行动船距离 ≤ **护卫自己一跳航程** ✓，不要求同星系 ✓）
    local config = {
        duration = tonumber(data.duration) or 1,
        safeMode = data.safeMode == true,
        immediateDelivery = data.immediateDelivery == true,
    }
    -- ★★ 注意：**只有 Trade 才有"路线"** ✗✓（2026-10-16 实测）
    --   本鱼原先把这段校验放在**所有动作**上 ✗ → 下 Mine 时也被判
    --   "this area has no trade routes at all" ✓（Mine 的 routes 当然是空的 ✓）。
    --   所以整段用 `if ctype == COMMAND_TYPES.Trade then` 圈起来 ✓✓。

    -- ★★★ Trade 的**货舱感知**（Issue B ✓✓）：船上有货 → 先卖 ✗→✓
    --   原因（原版 tradecommand.lua ✓）：被伏击召回时货**留在船上**（:460-464 ✓），
    --   而 Trade 只能装**剩余空间** ✗（:773-797 transportedPerFlight 受 freeCargoSpace 限制 ✓）
    --   → 有货还去贸易 = 装得少、赚得少、钱被压在货里 ✓（主人明确点出的场景 ✓✓）
    if ctype == COMMAND_TYPES.Trade then
        local hold, _herr, used = readHoldGoods(player, ship)
        if hold ~= nil and #hold > 0 then
            return false, "HOLD_HAS_GOODS", string.format(
                "the hold still holds %d units (%d kinds) — run action=Sell first, "
                .. "then trade with an empty hold (otherwise the trade carries almost nothing)",
                math.floor(used or 0), #hold)
        end
    end

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

    -- ★★★ Sell：把 config.goodsToSell 装上（Issue B ✓✓ 2026-10-17）
    --   形状由原版决定 ✓：`{ {goodName=…, amount=…, stolen=…} }`（sellcommand.lua:243/:326-343 ✓）
    --   默认**卖掉船上的全部货** ✓；若 DSH 显式给了 goodsToSell 就按它来（并按船上实际数量夹紧 ✓）。
    if ctype == COMMAND_TYPES.Sell then
        local hold, herr, used = readHoldGoods(player, ship)
        if hold == nil then
            return false, "HOLD_UNREADABLE", tostring(herr)
        end
        if #hold == 0 then
            return false, "HOLD_EMPTY", "the hold is empty — there is nothing to sell"
        end
        local wanted = nil
        if type(data.goodsToSell) == "table" and #data.goodsToSell > 0 then
            -- 只认船上真有的货 ✓，数量夹到船上实际值 ✓（原版 getErrors :349-360 会在超量时报错 ✗）
            wanted = {}
            for _, want in ipairs(data.goodsToSell) do
                local wn = type(want) == "table" and want.goodName or nil
                if type(wn) == "string" then
                    for _, have in ipairs(hold) do
                        if have.goodName == wn then
                            local amt = tonumber(want.amount) or have.amount
                            if amt > have.amount then amt = have.amount end
                            if amt > 0 then
                                wanted[#wanted + 1] = { goodName = wn, amount = math.floor(amt), stolen = have.stolen }
                            end
                            break
                        end
                    end
                end
            end
            if #wanted > 0 then hold = wanted end
        end
        config.goodsToSell = hold
        CopilotRpc.trace(string.format("onOrder Sell：goodsToSell = %d 种 / %d 单位 ✓（船上共 %d 单位 ✓）",
            #hold, (function() local n = 0 for _, g in ipairs(hold) do n = n + g.amount end return n end)(),
            math.floor(used or 0)))
    end

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

-- 尺寸：没给 → ★ **用该命令自己的合法正方形** ✓（2026-10-17 修 bug ✗✓）
--   病因：原来 `want == nil → return 17` 是**硬编码** ✗（Trade 的味道 ✗），
--   于是 Sell（原版就是 15x15，sellcommand.lua:414 ✓）会拿到 **17** ✗✓ —— 离线自检当场抓到 ✓。
--   改后：Trade 的合法正方形仍是 17 ✓（无回归 ✓）、Mine/Salvage/Sell → 15 ✓✓。
-- 给了 → 合法就用 ✓；不合法 → 用原版第一个正方形 ✓；一个都问不到 → 用 fallback（缺省 17 ✓）。
local function pickSquareSize(templates, requested, fallback)
    local want = tonumber(requested)
    if want == nil then
        for _, t in ipairs(templates) do
            if t.x == t.y then return t.x end
        end
        return tonumber(fallback) or 17
    end
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

-- ★★★ 候选区域集合（**每个区域都必须含船** ✓✓）—— tradePlan 与 jobPlan 共用 ✓
--
-- 硬依据：原版 simulation.lua:546 `isShipRequiredInArea` → Mine/Salvage/Trade 都要求
--   船**已经在目标区域内**，否则 startAreaAnalysis/startCommand 会被静默拒绝 ✗。
-- 所以候选区域只能围绕船的星区生成 ✓；显式给的 x,y 含不住船时**退回船的位置** ✓✓。
--
-- 返回：list, dropped（含不住船被丢掉的个数）, usedShipCentre, baseX, baseY ✓
local function collectAreaList(used, size, baseX, baseY, shipX, shipY)
    local function collect(bx, by)
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

    local list, miss = collect(baseX, baseY)
    local dropped, usedShipCentre = miss, false
    if #list == 0 then
        baseX, baseY = shipX, shipY
        usedShipCentre = true
        local l2, m2 = collect(baseX, baseY)
        list, dropped = l2, dropped + m2
    end
    return list, dropped, usedShipCentre, baseX, baseY
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

-- ★★★ 收益模型（2026-10-16 改：**风险调整**，主人钦定 ✓✓）
--
-- 原版证据（tradecommand.lua ✓，全部实读）：
--   · 被伏击 → 强制召回 → `onRecall`（:450）**不给被中断那一班的利润** ✗
--       :490  runTime ≥ 0.35×flightTime → 只退「押金 − 货钱」，**利润为 0** ✓
--       :496/:499 runTime < 0.35×flightTime → 全额退押金，**利润同样为 0** ✓
--       （★ 货**留在船上** ✗ —— 只能靠 Sell 变现 → Issue B ✓✓）
--   · 已经飞完的班次**照样结算** ✓（:124-127 每班 addYield、:147 ✓）
--   · 伏击时刻 = random(0.1,0.85) × flightTime ×（多班则 ×2，否则 ×1）（:89-96 ✓）
--       → ★ 伏击落在**第一或第二班之内** ✓ → 被伏击时**最多已结算 1 班** ✓✓
--   · 押金**不是成本** ✓：完成时 :135/:142 `money = money + self.config.deposit` 是**退还** ✓
--       （所以最好情况就是 profitPerFlight × flights，**不要**再减押金 ✗✓）
--
-- 于是（p = attackChance）：
--     最好情况  best  = profitPerFlight × flights          （标注为 best-case ✓）
--     期望      exp   = (1−p) × best + p × (1 班的利润)      （★ 排序主键 ✓✓）
--   p 未知时**不做调整**（= best）并在口径里**明说** ✓（原版闸门对未知也是放行 ✓，
--   保持一致；未知就乱打折反而会误杀合法候选 ✗）
--
-- 返回：bestLow, bestHigh, expLow, expHigh, 口径名（以 "netProfit" 开头 ✓ 供 basisRank 用 ✓）
local function profitModel(c)
    local fl = flightsOf(c)
    local pf = c.profitPerFlight
    if type(pf) ~= "table" or fl == nil or fl <= 0 then
        local m = fallbackMetric(c)
        return m, m, m, m, "profitPerSize(fallback; no risk adjustment available)"
    end
    local low, high = tonumber(pf.from), tonumber(pf.to)
    if low == nil or high == nil then
        local m = fallbackMetric(c)
        return m, m, m, m, "profitPerSize(fallback; no risk adjustment available)"
    end

    local bestLow, bestHigh = low * fl, high * fl

    local pRaw = tonumber(c.attackChanceEffective)
    if pRaw == nil then pRaw = tonumber(c.attackChance) end
    if pRaw == nil then
        -- 概率未知 → 与闸门口径一致：放行、且**不做**风险调整 ✓（并在口径里写明 ✓）
        return bestLow, bestHigh, bestLow, bestHigh, "netProfit(chance unknown -> unadjusted)"
    end
    local p = pRaw
    if p < 0 then p = 0 end
    if p > 1 then p = 1 end

    -- 被伏击时最多结算 1 班（证据见上 ✓）；保守用 from、乐观用 to ✓
    local keepLow, keepHigh = low * math.min(1, fl), high * math.min(1, fl)
    local expLow = (1 - p) * bestLow + p * keepLow
    local expHigh = (1 - p) * bestHigh + p * keepHigh
    return bestLow, bestHigh, expLow, expHigh, "netProfit(riskAdjusted)"
end

-- 排序/带宽逻辑用的薄封装：返回**风险调整期望的 low/high** + 口径名 ✓
-- ★ 必须保持**三个返回值** ✗→✓：调用点写的是 `local lo, hi, basis = netProfit(x)` ✓，
--   本鱼第一版只返回两个 ✗ → 于是 `hi` 接到了口径**字符串** ✗ →
--   string.format 的 %d 拿到字符串 → "attempt to perform arithmetic on a string value" ✓✓
--   （离线自检当场抓到 ✓ —— 这就是要跑测试的价值 ✓）
local function netProfit(c)
    local _bl, _bh, expLow, expHigh, basis = profitModel(c)
    return expLow, expHigh, basis
end

local function basisRank(c)
    local b = c.profitBasis
    return (type(b) == "string" and string.sub(b, 1, 9) == "netProfit") and 1 or 0
end

-- 风险：未知概率按**最差**参与排序（9 ✓）；但**闸门**对未知是放行的 ✓
-- （与 lib/copilot/trade.lua 里 `chance == nil or chance <= maxChance` 一致 ✓✓）
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
    -- ★ netProfitLow/High = **风险调整期望**（排序主键 ✓）；bestCaseLow/High = 最好情况（标注 ✓）
    local bl, bh, el, eh, basis = profitModel(cand)
    cand.bestCaseLow, cand.bestCaseHigh = bl, bh
    cand.netProfitLow, cand.netProfitHigh, cand.profitBasis = el, eh, basis
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
        local bl, bh, el, eh, basis = profitModel(rec.best)
        rec.bestCaseLow, rec.bestCaseHigh = bl, bh
        rec.bestNetLow, rec.bestNetHigh, rec.bestBasis = el, eh, basis
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
            bestCaseLow = rec.bestCaseLow,
            bestCaseHigh = rec.bestCaseHigh,
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

    local Trade = include("copilot/trade")
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
    local baseX, baseY = shipX, shipY
    if tonumber(data.x) ~= nil and tonumber(data.y) ~= nil then
        baseX, baseY = math.floor(tonumber(data.x)), math.floor(tonumber(data.y))
    end

    -- ★ 共用 helper（见文件上方 collectAreaList ✓）—— tradePlan / jobPlan 同一套含船约束 ✓✓
    local areaList, dropped, usedShipCentre, areaBaseX, areaBaseY =
        collectAreaList(used, size, baseX, baseY, shipX, shipY)
    baseX, baseY = areaBaseX, areaBaseY
    if #areaList == 0 then
        return false, "NO_AREAS", "no candidate area contains the ship"
    end

    -- 货舱剩余空间（预付金要用 ✓ —— 与 lib/copilot/card 用的是同一套已验证 API ✓）
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
    -- ★★ rec.index 必须在**重排之后**重编一遍 ✓✓
    --   病因：index 原来是**扫描时**编的 ✗，而 `rankAreasByNet` 会把 scanned **原地重排** ✗ →
    --   下面 `scanned[top.areaIndex]` 就会指到**另一个区域** ✓（推荐里的区域框/坐标全错 ✗）。
    --   这是 jobPlan 的 S1b 自检**当场抓到**的同一个坑 ✓ —— trade 这里是同一个隐患，一并修 ✓✓
    --   （另一个更彻底的做法：把区域的几何**直接挂到候选上**，见 jobPlan 的 pool 段 ✓）
    for i, rec in ipairs(scanned) do rec.index = i end
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
            bestCaseLow = profitModel(top),
            bestCaseHigh = select(2, profitModel(top)),
            attackNote = "被伏击 = 强制召回：被中断那一班**不计利润** ✗，已飞完的班次照算 ✓，"
                .. "货会留在船上（靠 Sell 变现 ✓）—— 所以 netProfit* 是**风险调整后的期望** ✓，"
                .. "bestCase* 才是最好情况 ✓（原版 tradecommand.lua:450-506 / :124-147 ✓）",
            profitPerSize = top.profitPerSize,
            flights = top.flights,
            flightTime = top.flightTime,
            maxAvailable = top.maxAvailable,
            transportedPerFlight = top.transportedPerFlight,
            from = top.from,
            to = top.to,
        }
        recommendation.reason = string.format(
            "净收益**期望** C%d~%d（★ 风险调整后 ✓，口径 %s；最好情况 C%d~%d）／航班 %s 次；伏击概率 %s ≤ %.0f%%；区域偏移 (%+d,%+d)；商品「%s」；预付金 %d；护航 %s",
            math.floor((lo or 0) + 0.5), math.floor((hi or 0) + 0.5), tostring(basis),
            math.floor((recommendation.bestCaseLow or 0) + 0.5),
            math.floor((recommendation.bestCaseHigh or 0) + 0.5),
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

    -- ★ ④ 纯函数决策（lib/copilot/trade.lua ✓ —— 有离线自检 ✓✓）
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
    -- 修法：把 DSH 传来的**护航候选**代入 ✓（判据见上：一跳航程 ✓，不要求同星系 ✓）：
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
        local _bl2, _bh2, lo, hi, basis = profitModel(b)
        plan.bestCaseLow, plan.bestCaseHigh = _bl2, _bh2
        plan.config.goodName = b.name
        plan.config.deposit = b.deposit
        plan.config.escorts = b.escortsForGate or {}
        plan.netProfitLow, plan.netProfitHigh, plan.profitBasis = lo, hi, basis
        plan.attackChance = tonumber(b.attackChanceEffective)
        plan.reason = tostring(plan.reason) .. string.format(
            "  ★ 按主人钦定的**净收益**口径重排：本区域最优是「%s」（净收益**期望** C%d~%d，风险调整 ✓；最好情况 C%d~%d；伏击概率 %s）",
            tostring(b.name), math.floor(lo + 0.5), math.floor(hi + 0.5),
            math.floor((_bl2 or 0) + 0.5), math.floor((_bh2 or 0) + 0.5),
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
        notes[#notes + 1] = string.format("推荐「%s」净收益**期望** C%d~%d（风险调整 ✓；最好情况 C%d~%d），伏击概率 %s ≤ %.0f%%",
            tostring(recommendation.goodName),
            math.floor((recommendation.netProfitLow or 0) + 0.5),
            math.floor((recommendation.netProfitHigh or 0) + 0.5),
            math.floor((recommendation.bestCaseLow or 0) + 0.5),
            math.floor((recommendation.bestCaseHigh or 0) + 0.5),
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

-- ===========================================================================
-- ★★★ jobPlan：Mine / Salvage 的「多区域 × 参数（时长/安全模式/护航）× 层级加权」规划
-- ===========================================================================
--
-- 主人的钦定目标（2026-10-17，**原文照抄** ✓✓）：
--    「采矿应该尽可能采高级矿，而废弃物则应尽可能地收集高科技等级的舰船装备与插件，
--      两者都需要在合理的风险下。」
--
-- 与 tradePlan **同构**（同一套多区域扫描 ✓ + 同一道风险闸门 ✓ + 同一套 orderHint ✓），
-- 只有"价值"的定义不同：
--   Mine    : Σ_i 期望产量_i × 层级权重_i          ← 产量取自原版 calculatePrediction 的
--                                                   results.yields（★ 里面已经算过"这船挖得动哪些材料" ✓）
--             ★ **不是吨位** ✗ —— 吨位大但低阶的区会被高阶区压过去 ✓✓
--   Salvage : 装备件数 × E[稀有度层级]              ← results.items（★ 战利品是主角，废铁不是 ✓）
--             次级键 = 残骸场材料层级均值 fieldTier（★ 只作次级键，明说 ✓）
--   风险闸门：attackChance ≤ maxAttackChance（默认 0.10 ✓）**是硬线** ✗ ——
--     一个档位都不达标 → recommendation = nil + riskWarning（**明说**不推荐 ✓），绝不偷偷挑 ✓✓
--
-- 参数维度（= 原版窗口里能调的那几样 ✓ —— 证据 minecommand.lua:510-529 / salvagecommand.lua:588-607）：
--   duration —— 区间来自原版 `getConfigurableValues().duration.from/to` ✓（**绝不自己编 0.5/2** ✗）
--   safeMode —— ★ 原版会拿它去改伏击概率（×0.1；<0.1 直接归 0 ✓）：
--               证据 minecommand.lua:843-847 / salvagecommand.lua:967-971 →
--                    simulationutility.lua:866-868 `attackProbability = attackChanceModification(...)` ✓
--               → 这是**风险救援牌**（与 trade 的护航同位 ✓）；代价是只统计安全星区 → 产量下降 ✓
--   escorts  —— 与 trade 一致：只给过不了闸门的档位补算一次带护航的预测 ✓
--               （原版按护航强度降基础风险 ✓；★ 且 Mine/Salvage 的护航会**把自己那份产量加进来** ✓
--                 —— minecommand.lua:1121-1134 / salvagecommand.lua:1294-1300 ✓）
--
-- ★ 只在「默认档 / 最长档**都过不了闸门**」时才补算救援档（shortest / safeMode / escorts）✓
--   —— 与 trade 的"只给过不了闸门的路线补算护航"完全同一个取舍 ✓✓

-- 参数档的中文说明（进返回值，人能看懂 ✓）
local JOB_PARAM_TAG = {
    default  = "默认档（duration 用原版默认 1 小时 / 非安全模式）",
    longest  = "最长时长档（原版允许的 duration 上限 ✓：产量最高、风险也最高）",
    shortest = "最短时长档（原版允许的 duration 下限 ✓：风险最低、产量也最低）",
    safeMode = "安全模式档（★ 原版把伏击概率 ×0.1 ✓，代价是只统计安全星区 → 产量下降）",
    escorts  = "护航档（★ 原版判据：一跳航程内即可护航：降风险，且护航自己也出产量 ✓）",
}

-- 材料表：★ 只用**已核实**的三样东西（NumMaterials / Material / goods ✓），绝不发明 API ✗
--
-- 证据（逐行可查 ✓）：
--   * `NumMaterials()` / `Material(i-1).name` —— 原版自己就是这么列举材料的 ✓
--     minecommand.lua:531-543（getPredictableValues 里 `for i = 1, NumMaterials() do Material(i - 1)` ✓）
--   * `Material(i-1).costFactor` —— 原版**材料价值因子**（Documentation/Material.html 的
--     costFactor 属性 ✓）；原版两处实锤用法：
--         salvagecommand.lua:832  `credits = resourcesPerWreckage * Material(material - 1).costFactor * 0.1`
--         insurance.lua:329       `sum = sum + Material(i - 1).costFactor * v * 10`
--     → 它就是"1 单位这种材料值多少钱"的原版口径 ✓✓（绝对倍数无所谓，本鱼只用它排序 ✓）
--   * 矿物商品基准价 `goods["<材料名> Ore"].price` —— 原版数据文件 goodsindex.lua ✓：
--         Iron Ore=2 / Titanium Ore=3 / Naonite Ore=4 / Trinium Ore=5 /
--         Xanion Ore=7 / Ogonite Ore=9 / Avorion Ore=12 ✓
--
-- ⚠️★★ 本鱼**没有找到**任何"矿石层级 / 每材料售价"的**索引型 API** ✗（没有 OreTier 之类别名）——
--    所以下面只**读**上面那三样；三样都读不到时退回"材料层级 index"，并**在 scoreBasis 里明说** ✓✓
--    （这是本文件里唯一"像权重"的东西，它的来源与口径都写在返回值里，能被审计 ✓）
local function jobMaterialTable(goodsLib)
    local n = 0
    local okN = pcall(function() n = math.floor(tonumber(NumMaterials()) or 0) end)
    if not okN or n <= 0 then n = 7 end        -- 兜底：Iron..Avorion 共 7 种 ✓（MaterialType 枚举 ✓）
    local list = {}
    for i = 1, n do
        local rec = { index = i, materialType = i - 1, name = "Material " .. tostring(i - 1) }
        pcall(function()
            local m = Material(i - 1)
            rec.name = tostring(m.name)
            rec.costFactor = tonumber(m.costFactor)
        end)
        if type(goodsLib) == "table" then
            local okG, g = pcall(function() return goodsLib[rec.name .. " Ore"] end)
            if okG and type(g) == "table" then rec.orePrice = tonumber(g.price) end
        end
        list[i] = rec
    end
    return list, n
end

-- 层级权重：显式覆盖 > 原版 costFactor > 矿物商品价 > 材料层级 index ✓
-- ★ 每一条都先查**单调不降**（主人的目标是"越高阶越好" ✓）—— 不单调的口径一律不用 ✗，
--   免得悄悄给出反向排序 ✓✓
-- 返回：weights, scoreBasis, source ✓
local function jobTierWeights(Job, matList, n, requested)
    if type(requested) == "table" then
        local w, ok = {}, true
        for i = 1, n do
            local v = tonumber(requested[i])
            if v == nil or v <= 0 then ok = false break end
            w[i] = v
        end
        if ok and n > 0 and Job.isNonDecreasing(w, n) then
            return w, "Σ 期望产量 × data.tierWeights（调用方显式给定的层级权重 ✓）", "explicit"
        end
    end

    -- ① 原版材料价值因子 ✓
    do
        local w, ok = {}, true
        for i = 1, n do
            local v = matList[i] and matList[i].costFactor
            if v == nil or v <= 0 then ok = false break end
            w[i] = v
        end
        if ok and Job.isNonDecreasing(w, n) then
            return w,
                "Σ 期望产量 × Material(i-1).costFactor（原版材料价值因子；salvagecommand.lua:832 / insurance.lua:329 同源 ✓）",
                "costFactor"
        end
    end

    -- ② 原版矿物商品基准价 ✓（比 costFactor 平缓得多 —— 所以口径必须写明 ✓）
    do
        local w, ok = {}, true
        for i = 1, n do
            local v = matList[i] and matList[i].orePrice
            if v == nil or v <= 0 then ok = false break end
            w[i] = v
        end
        if ok and Job.isNonDecreasing(w, n) then
            return w,
                "Σ 期望产量 × 矿物商品基准价 goods[\"<材料> Ore\"].price（goodsindex.lua ✓；比 costFactor 平缓）",
                "orePrice"
        end
    end

    -- ③ ★ 兜底：材料**层级 index**（Iron=1 … Avorion=7 ✓）—— 口径**明说** ✓✓
    local w = {}
    for i = 1, n do w[i] = i end
    return w,
        "Σ 期望产量 × 材料层级 index（★ 原版**没有**公开的'每材料价格/层级'API ✗ → 退回 MaterialType 顺序 Iron=1…Avorion=7 ✓）",
        "tierIndex"
end

-- 原版 duration 合法区间（★ 从命令自己问 ✓）＋ 参数网格 ✓
local function jobParamGrid(command, player, ship, data, escorts)
    local from, to = 0.5, 2          -- 拿不到 values 时的兜底 = 原版写死的默认区间 ✓
    local okV = pcall(function()
        local v = command:getConfigurableValues(player.index, ship)
        if type(v) == "table" and type(v.duration) == "table" then
            local a, b = tonumber(v.duration.from), tonumber(v.duration.to)
            if a ~= nil and a > 0 then from = a end
            if b ~= nil and b > 0 then to = b end
        end
    end)
    if to < from then to = from end

    local want = tonumber(data and data.duration)
    local d0 = (want ~= nil and want > 0) and want or 1
    if d0 < from then d0 = from end
    if d0 > to then d0 = to end

    local list = { { tag = "default", duration = d0, safeMode = false } }
    if to > d0 + 1e-9 then
        list[#list + 1] = { tag = "longest", duration = to, safeMode = false }
    end
    if from < d0 - 1e-9 then
        list[#list + 1] = { tag = "shortest", duration = from, safeMode = false, rescue = true }
    end
    list[#list + 1] = { tag = "safeMode", duration = d0, safeMode = true, rescue = true }
    if type(escorts) == "table" and #escorts > 0 then
        list[#list + 1] = {
            tag = "escorts", duration = d0, safeMode = false,
            escorts = escorts, rescue = true,
        }
    end
    return list, { from = from, to = to, default = d0, okValues = okV }
end

-- 扫**一个**区域：分析（pcall ✓）+ 逐个参数档算预测（pcall ✓）＋ 评分 ✓
-- ★ 任何一步失败都只写进 rec.error / cand.predictionFailed，**绝不中断整轮扫描** ✓✓
local function scanJobArea(command, Job, player, ship, ctype, area, params, opts)
    local rec = { area = area, offset = { x = 0, y = 0 }, candidates = {}, acceptable = false }

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

    rec.results = results
    -- ★★ 必须把分析结果**挂回 area** 上 ✓（否则 calculatePrediction 一进去就
    --    "attempt to index field 'analysis' (a nil value)" ✓✓ —— tradePlan 同款处理 ✓）
    rec.area.analysis = results

    rec.areaStats = {
        sectors = results.sectors, reachable = results.reachable,
        unreachable = results.unreachable,
        biggestFactionInArea = results.biggestFactionInArea,
        safeSectorCount = (type(results.safeSectors) == "table") and #results.safeSectors or nil,
        asteroids = results.asteroids, wrecks = results.wrecks,
        volume = results.volume,
    }
    rec.areaMaterials = {}
    for i = 1, opts.nMaterials do
        rec.areaMaterials[i] = {
            index = i, name = opts.matNames[i], materialType = i - 1,
            weight = opts.weights[i],
            probability = tonumber(type(results.materials) == "table" and results.materials[i]) or 0,
        }
    end
    rec.fieldTier = Job.fieldTier(results.materials, opts.nMaterials)

    local function evaluate(p)
        local cfg = {
            duration = p.duration,
            safeMode = p.safeMode == true,
            collected = opts.collected,
            escorts = p.escorts or {},
        }
        local cand = {
            tag = p.tag, tagNote = JOB_PARAM_TAG[p.tag], label = p.tag,
            duration = p.duration, safeMode = cfg.safeMode, escorts = cfg.escorts,
            pValue = -1, sValue = -1, acceptable = false, scoreBasis = opts.scoreBasis,
        }
        local okP, pred = pcall(function()
            return command:calculatePrediction(player.index, ship, rec.area, cfg)
        end)
        if not okP or type(pred) ~= "table" then
            cand.predictionFailed = tostring(pred)
            rec.candidates[#rec.candidates + 1] = cand
            return cand
        end

        cand.attackChance = pred.attackChance and tonumber(pred.attackChance.value) or nil
        cand.chance = cand.attackChance
        if pred.error ~= nil then cand.error = tostring(pred.error) end

        if opts.action == "Mine" then
            local low, high, topTier, per = Job.mineValue(pred.yields, opts.weights)
            for i = 1, #per do per[i].name = opts.matNames[per[i].index] end
            cand.valueLow, cand.valueHigh = low, high
            cand.topTier, cand.topMaterial = topTier, opts.matNames[topTier]
            cand.materials = per
            cand.pValue, cand.sValue = low, topTier          -- ★ 主键=层级加权价值；次键=最高矿层级 ✓
        else
            local low, high, itemsFrom, itemsTo, rarityTier = Job.salvageValue(pred.items, opts.rarityTier)
            local sLow, sHigh, sTop, sPer = Job.mineValue(pred.yields, opts.weights)
            for i = 1, #sPer do sPer[i].name = opts.matNames[sPer[i].index] end
            cand.valueLow, cand.valueHigh = low, high
            cand.items = { from = itemsFrom, to = itemsTo }
            cand.rarityTier = rarityTier
            cand.scrapLow, cand.scrapHigh = sLow, sHigh    -- 废铁价值（**只作审计/冷门参考** ✓，主人说战利品才是主角 ✓）
            cand.scrapMaterials = sPer
            cand.pValue, cand.sValue = low, (rec.fieldTier or -1)   -- ★ 次键=残骸场层级均值 ✓（明说它是代理 ✓）
        end

        -- ★★ 达标判定（两条，缺一不可 ✓✓）：
        --   ① **要有产出** —— 产出为 0 的档位**不算可用候选** ✗
        --      原版自己在没产出时也会给 error（"This mining operation won't yield any resources!"
        --      / "There are no sectors to salvage in in this area!" ✓），
        --      但那是 error 不是 "推荐" ✓ —— 不把"啥也采不到的区域"当成合法答案，
        --      否则**空产出 + 0% 风险**会一路排到最前面 ✗✓（自检 M3 / S1b 当场抓到过 ✓）
        --   ② 风险：**未知风险放行** ✓（与 lib/copilot/trade 的 `chance == nil or <= max` 一致 ✓）
        local hasOutput = (tonumber(cand.valueHigh) or 0) > 0
        cand.hasOutput = hasOutput
        if not hasOutput then cand.noOutput = true end
        cand.acceptable = hasOutput and (cand.chance == nil or cand.chance <= opts.gate)
        cand.label = p.tag
        rec.candidates[#rec.candidates + 1] = cand
        return cand
    end

    -- ① 正常档：default（+ longest）✓
    for _, p in ipairs(params) do
        if not p.rescue then evaluate(p) end
    end
    -- ② 救援档：**只有正常档一个都没达标**时才补算 ✓✓（safeMode / shortest / escorts ✓）
    local anyOK = false
    for _, c in ipairs(rec.candidates) do
        if c.acceptable then anyOK = true break end
    end
    if not anyOK then
        for _, p in ipairs(params) do
            if p.rescue then evaluate(p) end
        end
    end

    local pass, all = {}, {}
    for _, c in ipairs(rec.candidates) do
        all[#all + 1] = c
        if c.acceptable then pass[#pass + 1] = c end
    end
    Job.rankCandidates(pass, nil, { band = opts.band })
    Job.rankCandidates(all, nil, { band = opts.band })
    rec.acceptable = (#pass > 0)
    rec.best = pass[1] or all[1]
    rec.candidatesRanked = all
    if rec.best ~= nil then
        rec.bestValue = rec.best.valueLow
        rec.bestValueHigh = rec.best.valueHigh
        rec.bestChance = rec.best.chance
        rec.bestTag = rec.best.tag
        rec.bestTopTier = rec.best.topTier
        if rec.best.predictionFailed ~= nil then rec.error = "prediction failed: " .. tostring(rec.best.predictionFailed) end
        if rec.best.error ~= nil then rec.error = "prediction says: " .. tostring(rec.best.error) end
    end
    return rec
end

-- 区域排序 ✓：达标的在前 ✓；按该区域最优档的**层级加权价值**降序 ✓；带宽内风险优先 ✓
local function rankJobAreas(recs, band)
    table.sort(recs, function(a, b)
        if a.acceptable ~= b.acceptable then return a.acceptable end
        local va, vb = tonumber(a.bestValue) or -1, tonumber(b.bestValue) or -1
        if va ~= vb then return va > vb end
        local ca, cb = tonumber(a.bestChance) or 9, tonumber(b.bestChance) or 9
        if ca ~= cb then return ca < cb end
        local fa, fb = tonumber(a.fieldTier) or -1, tonumber(b.fieldTier) or -1
        if fa ~= fb then return fa > fb end
        return tostring(a.bestTag) < tostring(b.bestTag)
    end)
    for i = 2, #recs do
        local j = i
        while j > 1 do
            local cur, prev = recs[j], recs[j - 1]
            if cur.acceptable ~= prev.acceptable then break end
            local vp, vc = tonumber(prev.bestValue), tonumber(cur.bestValue)
            if vp == nil or vc == nil or vp <= 0 then break end
            if vc < vp * (1 - band) then break end
            local cc, cp = tonumber(cur.bestChance) or 9, tonumber(prev.bestChance) or 9
            local swap = false
            if cc < cp - 1e-9 then
                swap = true
            elseif math.abs(cc - cp) <= 1e-9
                and (tonumber(cur.fieldTier) or -1) > (tonumber(prev.fieldTier) or -1) + 1e-9 then
                swap = true
            end
            if not swap then break end
            recs[j], recs[j - 1] = prev, cur
            j = j - 1
        end
    end
    return recs
end

-- 回传给 DSH 的区域榜（**裁掉**重字段 ✓：只剩标量 + 最优档的逐材料明细 ✓）
local function buildJobRanking(scanned, opts)
    local out = {}
    for _, rec in ipairs(scanned) do
        local a = rec.area
        local entry = {
            area = {
                lower = { x = a.lower.x, y = a.lower.y },
                upper = { x = a.upper.x, y = a.upper.y },
                offset = { x = rec.offset.x, y = rec.offset.y },
            },
            fieldTier = rec.fieldTier,
            bestTag = rec.bestTag,
            bestTagNote = rec.best and rec.best.tagNote or nil,
            valueLow = rec.bestValue,
            valueHigh = rec.bestValueHigh,
            attackChance = rec.bestChance,
            topTier = rec.bestTopTier,
            topMaterial = rec.best and rec.best.topMaterial or nil,
            acceptable = rec.acceptable,
            parameterTags = {},
            candidates = {},
        }
        if rec.best ~= nil then
            entry.duration = rec.best.duration
            entry.safeMode = rec.best.safeMode
            entry.escorts = rec.best.escorts
            entry.items = rec.best.items
            entry.scrapHigh = rec.best.scrapHigh
            entry.scoreBasis = rec.best.scoreBasis
        end
        for _, c in ipairs(rec.candidatesRanked or rec.candidates) do
            entry.parameterTags[#entry.parameterTags + 1] = string.format(
                "%s(duration=%s,safeMode=%s%s%s)",
                tostring(c.tag), tostring(c.duration), tostring(c.safeMode),
                (c.escorts and #c.escorts > 0) and (",escorts=" .. table.concat(c.escorts, ",")) or "",
                c.acceptable and ",ok" or ",over-gate")
        end
        local list = rec.candidatesRanked or rec.candidates
        local shown = {}
        for i = 1, math.min(SCAN_DETAIL, #list) do
            local c = list[i]
            local copy = {}
            for k, v in pairs(c) do
                if k ~= "materials" and k ~= "scrapMaterials" then copy[k] = v end
            end
            if c == rec.best and type(c.materials) == "table" then copy.materials = c.materials end
            shown[i] = copy
        end
        entry.candidates = shown
        local bs = rec.best
        if bs ~= nil and bs ~= list[1] and type(bs.materials) == "table" then
            -- 最优档若被裁掉，单独附上它的逐材料明细 ✓（人要看数 ✓）
            local copy = {}
            for k, v in pairs(bs) do
                if k ~= "scrapMaterials" then copy[k] = v end
            end
            entry.bestCandidate = copy
        end
        if rec.error ~= nil then entry.error = rec.error end
        out[#out + 1] = entry
    end
    return out
end

-- ===========================================================================
-- ★★★ sellPlan：把船上的货**变现**（Issue B ✓✓ 2026-10-17）
-- ===========================================================================
--
-- 为什么必须要有它 ✗→✓（主人的场景 ✓）：
--   原版 tradecommand.lua:450-506（`onRecall`）—— 被伏击强制召回时**只退押金** ✓
--   （:488 remainingDeposit = deposit − 货钱、:490 addYield），而被中断那一班的货
--   **留在船上** ✗（:460-464 entry:setCargo ✓），**利润是 0** ✓。
--   于是：船上有货时再下 Trade，货舱装不进新货 ✗ → **必须先 Sell 变现** ✓✓。
--
-- 原版 Sell 的关键事实（全部**实读**，不是猜 ✗）：
--   · CommandType.Sell = "6bf2d9af-255b-4108-a1e1-dc83ace49819"（commandtype.lua ✓）
--   · 区域：getAreaSize → {15,15}（sellcommand.lua:414-416 ✓）；isShipRequiredInArea → true（:430-432 ✓）
--   · config：`goodsToSell = { {goodName=…, amount=…, stolen=…} }`（:243、:326-343 ✓）
--   · 预测：calculatePrediction（:456 ✓）→ duration / **yield** / attackChance / pricesPerGood ✓
--   · 被伏击的结算（:152-159 onRecall ✓）：
--         只在 `runTime ≥ 11 分钟` **或** `runTime > duration × 0.8` 时才**部分卖** ✓
--         percentage = runTime / duration（:156 ✓）
--         而攻击时刻 = random(0.1, 0.75) × duration（:144 ✓）
--       → 期望 percentage ≈ (0.1+0.75)/2 = **0.425** ✓；若那一刻还没到 11 分钟 → **一点都不卖**（keep = 0 ✓✓）
--   · 货名：cargo 表的键是 good 对象，它的 `.name` 就是 goods 索引名 ✓
--       （transfercrewgoods.lua:881 `playerCargoName[i] = good.name` ✓、factory.lua:109 ✓）
--   · 空货舱 → 没有可卖的（getErrors :345 `No good to sell selected!` ✓）

function CopilotLinkIn.sellPlan(player, data)
    data = data or {}
    local ship = data.ship
    if type(ship) ~= "string" or ship == "" then
        return false, "BAD_REQUEST", "sellPlan needs data.ship"
    end
    if player == nil then return false, "NO_PLAYER", "no player object" end

    local startMs = os.clock()
    local gate = tonumber(data.maxAttackChance) or 0.10
    local _, Ship = nil, nil
    local Card = include("copilot/card")
    local card = Card.shipCard(player, ship)

    -- ① 船上有货吗？（没有 → **明说**"不用卖"，而不是编一个计划 ✗✓）
    local hold, herr, used = readHoldGoods(player, ship)
    if hold == nil then
        return false, "HOLD_UNREADABLE", tostring(herr)
    end
    if #hold == 0 then
        CopilotRpc.trace("sellPlan " .. ship .. "：货舱是空的 → 不需要卖 ✓")
        return true, {
            ship = ship, action = "Sell", routeCount = 0,
            goodsToSell = {}, holdUsed = 0,
            recommendation = nil,
            riskWarning = nil,
            note = "hold is empty — nothing to sell (sell is only needed when the hold has goods)",
            holdEmpty = true,
            orderHint = nil,
            areasScanned = 0, scanMs = 0,
        }
    end

    -- ② 区域：15x15、必须含船（与 Mine/Salvage/Trade 同一条硬约束 ✓）
    local ctype = COMMAND_TYPES.Sell
    local command = nil
    local okF, factory = pcall(function() return include("commandfactory") end)
    if okF then
        local okC, c = pcall(function() return factory.makeCommand(ctype) end)
        if okC then command = c end
    end
    if command == nil then
        return false, "NO_COMMAND", "cannot make a Sell command instance"
    end

    local templates = legalAreaSizes(command, player, ship)
    local size = pickSquareSize(templates, data.size)
    if size == nil or size <= 0 then size = DEFAULT_SIZE.Sell end

    local shipX, shipY = tonumber(data.x), tonumber(data.y)
    if shipX == nil or shipY == nil then
        local okPos, px, py = pcall(function() return player:getShipPosition(ship) end)
        if not okPos or px == nil then return false, "NO_POSITION", "cannot read ship position" end
        shipX, shipY = px, py
    end

    local half = math.floor((size - 1) / 2)
    local step = tonumber(data.step) or 4
    local offsets = scanOffsets(half, step)
    local maxAreas = tonumber(data.maxAreas) or 9
    local used_ = {}
    for i = 1, math.min(#offsets, maxAreas) do used_[#used_ + 1] = offsets[i] end
    if #used_ == 0 then used_[1] = { x = 0, y = 0 } end

    local areaList, dropped, usedShipCentre, baseX, baseY =
        collectAreaList(used_, size, shipX, shipY, shipX, shipY)

    -- ③ 逐区域：分析（pcall ✓）→ 预测（pcall ✓）
    local okInc = pcall(function() return include("areaanalysis") end)
    if not okInc or type(run) ~= "function" then
        return false, "NO_ANALYSIS_SCRIPT", "areaanalysis.lua did not define run()"
    end

    local config = { goodsToSell = hold }
    local scanned = {}
    local budgetMs = tonumber(data.maxScanMs) or 20000
    local stoppedEarly = false

    for _, item in ipairs(areaList) do
        local rec = { area = item.area, offset = item.offset, candidates = {}, acceptable = false }
        local okRun, _s, _ty, rArea, results = pcall(function()
            return run(player.index, ship, ctype, item.area, player.index)
        end)
        if not okRun or type(results) ~= "table" then
            rec.error = "analysis failed: " .. tostring(rArea)
        else
            rArea.analysis = results
            rec.analysis = results
            local okP, pred = pcall(function()
                return command:calculatePrediction(player.index, ship, rArea, config)
            end)
            if okP and type(pred) == "table" then
                local yLo, yHi = numericRange(pred.yield)
                local p = pred.attackChance and tonumber(pred.attackChance.value) or nil
                local dur = tonumber(pred.duration)
                local keep = attackKeepFraction(dur)
                local cand = {
                    name = "Sell",
                    goodsToSell = hold,
                    yieldLow = yLo, yieldHigh = yHi,
                    duration = dur,
                    attackChance = p,
                    keepFractionOnAttack = keep,
                    pricesPerGood = pred.pricesPerGood,
                    predictionError = pred.error,
                }
                if yLo ~= nil and p ~= nil then
                    -- ★ 风险调整期望（主人口径 ✓）：被伏击只能卖掉 keep 那部分 ✓
                    cand.netProfitLow = (1 - p) * yLo + p * (yLo * keep)
                    cand.netProfitHigh = (1 - p) * (yHi or yLo) + p * ((yHi or yLo) * keep)
                    cand.bestCaseLow, cand.bestCaseHigh = yLo, (yHi or yLo)
                    cand.profitBasis = "sellYield(riskAdjusted)"
                elseif yLo ~= nil then
                    cand.netProfitLow, cand.netProfitHigh = yLo, (yHi or yLo)
                    cand.bestCaseLow, cand.bestCaseHigh = yLo, (yHi or yLo)
                    cand.profitBasis = "sellYield(chance unknown -> unadjusted)"
                else
                    rec.error = "prediction gave no yield: " .. tostring(pred.error)
                end
                rec.candidates = { cand }
                rec.best = cand
                rec.acceptable = (cand.netProfitLow ~= nil) and (cand.attackChance == nil or cand.attackChance <= gate)
                rec.bestChance = cand.attackChance
                rec.bestDur = cand.duration
            else
                rec.error = "prediction failed: " .. tostring(pred)
            end
        end
        scanned[#scanned + 1] = rec
        if ((os.clock() - startMs) * 1000) > budgetMs then
            stoppedEarly = true
            break
        end
    end

    -- ④ 排序：达标的在前 ✓；按风险调整期望降序 ✓；风险低者优先 ✓
    table.sort(scanned, function(a, b)
        if a.acceptable ~= b.acceptable then return a.acceptable end
        local na = (a.best and a.best.netProfitLow) or -1
        local nb = (b.best and b.best.netProfitLow) or -1
        if na ~= nb then return na > nb end
        local ca = a.bestChance or 9
        local cb = b.bestChance or 9
        if ca ~= cb then return ca < cb end
        return tostring(a.offset.x) .. "," .. tostring(a.offset.y) < tostring(b.offset.x) .. "," .. tostring(b.offset.y)
    end)

    local recTop = nil
    for _, r in ipairs(scanned) do if r.acceptable then recTop = r break end end

    local areaRanking = {}
    for _, r in ipairs(scanned) do
        local b = r.best
        areaRanking[#areaRanking + 1] = {
            area = { lower = { x = r.area.lower.x, y = r.area.lower.y },
                     upper = { x = r.area.upper.x, y = r.area.upper.y },
                     offset = { x = r.offset.x, y = r.offset.y } },
            routeCount = r.best and 1 or 0,
            bestRouteName = r.best and "Sell" or nil,
            netProfitLow = b and b.netProfitLow or nil,
            netProfitHigh = b and b.netProfitHigh or nil,
            netProfitBasis = b and b.profitBasis or nil,
            bestCaseLow = b and b.bestCaseLow or nil,
            bestCaseHigh = b and b.bestCaseHigh or nil,
            attackChance = b and b.attackChance or nil,
            duration = b and b.duration or nil,
            keepFractionOnAttack = b and b.keepFractionOnAttack or nil,
            acceptable = r.acceptable,
            error = r.error,
        }
    end

    local recommendation, riskWarning = nil, nil
    if recTop ~= nil then
        local b = recTop.best
        recommendation = {
            area = { lower = { x = recTop.area.lower.x, y = recTop.area.lower.y },
                     upper = { x = recTop.area.upper.x, y = recTop.area.upper.y },
                     offset = { x = recTop.offset.x, y = recTop.offset.y } },
            x = baseX + recTop.offset.x, y = baseY + recTop.offset.y, size = size,
            action = "Sell",
            goodsToSell = hold,
            holdUsed = used,
            duration = b.duration,
            attackChance = b.attackChance,
            maxAttackChance = gate,
            netProfitLow = b.netProfitLow, netProfitHigh = b.netProfitHigh,
            bestCaseLow = b.bestCaseLow, bestCaseHigh = b.bestCaseHigh,
            profitBasis = b.profitBasis,
            keepFractionOnAttack = b.keepFractionOnAttack,
            attackNote = "被伏击 = 强制召回：**没卖完的货还在船上** ✓，而且只有"
                .. "跑够 11 分钟（或超过时长的 80%）才开始卖 ✓ —— 未到就**一点也卖不掉** ✓"
                .. "（原版 sellcommand.lua:152-159 / :235-291 ✓）。所以 netProfit* 是风险调整期望 ✓，"
                .. "bestCase* 才是最好情况 ✓。",
        }
        recommendation.reason = string.format(
            "卖货：本金期望 C%d~%d（风险调整 ✓，口径 %s；最好情况 C%d~%d）／时长 %s 秒；"
                .. "伏击概率 %s ≤ %.0f%%；区域偏移 (%+d,%+d)；卖 %d 单位 / %d 种货 ✓",
            math.floor((b.netProfitLow or 0) + 0.5), math.floor((b.netProfitHigh or 0) + 0.5),
            tostring(b.profitBasis),
            math.floor((b.bestCaseLow or 0) + 0.5), math.floor((b.bestCaseHigh or 0) + 0.5),
            tostring(b.duration),
            b.attackChance and string.format("%.1f%%", b.attackChance * 100) or "未知",
            gate * 100, recTop.offset.x, recTop.offset.y, math.floor(used), #hold)
    else
        local bestAny = scanned[1]
        riskWarning = string.format(
            "本鱼**不推荐**现在卖货 ✗：扫了 %d 个区域，没有一档满足伏击概率 ≤ %.0f%% ✓",
            #scanned, gate * 100)
        if bestAny ~= nil and bestAny.best ~= nil then
            riskWarning = riskWarning .. string.format("（最好的那档伏击概率 %s）",
                bestAny.best.attackChance and string.format("%.1f%%", bestAny.best.attackChance * 100) or "未知")
        end
    end

    local scanMs = math.floor(((os.clock() - startMs) * 1000) + 0.5)
    local notes = {
        "plan only — nothing was issued (order is a separate call)",
        string.format("多区域扫描：%d 个区域 / 步长 %d / 共 %d ms", #scanned, step, scanMs),
        string.format("船上有货：%d 单位 / %d 种 ✓（卖完货舱才空 ✓）", math.floor(used), #hold),
    }
    if dropped > 0 then
        notes[#notes + 1] = string.format("其中 %d 个候选区域含不住船的星区（已跳过 ✓）", dropped)
    end
    if usedShipCentre then
        notes[#notes + 1] = string.format("给的 x,y 周围没有能含住船的合法区域 → 改以船所在星区 (%d,%d) 为中心", shipX, shipY)
    end
    if stoppedEarly then
        notes[#notes + 1] = string.format("扫描提前结束：已用 %d ms > 预算 %d ms", scanMs, budgetMs)
    end
    if recommendation ~= nil then
        notes[#notes + 1] = string.format("推荐卖货：期望 C%d~%d（风险调整 ✓），伏击概率 %s",
            math.floor((recommendation.netProfitLow or 0) + 0.5),
            math.floor((recommendation.netProfitHigh or 0) + 0.5),
            recommendation.attackChance and string.format("%.1f%%", recommendation.attackChance * 100) or "未知")
    elseif riskWarning ~= nil then
        notes[#notes + 1] = riskWarning
    end

    CopilotRpc.trace(string.format("sellPlan %s 货物=%d 单位/%d 种 扫描=%d区域/%dms 推荐=%s",
        ship, math.floor(used), #hold, #scanned, scanMs,
        recommendation and "有" or "无"))

    local orderHint = nil
    if recommendation ~= nil then
        orderHint = {
            ship = ship, action = "Sell",
            x = recommendation.x, y = recommendation.y, size = size,
            goodsToSell = hold,
            duration = recommendation.duration,
            note = "把船上的货卖掉 ✓；x/y 是绝对星区坐标、区域 15x15 且已保证包含船 ✓",
        }
    end

    return true, {
        ship = ship, action = "Sell",
        area = recTop and recTop.area or (areaList[1] and areaList[1].area),
        size = size,
        goodsToSell = hold, holdUsed = used, holdKinds = #hold,
        routeCount = #hold,
        candidates = recTop and recTop.candidates or {},
        recommendation = recommendation,
        riskWarning = riskWarning,
        orderHint = orderHint,
        areaRanking = areaRanking,
        areasScanned = #scanned,
        scanMs = scanMs,
        scanNote = notes[2],
        note = table.concat(notes, "；"),
        cap = card and card.cargoCapacity or nil,
        scan = { size = size, step = step, maxAreas = maxAreas, gate = gate,
                 duration = nil, objective = "把船上的货在 ≤10% 伏击风险下变现（风险调整 ✓）" },
    }
end
function CopilotLinkIn.jobPlan(player, data, action)
    local t0 = os.clock()
    local ship = data and data.ship
    if type(ship) ~= "string" or ship == "" then
        return false, "BAD_REQUEST", "jobPlan needs data.ship"
    end
    action = action or (data and data.action) or "Mine"
    if action ~= "Mine" and action ~= "Salvage" then
        return false, "BAD_ACTION",
            "jobPlan supports Mine / Salvage (got " .. tostring(action) .. ")"
    end
    local ctype = COMMAND_TYPES[action]
    if ctype == nil then return false, "BAD_ACTION", "no command type for " .. tostring(action) end
    if player == nil then return false, "NO_PLAYER", "no player object" end

    local Job = include("copilot/job")
    if type(Job) ~= "table" then return false, "NO_LIB", "copilot/job did not load" end

    -- ★ ① 船在哪 —— 所有候选区域**必须含船** ✓✓（原版硬约束，见 collectAreaList ✓）
    local okPos, px, py = pcall(function() return player:getShipPosition(ship) end)
    if not okPos or tonumber(px) == nil or tonumber(py) == nil then
        return false, "NO_POSITION", "cannot read ship position for " .. ship .. "; pass x,y"
    end
    local shipX, shipY = math.floor(tonumber(px)), math.floor(tonumber(py))

    -- ★ ② 自己跑区域分析（**同步** ✓ —— areaanalysis.lua 末尾直接 return ✓）
    --   ⚠️ `include("areaanalysis")` 返回 **nil** ✗（它是引擎脚本，只定义**全局 run** ✓）；
    --   ⚠️ `pcall` 会在最前面**多返回一个 true** ✗ → 解构必须整体后移一格 ✓✓
    local okInc, incErr = pcall(function() return include("areaanalysis") end)
    if not okInc then return false, "NO_ANALYSIS_SCRIPT", tostring(incErr) end
    if type(run) ~= "function" then
        return false, "NO_ANALYSIS_RUN", "areaanalysis.lua did not define a global run()"
    end

    -- ★ ③ 命令实例：问合法区域尺寸 / duration 区间 / 算预测 ✓
    local okF, factory = pcall(function() return include("commandfactory") end)
    if not okF or type(factory) ~= "table" then
        return false, "NO_COMMAND_FACTORY", tostring(factory)
    end
    local okCmd, command = pcall(function() return factory.makeCommand(ctype) end)
    if not okCmd or command == nil then return false, "NO_COMMAND", tostring(command) end

    local okGoods, goodsLib = pcall(function() return include("goods") end)
    if not okGoods then goodsLib = nil end

    -- ★ ④ 尺寸：合法尺寸**只从命令问** ✓（Mine/Salvage 原版都是 15x15 ✓，
    --   证据 minecommand.lua:494-496 / salvagecommand.lua:572-574 ✓）—— 绝不自己编 ✗
    local templates = legalAreaSizes(command, player, ship)
    local reqSize = tonumber(data and data.size)
    local fallback = DEFAULT_SIZE[action] or 15
    local size
    if reqSize ~= nil then
        size = pickSquareSize(templates, reqSize)      -- 非法尺寸 → 原版第一个合法正方形 ✓
    else
        size = pickSquareSize(templates, fallback)     -- 默认 = 该命令的默认边长 ✓
    end
    local sizeAdjusted = (reqSize ~= nil and reqSize ~= size)
    local half = math.floor((size - 1) / 2)

    local step = math.floor(tonumber(data and data.step) or SCAN_STEP)
    if step < 1 then step = 1 end
    local maxAreas = math.floor(tonumber(data and data.maxAreas) or SCAN_MAX_AREAS)
    if maxAreas < 1 then maxAreas = 1 end
    if maxAreas > 25 then maxAreas = 25 end
    local budgetMs = math.floor(tonumber(data and data.maxScanMs) or SCAN_BUDGET_MS)
    if budgetMs < 0 then budgetMs = 0 end
    local gate = tonumber(data and data.maxAttackChance) or Job.MAX_ATTACK_CHANCE

    local offsets = scanOffsets(half, step)
    local used = {}
    for i = 1, #offsets do
        if #used >= maxAreas then break end
        used[#used + 1] = offsets[i]
    end

    local baseX, baseY = shipX, shipY
    if tonumber(data and data.x) ~= nil and tonumber(data and data.y) ~= nil then
        baseX, baseY = math.floor(tonumber(data.x)), math.floor(tonumber(data.y))
    end
    local areaList, dropped, usedShipCentre, areaBaseX, areaBaseY =
        collectAreaList(used, size, baseX, baseY, shipX, shipY)
    baseX, baseY = areaBaseX, areaBaseY
    if #areaList == 0 then
        return false, "NO_AREAS", "no candidate area contains the ship"
    end

    -- ★ ⑤ 层级权重（口径写进 scoreBasis ✓）+ 材料表 ✓
    local matList, nMaterials = jobMaterialTable(goodsLib)
    local matNames = {}
    for i = 1, nMaterials do matNames[i] = matList[i].name end
    local weights, scoreBasis, weightSource = jobTierWeights(Job, matList, nMaterials,
        data and data.tierWeights)

    -- ★ ⑥ 稀有度层级（Salvage 用 ✓）：先试原版 `Rarity(v).value`，读不到就用枚举序号 ✓
    local rarityTierOf, rarityTierFrom = nil, "RarityType 枚举序号（Petty=0 … Exceptional=4 ✓）"
    do
        local okR, tierOf = pcall(function()
            local t = {}
            for _, r in ipairs(Job.RARITY_MIX) do
                t[r.name] = tonumber(Rarity(r.type).value)
            end
            return t
        end)
        if okR and type(tierOf) == "table" then
            rarityTierOf = tierOf
            rarityTierFrom = "Rarity(v).value（原版稀有度对象 ✓）"
        end
    end
    local rarityTier = Job.expectedRarityTier(rarityTierOf)

    -- ★ scoreBasis：**排序真正用的口径**必须写在返回值里 ✓✓
    --   Mine    → 就是材料层级加权价值 ✓
    --   Salvage → **战利品口径**为主（装备件数 × E[稀有度层级]），材料加权只用于审计废铁 ✓
    --             —— 主人的原话："废弃物则应尽可能地收集高科技等级的舰船装备与插件" ✓
    local scoreBasisEff = scoreBasis
    local lootBasis = nil
    if action == "Salvage" then
        lootBasis = string.format(
            "主键 = 装备件数(prediction.items) × E[稀有度层级] = %.3f（混合表：%s；层级取自 %s ✓）；" ..
            "次键 = 残骸场材料层级均值 fieldTier（★ 只是**代理指标**，见 copilot/job.lua 的说明 ✓）；" ..
            "废铁价值口径 = %s（**只作审计** ✓ —— 主人说战利品才是主角 ✓）",
            rarityTier, Job.RARITY_MIX_SOURCE, rarityTierFrom, scoreBasis)
        scoreBasisEff = lootBasis
    end

    -- ★ ⑦ 参数网格（duration 区间来自原版 ✓）
    local escorts = {}
    if type(data) == "table" and type(data.escorts) == "table" then
        for _, n2 in ipairs(data.escorts) do
            if type(n2) == "string" and n2 ~= "" then escorts[#escorts + 1] = n2 end
        end
    end
    local params, durs = jobParamGrid(command, player, ship, data, escorts)

    -- ★ ⑧ 命令自己的"能不能挖得动"（getMiningProperties / getSalvagingProperties ✓）
    --   —— 这是**权威的"这艘船到底能采什么"** ✓（原版预测内部也是用它 ✓）
    local capability = nil
    do
        local okC, props = pcall(function()
            if action == "Mine" then return command:getMiningProperties(player.index, ship) end
            return command:getSalvagingProperties(player.index, ship)
        end)
        if okC and type(props) == "table" then
            capability = { source = (action == "Mine") and "MineCommand:getMiningProperties" or "SalvageCommand:getSalvagingProperties", materials = {} }
            for i = 1, nMaterials do
                local mp = props.materials and props.materials[i]
                capability.materials[i] = {
                    index = i, name = matNames[i], materialType = i - 1,
                    dps = mp and tonumber(mp.dps) or 0,
                    canMine = (mp and tonumber(mp.dps) or 0) > 0,
                }
            end
            capability.rawMining = props.rawMining or props.rawSalvaging or nil
            capability.refinedMining = props.refinedMining or props.refinedSalvaging or nil
            capability.cargoSpace = props.cargoSpace
            capability.turretSlotsFulfilled = props.turretSlotsFulfilled
        end
    end

    -- ★ ⑨ collected（★ 命令**必须**有它 ✗：minecommand.lua:964 / salvagecommand.lua:1116
    --    会 `config.collected[material - 1]` —— 缺了直接报 nil 索引 ✓）—— 与 onOrder 一致：全收 ✓
    local collected = {}
    for i = 0, 15 do collected[i] = true end

    local opts = {
        action = action, gate = gate, band = NET_PROFIT_BAND,
        nMaterials = nMaterials, matNames = matNames, weights = weights,
        scoreBasis = scoreBasisEff, rarityTier = rarityTier, collected = collected,
    }

    -- ★★★ ⑩ 多区域扫描：区域 × 参数 × 层级 ✓✓
    local scanned = {}
    local stoppedEarly = false
    local scanMs = 0
    for _, item in ipairs(areaList) do
        scanMs = math.floor((os.clock() - t0) * 1000)
        if #scanned > 0 and budgetMs > 0 and scanMs > budgetMs then
            stoppedEarly = true
            break
        end
        local rec = scanJobArea(command, Job, player, ship, ctype, item.area, params, opts)
        rec.offset = item.offset
        rec.index = #scanned + 1
        scanned[#scanned + 1] = rec
    end
    scanMs = math.floor((os.clock() - t0) * 1000)

    rankJobAreas(scanned, NET_PROFIT_BAND)
    local chosen = scanned[1]
    local analysedArea = chosen.area
    local results = chosen.results

    -- ★★★ ⑪ 最终推荐：把**所有区域的所有参数档**放一起，取闸门内价值最高的那个 ✓✓
    local pool = {}
    for _, rec in ipairs(scanned) do
        for _, c in ipairs(rec.candidates) do
            if c.acceptable then
                -- ★★ 把该区域的几何**直接挂到候选上** ✓✓ —— **绝不要**用 `scanned[rec.index]`
                --    再回去找 ✗：区域榜已经**原地重排**过，而 rec.index 是**排序前**的序号
                --    → 会指到**另一个区域** ✗✓（自检 S1b 当场抓到：推荐落在 (0,4) 而非 (4,4) ✓）
                c.areaIndex = rec.index
                c.areaLower = { x = rec.area.lower.x, y = rec.area.lower.y }
                c.areaUpper = { x = rec.area.upper.x, y = rec.area.upper.y }
                c.areaOffset = { x = rec.offset.x, y = rec.offset.y }
                c.areaFieldTier = rec.fieldTier
                c.label = tostring(rec.index) .. "/" .. tostring(c.tag)
                pool[#pool + 1] = c
            end
        end
    end
    Job.rankCandidates(pool, gate, { band = NET_PROFIT_BAND })

    local recommendation, riskWarning = nil, nil
    local top = pool[1]
    if top ~= nil then
        local off = top.areaOffset or { x = 0, y = 0 }
        recommendation = {
            action = action,
            area = {
                lower = top.areaLower,
                upper = top.areaUpper,
                offset = { x = off.x, y = off.y },
            },
            x = baseX + off.x,
            y = baseY + off.y,
            size = size,
            tag = top.tag,
            duration = top.duration,
            safeMode = top.safeMode,
            escorts = top.escorts or {},
            attackChance = top.chance,
            maxAttackChance = gate,
            valueLow = top.valueLow,
            valueHigh = top.valueHigh,
            scoreBasis = top.scoreBasis,
            topTier = top.topTier,
            topMaterial = top.topMaterial,
            items = top.items,
            scrapHigh = top.scrapHigh,
            fieldTier = top.areaFieldTier,
            materials = top.materials,
            scrapMaterials = top.scrapMaterials,
        }
        local desc
        if action == "Mine" then
            desc = string.format(
                "层级加权价值 %.0f~%.0f（口径：%s）；最高可采矿 = %s（层级 %s）；伏击概率 %s ≤ %.0f%%；区域偏移 (%+d,%+d)；时长 %s 小时；安全模式 %s；护航 %s",
                math.floor((top.valueLow or 0) + 0.5), math.floor((top.valueHigh or 0) + 0.5),
                tostring(top.scoreBasis),
                tostring(top.topMaterial), tostring(top.topTier),
                top.chance and string.format("%.1f%%", top.chance * 100) or "未知",
                gate * 100, off.x, off.y,
                tostring(top.duration), tostring(top.safeMode),
                (#(top.escorts or {}) > 0) and table.concat(top.escorts, ",") or "无")
        else
            desc = string.format(
                "装备期望 %d~%d 件 × E[稀有度层级] %.3f = 加权价值 %.1f~%.1f；残骸场材料层级均值 %s；伏击概率 %s ≤ %.0f%%；区域偏移 (%+d,%+d)；时长 %s 小时；安全模式 %s；护航 %s",
                math.floor((top.items and top.items.from or 0) + 0.5),
                math.floor((top.items and top.items.to or 0) + 0.5),
                top.rarityTier or 0,
                top.valueLow or 0, top.valueHigh or 0,
                (top.areaFieldTier ~= nil) and string.format("%.2f", top.areaFieldTier) or "未知",
                top.chance and string.format("%.1f%%", top.chance * 100) or "未知",
                gate * 100, off.x, off.y,
                tostring(top.duration), tostring(top.safeMode),
                (#(top.escorts or {}) > 0) and table.concat(top.escorts, ",") or "无")
        end
        recommendation.reason = desc
    else
        -- ★ 一个档位都没过闸门 → **明说**，绝不偷偷挑高风险的 ✓✓
        --   先把"为什么没有推荐"分清楚（★ 两种原因要分开告诉模型 ✓）：
        --     ① 有产出的档位全被闸门挡下 → 该派护航 / 缩时长 / 开安全模式 ✓
        --     ② 压根没有有产出的档位 → 该换区域 / 换船（采不动 / 区域里没目标 ✓）
        local nOut, nOver, nPredFail = 0, 0, 0
        local anyBest = nil
        for _, rec in ipairs(scanned) do
            for _, c in ipairs(rec.candidates) do
                if c.hasOutput then
                    nOut = nOut + 1
                    if c.chance ~= nil and c.chance > gate then nOver = nOver + 1 end
                end
                if c.predictionFailed ~= nil or c.error ~= nil then nPredFail = nPredFail + 1 end
            end
            if rec.best ~= nil
                and (anyBest == nil or (tonumber(rec.bestValue) or -1) > (tonumber(anyBest.bestValue) or -1)) then
                anyBest = rec
            end
        end

        if nOut == 0 then
            riskWarning = string.format(
                "扫过的 %d 个区域里，%s 一个**有产出**的参数档都没算出来 ✗ —— 本鱼**不推荐**下单 ✓。"
                .. "常见原因：这艘船没有对应的采集设备（用 %s 看：参见返回里的 capability ✓）／"
                .. "区域里没有可采目标（area.analysis.materials / wrecks / asteroids 全 0 ✓）／"
                .. "或预测本身报错（%d 个档位报错 ✓）。→ 换一片星区、换一艘有采集设备的船 ✓",
                #scanned, action,
                (action == "Mine") and "原版 MineCommand:getMiningProperties"
                    or "原版 SalvageCommand:getSalvagingProperties",
                nPredFail)
        elseif anyBest ~= nil and anyBest.best ~= nil then
            riskWarning = string.format(
                "没有任何参数档通过风险闸门（伏击概率 ≤ %.0f%%）✗ —— 本鱼**不推荐**%s ✓。"
                .. "最有产出的候选是「%s / 区域偏移 %+d,%+d」（伏击概率 %s%s）；"
                .. "可派护航重算 / 缩短时长 / 开安全模式（原版会把伏击概率 ×0.1 ✓）/ 缩小区域范围 / 换一艘更硬更快的船 ✓",
                gate * 100, action, tostring(anyBest.bestTag),
                anyBest.offset.x, anyBest.offset.y,
                anyBest.bestChance and string.format("%.1f%%", anyBest.bestChance * 100) or "未知",
                (nOver == nOut) and string.format("；全部 %d 个有产出的档位都超闸门 ✓", nOut) or "")
        else
            riskWarning = string.format(
                "扫过的 %d 个区域里，%s 一个可用的参数档都没算出来 ✗ —— 本鱼**不推荐**下单 ✓"
                .. "（区域分析本身失败／或所有档位的预测都报错，共 %d 个报错档 ✓）",
                #scanned, action, nPredFail)
        end
    end

    -- ★ ⑫ orderHint：**可以直接喂给 order** ✓（onOrder 读 ship/action/x/y/size/duration/safeMode/escorts ✓）
    local orderHint = {
        ship = ship, action = action, size = size,
        x = baseX + chosen.offset.x, y = baseY + chosen.offset.y,
        duration = (chosen.best and chosen.best.duration) or durs.default,
        safeMode = (chosen.best and chosen.best.safeMode) or false,
        escorts = (chosen.best and chosen.best.escorts) or {},
        note = "order here — the ship is already inside this area",
    }
    if recommendation ~= nil then
        orderHint.x, orderHint.y = recommendation.x, recommendation.y
        orderHint.duration = recommendation.duration
        orderHint.safeMode = recommendation.safeMode
        orderHint.escorts = recommendation.escorts
    end

    -- ★ ⑬ 组装 plan（形状对齐 tradePlan ✓：{ config = {...}, reason = "..." } ✓）
    local plan = nil
    if recommendation ~= nil then
        plan = {
            config = {
                duration = recommendation.duration,
                safeMode = recommendation.safeMode,
                escorts = recommendation.escorts,
                collected = collected,
            },
            area = recommendation.area,
            attackChance = recommendation.attackChance,
            valueLow = recommendation.valueLow,
            valueHigh = recommendation.valueHigh,
            scoreBasis = recommendation.scoreBasis,
            reason = recommendation.reason,
        }
    end

    -- ★ ⑭ 说明（人看的 ✓）
    local scanNote = string.format("多区域扫描：%d 个区域 / 步长 %d / 尺寸 %dx%d / 共 %d ms",
        #scanned, step, size, size, scanMs)
    local notes = { "plan only — nothing was issued (order is a separate call)", scanNote }
    if sizeAdjusted then
        notes[#notes + 1] = string.format("data.size=%s 不是 %s 的合法区域尺寸 → 改用 %dx%d",
            tostring(data and data.size), tostring(action), size, size)
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
        notes[#notes + 1] = string.format("推荐 %s 档：%s", tostring(recommendation.tag), recommendation.reason)
    elseif riskWarning ~= nil then
        notes[#notes + 1] = riskWarning
    end

    CopilotRpc.trace(string.format(
        "jobPlan %s %s area=[%d,%d]-[%d,%d] 参数档=%d 扫描=%d区域/%dms 推荐=%s",
        action, ship, analysedArea.lower.x, analysedArea.lower.y,
        analysedArea.upper.x, analysedArea.upper.y, #params, #scanned, scanMs,
        recommendation and (recommendation.tag .. "/" .. tostring(recommendation.topMaterial)) or "none"))

    -- ★★★ 只**组装**，不发起 ✓✓（与 tradePlan 同一约定 ✓）
    local weightList = {}
    for i = 1, nMaterials do
        weightList[i] = {
            index = i, name = matNames[i], materialType = i - 1,
            weight = weights[i], costFactor = matList[i].costFactor, orePrice = matList[i].orePrice,
        }
    end

    return true, {
        ship = ship,
        action = action,
        area = analysedArea,
        size = size,
        materials = chosen.areaMaterials,      -- ★ 选中区域的逐材料：层级权重 × 区域概率 ✓
        weights = weightList,                  -- ★ 层级权重表（含原版 costFactor / 矿价，能审计 ✓）
        scoreBasis = scoreBasisEff,            -- ★ 排序**真正用的**口径（明说 ✓）
        weightBasis = scoreBasis,              -- ★ 材料权重的来源与口径（Salvage 时只用于废铁审计 ✓）
        lootBasis = lootBasis,
        weightSource = weightSource,
        rarity = (action == "Salvage") and {
            source = Job.RARITY_MIX_SOURCE,
            tierFrom = rarityTierFrom,
            expectedTier = rarityTier,
            mix = Job.rarityBreakdown(rarityTierOf),
            note = "★ 原版这张稀有度混合表**与区域无关**（常数）✗ → 区域间排序实际由'装备件数'驱动 ✓；区域间的'高科技程度'用 fieldTier（残骸场材料层级均值）作**次级键** ✓",
        } or nil,
        capability = capability,                -- ★ 这艘船**到底采得动什么**（原版权威口径 ✓）
        candidates = chosen.candidates,          -- 选中区域的全部参数档 ✓（含逐材料明细 ✓）
        plan = plan,                             -- 可行 config + reason；nil = 不建议下单 ✓
        recommendation = recommendation,         -- nil = 一个档位都没过闸门 ✗（看 riskWarning ✓）
        riskWarning = riskWarning,
        areaRanking = buildJobRanking(scanned, opts),
        areasScanned = #scanned,
        scanMs = scanMs,
        scanNote = scanNote,
        note = table.concat(notes, "；"),
        durationChoices = durs,
        orderHint = orderHint,
        analysis = {
            sectors = results.sectors, reachable = results.reachable,
            unreachable = results.unreachable,
            biggestFactionInArea = results.biggestFactionInArea,
            materials = results.materials,
            safeMaterials = results.safeMaterials,
        },
        scan = {
            step = step, size = size, sizeRequested = reqSize, legalSizes = templates,
            maxAreas = maxAreas, budgetMs = budgetMs, stoppedEarly = stoppedEarly,
            usedShipCentre = usedShipCentre, droppedNoShip = dropped,
            shipSector = { x = shipX, y = shipY }, maxAttackChance = gate,
            escortsConsidered = escorts,
            parameterTags = (function()
                local t = {}
                for _, p in ipairs(params) do t[#t + 1] = p.tag end
                return t
            end)(),
            duration = durs,
            objective = "多区域 × 参数（时长/安全模式/护航）× 层级加权 —— 采最高阶的矿 / 收最高科技的战利品，且在伏击概率 ≤ 10% 之下",
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

-- setGoal：DSH 设定/清除某船的运营目标（真实现 ✓，用 lib/copilot/goal）
function CopilotLinkIn.onSetGoal(data)
    data = data or {}
    local ship = data.ship
    if type(ship) ~= "string" or ship == "" then
        return false, "BAD_REQUEST", "setGoal needs data.ship"
    end

    local player = Player()
    if player == nil then return false, "NO_PLAYER", "no player object" end

    local Goal = include("copilot/goal")

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
-- ===========================================================================
-- scoutPlan —— 勘察（2026-10-16 加 ✓，主人定的战略第一步）
-- ===========================================================================
-- 主人的原话：「往地图中心推进…越往中心矿越高级、装备越优秀、也越危险」✓
--   → 而**没有已探索的星区，就没有可推进的方向** ✓✓ 所以勘察是前提 ✓
--
-- 原版核实（scoutcommand.lua，全部实读 ✓）：
--   · getAreaSize            = {21,21}          :416 ✓
--   · isShipRequiredInArea   = **true**         :428 ✓ → 区域必须**含船** ✓（与 Mine/Salvage 同 ✓）
--   · isAreaFixed            = false            :434 ✓
--   · getConfigurableValues  = 只有 addCaptainsNote(default true)  :446 ✓
--       ★ **没有 duration / safeMode** ✗ —— 时长是它自己按可达星区数算的 ✓
--   · getPredictableValues   = attackChance + duration + **revealsOffgrid**  :459 ✓
--   · calculatePrediction    : duration = area.analysis.reachable / 25（+ Reckless 船长加成）:472 ✓
--       results: duration :516 / attackChance+attackLocation :517 / **revealsOffgrid** :519-530 ✓
--
-- 评分（照主人的目标 ✓，不是拍脑袋 ✗）：
--   主键 = **revealsOffgrid**（新揭开多少"隐藏质量星区" ✓ = 多少**新地图** ✓）
--   次键 = **离地图中心 (0,0) 越近越好** ✓（推进方向 ✓）
--   ★ 若原版没给出可用的 revealsOffgrid → 退到"可达星区数"，并在 scoreBasis **写明** ✓
function CopilotLinkIn.scoutPlan(player, data)
    data = data or {}
    local ship = data.ship
    if type(ship) ~= "string" or ship == "" then
        return false, "BAD_REQUEST", "scoutPlan needs data.ship"
    end
    if player == nil then return false, "NO_PLAYER", "no player object" end

    local startMs = os.clock()
    local gate = tonumber(data.maxAttackChance) or 0.10
    local Card = include("copilot/card")
    local card = Card.shipCard(player, ship)
    local sx = card.sector and card.sector.x or nil
    local sy = card.sector and card.sector.y or nil
    if sx == nil or sy == nil then
        return false, "NO_POSITION", "cannot read the ship position"
    end

    local ctype = COMMAND_TYPES.Scout
    local okInc = pcall(function() return include("areaanalysis") end)
    if not okInc or type(run) ~= "function" then
        return false, "NO_ANALYSIS_RUN", "areaanalysis.run missing"
    end
    local okF, factory = pcall(function() return include("commandfactory") end)
    if not okF then return false, "NO_COMMAND_FACTORY", tostring(factory) end
    local okCmd, command = pcall(function() return factory.makeCommand(ctype) end)
    if not okCmd or command == nil then return false, "NO_COMMAND", tostring(command) end

    local sizes = legalAreaSizes(command, player, ship)
    local size = pickSquareSize(sizes, tonumber(data.size), 21)
    local half = math.floor((size - 1) / 2)
    local offs = scanOffsets(half, tonumber(data.step) or 4)
    local maxAreas = math.max(1, math.min(tonumber(data.maxAreas) or 9, #offs))

    local scanned, dropped = {}, 0
    for _, o in ipairs(offs) do
        if #scanned >= maxAreas then break end
        local cx, cy = sx + o.x, sy + o.y
        local a = buildArea(cx, cy, size)
        -- ★ 原版要求船在区域内（:428 ✓）→ 不含船的区域**直接丢掉** ✓（不许把船挪走 ✗）
        if sx >= a.lower.x and sx <= a.upper.x and sy >= a.lower.y and sy <= a.upper.y then
            local okR, _s, _t, rArea, rRes = pcall(function()
                return run(player.index, ship, ctype, a, player.index)
            end)
            local entry = { area = a, offset = o, centre = { x = cx, y = cy }, distance = math.abs(cx) + math.abs(cy) }
            if okR and type(rRes) == "table" then
                rArea.analysis = rRes
                entry.analysis = {
                    reachable = rRes.reachable, sectors = rRes.sectors,
                    unreachable = rRes.unreachable,
                }
                local okP, pred = pcall(function()
                    return command:calculatePrediction(player.index, ship, rArea, { addCaptainsNote = true })
                end)
                if okP and type(pred) == "table" then
                    local revLo, revHi = numericRange(pred.revealsOffgrid)
                    local durLo, durHi = numericRange(pred.duration)
                    entry.revealsLow, entry.revealsHigh = revLo, revHi
                    entry.durationLow, entry.durationHigh = durLo, durHi
                    entry.attackChance = pred.attackChance and pred.attackChance.value or nil
                    -- ★ 退路：原版没给 revealsOffgrid → 用"可达星区数"当代理 ✓ 并写明 ✓
                    if entry.revealsLow == nil then
                        entry.revealsLow = tonumber(rRes.reachable) or 0
                        entry.revealsHigh = entry.revealsLow
                        entry.scoreBasis = "revealsOffgrid unavailable -> reachable sector count (proxy)"
                    else
                        entry.scoreBasis = "revealsOffgrid (vanilla, scoutcommand.lua:519-530)"
                    end
                else
                    entry.predictionFailed = tostring(pred)
                end
            else
                entry.error = tostring(rRes)
            end
            local ch = chanceOf(entry)
            entry.attackChanceEffective = ch
            entry.acceptable = (entry.revealsLow ~= nil) and (ch == nil or ch <= gate)
            scanned[#scanned + 1] = entry
        else
            dropped = dropped + 1
        end
    end

    -- 排序：达标优先 → reveals 降序 → 离中心近优先 ✓✓
    table.sort(scanned, function(x, y)
        if x.acceptable ~= y.acceptable then return x.acceptable end
        local rx, ry = x.revealsLow or -1, y.revealsLow or -1
        if rx ~= ry then return rx > ry end
        return (x.distance or 0) < (y.distance or 0)
    end)

    local best = scanned[1]
    local acceptable = nil
    for _, e in ipairs(scanned) do
        if e.acceptable then acceptable = e; break end
    end

    local out = {
        ship = ship, action = "Scout",
        shipSector = { x = sx, y = sy },
        size = size, areasScanned = #scanned, droppedNoShip = dropped,
        maxAttackChance = gate,
        scanMs = math.floor((os.clock() - startMs) * 1000),
        areaRanking = scanned,
        areasScannedList = scanned,
    }
    if acceptable ~= nil then
        out.recommendation = acceptable
        out.area = acceptable.area
        out.orderHint = {
            ship = ship, action = "Scout",
            x = acceptable.centre.x, y = acceptable.centre.y, size = size,
            addCaptainsNote = true,
            note = "reveals hidden-mass sectors; the ship must already be inside this area (vanilla isShipRequiredInArea = true)",
        }
        out.scoreBasis = acceptable.scoreBasis
        out.note = "scout recommendation: reveals " .. tostring(acceptable.revealsLow)
            .. " (basis: " .. tostring(acceptable.scoreBasis) .. "), attackChance "
            .. tostring(acceptable.attackChanceEffective) .. ", " .. tostring(acceptable.distance) .. " from map centre"
    else
        out.recommendation = nil
        out.scoreBasis = best and best.scoreBasis or "n/a"
        out.riskWarning = "no scouting area passed the risk gate (<= " .. tostring(gate) .. ")"
        out.note = "no acceptable scouting area — do not order; consider escorts or another region"
    end
    -- ★★ 侦察的**事实**（2026-10-16 ✓✓ —— 只给事实，不做决定 ✓）
    --
    -- 主人原则（最高优先 ✓）：「把机制写清楚让决策 LLM 去判断该怎么做，
    --   而不是做成一个固定的脚本流程。」
    -- → 这里**只**给算数结果 ✓：邻域还有多少未探索 ✓、离地图中心多远 ✓、侦察一次多久 ✓
    -- → ★ **不**给"该不该挪位 / 挪到哪 / 下一步做什么" ✗（那是 LLM 的判断 ✓✓）
    do
        local okScout, Scout = pcall(function() return include("copilot/scout") end)
        if okScout and type(Scout) == "table" then
            local okPos, px, py = pcall(function() return player:getShipPosition(ship) end)
            if okPos and px ~= nil and py ~= nil then
                -- "已探索"判据**直接来自原版** ✓（不用猜 ✗）：
                --   player:getKnownSector(x,y) ~= nil → 该星区已知 ✓
                --   （orderchain.lua:887 / factionmapsegment.lua:235 / entitydbg.lua:3955 ✓）
                local isKnown = function(x, y)
                    local ok, view = pcall(function() return player:getKnownSector(x, y) end)
                    if not ok then return false end
                    return view ~= nil
                end
                out.shipSector = { x = px, y = py }
                -- 邻域 = 侦察区域本身（原版 21x21 → half=10 ✓ scoutcommand.lua:416 ✓）
                out.coverage = Scout.survey(isKnown, px, py, 10)
                out.coverage.basis = "player:getKnownSector(x,y)==nil 视为未探索 ✓（orderchain.lua:887 / factionmapsegment.lua:235）"
                out.centre = { x = 0, y = 0, distance = Scout.centreDistance(px, py),
                               note = "|x|+|y| 越小越靠地图中心；主人设定：越靠中心矿越高级、装备越好、也越危险 ✓" }
                out.travelFacts = { minJumps = 2, areaSize = { 1, 1 }, shipMustBeInside = false,
                                    source = "travelcommand.lua（目的地 ≥2 跳 ✓）；scoutcommand.lua:416/428（21x21、船必须在区内 ✓）" }
                out.revealsOffgridNote = "0=none 1=some 2=all —— ★ 是枚举**不是计数** ✗（scoutcommand.lua:519-529 ✓）"
                out.factNote = "以上都是**事实** ✓；在哪侦察、要不要用旅行换个位置，由你自己判断 ✓"
                CopilotRpc.trace(string.format("scoutPlan 事实: 船(%d,%d) 未探索=%d/%d 离中心=%d",
                    px, py, out.coverage.unknown, out.coverage.total, out.centre.distance))
            end
        end
    end

    CopilotRpc.trace(string.format("scoutPlan %s 扫 %d 区 / %dms 推荐=%s",
        ship, #scanned, out.scanMs, acceptable and "有" or "无"))
    return true, out
end

-- ---------------------------------------------------------------------------
-- ★★ 只告知、不决定（2026-10-17 主人要求 ✓✓）
-- ---------------------------------------------------------------------------
--
--   主人原话：「把机制写清楚，让决策 LLM 去判断该怎么做，而不是做成一个固定的脚本流程」✓
--
--   所以计划响应只提供**事实与选项** ✓：某个评分器排第一的档位**只是一个选项** ✗，
--   而"超闸门"的候选也**照样列出来**（标 exceedsRiskLimit=true ✓），不静默丢弃 ✓✓。
--
--   本函数只加字段、不改任何既有字段 ✓ —— 既不重排、也不删减 ✓。
function CopilotLinkIn.informOnly(resp, data)
    if type(resp) ~= "table" then return resp end
    local gate = 0.10
    if type(data) == "table" then
        local g = tonumber(data.maxAttackChance)
        if g ~= nil then gate = g end
    end
    resp.riskLimit = gate
    resp.recommendationIsOneOption = true
    resp.decisionNote = "★ 这些是事实与选项：recommendation / orderHint 只是评分器选出的其中一组参数，" ..
        "**供参考、不是必须照抄的答案** ✓；选哪个（或什么都不选）由决策模型自己定 ✓。" ..
        "exceedsRiskLimit=true 的候选只是**超出玩家闸门**，数字照样列出来供你比较 ✓。"

    local function tagList(list, depth)
        if type(list) ~= "table" then return end
        for _, c in ipairs(list) do
            if type(c) == "table" then
                local ch = tonumber(c.attackChanceEffective)
                if ch == nil then ch = tonumber(c.attackChance) end
                c.riskLimit = gate
                if ch ~= nil then
                    c.exceedsRiskLimit = (ch > gate)
                    c.satisfiesPlayerRiskRule = (ch <= gate)
                end
                if depth ~= nil and depth > 0 then tagList(c.candidates, depth - 1) end
            end
        end
    end

    tagList(resp.candidates, 0)
    tagList(resp.areaRanking, 1)
    if type(resp.recommendation) == "table" then
        local r = resp.recommendation
        local ch = tonumber(r.attackChanceEffective)
        if ch == nil then ch = tonumber(r.attackChance) end
        r.riskLimit = gate
        if ch ~= nil then r.exceedsRiskLimit = (ch > gate) end
        r.isOneOptionAmongListed = true
    end
    return resp
end

return CopilotLinkIn
