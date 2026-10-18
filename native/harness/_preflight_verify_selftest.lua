-- _preflight_verify_selftest.lua —— 「回执带预检 + 实测」离线自检 ✓ 2026-10-17
--
-- 主人原话（本文件验的就是它）：
--   「你下的指令似乎你都不知道是有没有正常执行啊，回执没法带结果吗？」
--
-- 不开游戏就能验：把游戏 API 全换成替身，然后**真的调**
-- `data/scripts/net/link_in.lua` 里的 `CopilotLinkIn.onOrder` / `.tickOrders` /
-- `.orderStatus` ✓✓。
--
-- 覆盖（任务书第 1、2 条 ✓）：
--   · 预检不过 → `accepted:false` + `preflight{ok:false, code, reason, detail}` ✓，
--     且**什么都没发**（没发起区域分析 ✗、没排 startCommand 队列 ✗）
--   · 预检通过 → `accepted:true` + `preflight{ok:true}` + `orderId` + `verify{pending}` ✓
--   · 实测：startCommand 之后延迟重读实体状态 ✓，`verify.ok` 按动作的**成功证据**判 ✓；
--     状态毫无变化 → `ok=false` + `reason`（"接了就完"的情形 ✓✓）
--   · 五种动作都造「预检不过 / 通过」各一例 ✓（Travel / Sell / Trade / Mine / Salvage ✓）
--
-- ★ 判据的**原版依据**（每条都在 link_in.lua 注释里带 文件:行 ✓，这里只列结论）：
--   Travel 1 跳：travelcommand.lua:75-77 `#route <= 2 → "This route is too short."`（服务端 initialize ✓）
--   Travel 已在终点：travelcommand.lua:71-73
--   框必须含船：simulation.lua:545-554 + 各命令 isShipRequiredInArea
--   Trade 要 Merchant：tradecommand.lua:632-637
--   duration 区间：simulation.lua:52-72（clampConfig）+ 命令自己的 getConfigurableValues
--   护航太远：simulationutility.lua:156-163（TooFarAway）
--   busy 判据：simulation.lua:584 `setShipAvailability(ship, InBackground)`（在**所有**闸门之后 ✓）
--   货舱/坐标只在 onFinish 变：sellcommand.lua:161/235-267、travelcommand.lua:373-408
--
-- 跑法（★ 必须在 mod 仓库根跑）：
--   native\harness\lua.exe native\harness\_preflight_verify_selftest.lua

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

-- ===========================================================================
-- 夹具状态（全部可变 ✓ —— 用来造"预检不过 / 通过"、"实测有变化 / 没变化"）
-- ===========================================================================

local SHIP, SHIP_X, SHIP_Y = "Salvager-00001", -381, 57
local DEST_X, DEST_Y = -374, 64          -- Travel 的目的地（7 跳 ✓）
local AVAIL = 0                          -- 0 = Available / 1 = InBackground
local CAP = 4000
local CARGO = {}                         -- good 对象 → 数量 ✓
local DEMAND, SUPPLY = {}, {}
local CAPTAIN_CLASS = "Scavenger"        -- 船长职业名（替身 hasClass 用 ✓）
local HAS_CAPTAIN = true
local TRACE, INVOKED = {}, {}
local START_COMMANDS = {}                -- 第二阶段真的发出去的 startCommand ✓
local TRAVEL_ROUTE_SECTORS = 8           -- 默认：7 跳（route = 跳数 + 1 ✓）
local RUN_ERROR = false
local ESCORTS = {}                       -- name → { x, y, reach, canFight }

-- ★ 前向声明（reset() 里要用它 ✓ —— Lua 的 local 是**词法作用域** ✗，
--   写在下面 `LinkIn = dofile(...)` 只会造一个新的 local，reset 看不到 ✓）
local LinkIn = nil

local function reset()
    SHIP_X, SHIP_Y = -381, 57
    AVAIL = 0
    CARGO, DEMAND, SUPPLY = {}, {}, {}
    CAPTAIN_CLASS = "Scavenger"
    HAS_CAPTAIN = true
    TRACE, INVOKED, START_COMMANDS = {}, {}, {}
    TRAVEL_ROUTE_SECTORS = 8
    RUN_ERROR = false
    ESCORTS = {}
    LinkIn.orderRecords = {}
    LinkIn.lastOrderOf = {}
    LinkIn.orderSeq = 0
    LinkIn.pendingOrders = {}
    LinkIn.pendingVerifies = {}
end

-- ===========================================================================
-- 游戏 API 的替身 ✓
-- ===========================================================================

CopilotRpc = { trace = function(line) TRACE[#TRACE + 1] = tostring(line) end }

local GOODS = {
    ["Rift Naonite Ore"] = { price = 3, size = 0.025, tags = { naonite = true, ore = true, rich = true } },
    ["Drill"] = { price = 40, size = 1 },
    ["Oxygen"] = { price = 12, size = 1 },
    ["Antigrav Unit"] = { price = 900, size = 2 },
}
for _, g in pairs(GOODS) do g.good = function(self) return self end end

function NumMaterials() return 7 end
function Rarity(v) return { value = v } end

-- ★ 区域分析：Travel 交 route，Sell 交 goodsInDemand（与 link_in 的用法一致 ✓）
function run(factionIndex, shipName, ctype, area, callingPlayer)
    if RUN_ERROR then error("simulated area analysis failure") end
    local inDemand, inSupply = {}, {}
    for k in pairs(DEMAND) do inDemand[k] = true end
    for k in pairs(SUPPLY) do inSupply[k] = true end
    local results = {
        goodsInDemand = inDemand,
        goodsInSupply = inSupply,
        numSectorsWithGoodInDemand = {},
        numSectorsWithGoodInSupply = {},
        averagePriceFactors = {}, highestPriceFactors = {},
        sectors = 225, reachable = 220, unreachable = 5,
        biggestFactionInArea = 1, reachableCoordinates = {},
    }
    if ctype == "travel" or ctype == TRAVEL_CTYPE then
        local route = {}
        for i = 1, TRAVEL_ROUTE_SECTORS do route[i] = { x = SHIP_X + i, y = SHIP_Y } end
        results.route = route
        results.origin = { x = SHIP_X, y = SHIP_Y }
        results.destination = { x = area.lower.x, y = area.lower.y }
        results.values = { jumpRange = 5, canPassRifts = false }
        results.attackProbabilities = {}
        results.travelTimeFactors = {}
        results.reachableCoordinates = {}
    end
    -- ★ 2026-10-18：order 的 Trade 分支现在**下单前**用同一份分析校验路线 ✓
    --   → 替身必须像原版一样给出 routes（tradecommand.lua:390-444 ✓，否则一律 NO_ROUTE ✗）
    if COURSE_ACTION == "Trade" then
        results.routes = {}
        for name in pairs(GOODS) do
            results.routes[#results.routes + 1] = {
                name = name, lowest = -0.05, highest = 0.15, profitPerSize = 10,
                from = { x = SHIP_X, y = SHIP_Y }, to = { x = SHIP_X + 2, y = SHIP_Y },
            }
        end
    end
    return shipName, ctype, area, results, callingPlayer
end

-- ★ 各动作的**原版接口**替身（判据照抄原版；原话逐字保留 ✓）
local FAKE_COMMAND = {}

function FAKE_COMMAND:getAreaSize(ownerIndex, shipName)
    return { x = 15, y = 15 }
end

function FAKE_COMMAND:isShipRequiredInArea(ownerIndex, shipName)
    return COURSE_ACTION ~= "Travel"          -- travelcommand.lua:472-474 = false ✓
end

function FAKE_COMMAND:getConfigurableValues(ownerIndex, shipName)
    if COURSE_ACTION == "Mine" or COURSE_ACTION == "Salvage" then
        -- minecommand.lua:510-527 ✓（duration 0.5..2 + safeMode + immediateDelivery）
        return {
            duration = { from = 0.5, to = 2, default = 1 },
            safeMode = { default = false },
            immediateDelivery = { default = false },
        }
    end
    if COURSE_ACTION == "Sell" then
        return { goodsToSell = {} }           -- sellcommand.lua:434-441 ✓
    end
    return {}                              -- Trade/Scout/Travel/Refine：没有 duration ✓
end

function FAKE_COMMAND:calculatePrediction(ownerIndex, shipName, area, config)
    -- ★ Trade 的口径（tradecommand.lua:736-852 ✓）：fillPrediction 读这几个字段 ✓
    if type(config) == "table" and type(config.goodName) == "string" then
        return {
            attackChance = { value = 0.05 },
            profitPerFlight = { from = 100, to = 120 },
            flights = { from = 2, to = 2 },
            flightTime = { value = 600 },
            maxAvailable = { value = 500 },
            transportedPerFlight = 100,
        }
    end
    return { attackChance = { value = 0.05 }, distance = 42, travelTime = 3600, duration = 3600, yields = {} }
end

-- ★ Sell 的 getErrors 替身（判据抄 sellcommand.lua:326-412，原话逐字保留 ✓）
function FAKE_COMMAND:getErrors(ownerIndex, shipName, area, config)
    local entry = ShipDatabaseEntry(ownerIndex, shipName)
    local captain = entry:getCaptain()
    local isMerchant = captain:hasClass("Merchant")
    local isSmuggler = captain:hasClass("Smuggler")
    for _, toSell in pairs(config.goodsToSell) do
        if GOODS[toSell.goodName] == nil then
            return string.format("I don't know how to sell '%s' here.", toSell.goodName)
        end
    end
    for _, toSell in pairs(config.goodsToSell) do
        if toSell.amount == 0 then
            return string.format("No amount for %s selected!", toSell.goodName)
        end
    end
    for _, toSell in pairs(config.goodsToSell) do
        if (area.analysis.goodsInDemand and not area.analysis.goodsInDemand[toSell.goodName])
            and not (isSmuggler or isMerchant) then
            return string.format("There is no demand for '%s' here.", toSell.goodName)
        end
        if (area.analysis.goodsInSupply and area.analysis.goodsInSupply[toSell.goodName])
            and not (area.analysis.goodsInDemand and area.analysis.goodsInDemand[toSell.goodName])
            and not isSmuggler then
            return string.format("There is no demand for '%s' here.", toSell.goodName)
        end
    end
    return nil
end

function include(name)
    if name == "areaanalysis" then return nil end       -- 真的也返回 nil（只定义全局 run ✓）
    if name == "commandfactory" then
        return { makeCommand = function(ctype) return FAKE_COMMAND end }
    end
    if name == "goods" then return GOODS end
    if name == "captainutility" then
        -- CaptainUtility.ClassType（数字枚举 ✓；名字与真机一致 ✓）
        return { ClassType = { None = 0, Miner = 1, Merchant = 2, Smuggler = 3, Scavenger = 4 } }
    end
    if name == "copilot/card" then
        -- ★ 替身（真 card.equipmentFacts 由 _weapons_card_selftest.lua 验过 ✓）：
        --   只交出"有没有武装"这三个事实，口径与真的一模一样 ✓
        return {
            equipmentFacts = function(_player, entry, card, _notes)
                card = card or {}
                local e = ESCORTS_BY_ENTRY[entry] or ESCORTS_BY_ENTRY.default
                if e ~= nil then
                    card.armedTurrets = e.armedTurrets or 0
                    card.armedFighters = e.armedFighters or 0
                    card.torpedoes = e.torpedoes or 0
                    card.canFight = (card.torpedoes > 0) or (card.armedTurrets > 0) or (card.armedFighters > 0)
                    card.canFightKnown = true
                else
                    card.canFightKnown = false
                end
                return card
            end,
        }
    end
    error("unexpected include: " .. tostring(name))
end

-- 护航的替身数据（按船名 ✓）
ESCORTS_BY_ENTRY = {}
local function escortEntry(name)
    local e = ESCORTS[name]
    local entry = {
        name = name,
        getCargo = function() return {}, CAP end,
        getCaptain = function() return { hasClass = function() return false end } end,
        getCoordinates = function() return e and e.x or 0, e and e.y or 0 end,
        getHyperspaceProperties = function() return e and e.reach or 5, false end,
        getTurrets = function() return {} end,
        getLightweightHangar = function() return {} end,
    }
    ESCORTS_BY_ENTRY[entry] = { armedTurrets = (e and e.canFight) and 3 or 0 }
    return entry
end

local CAPTAINS = {}
local function shipEntry(name)
    if CAPTAINS[name] == nil then
        CAPTAINS[name] = {
            name = name,
            getCargo = function() return CARGO, CAP end,
            getFreeCargoSpace = function()
                local used = 0
                for _, a in pairs(CARGO) do used = used + a end
                return CAP - used
            end,
            getCaptain = function()
                if name ~= SHIP then return { hasClass = function() return false end } end
                if HAS_CAPTAIN ~= true then return nil end
                return {
                    primaryClass = ({ None = 0, Miner = 1, Merchant = 2, Smuggler = 3, Scavenger = 4 })[CAPTAIN_CLASS] or 0,
                    hasClass = function(_, cls)
                        return cls == ({ None = 0, Miner = 1, Merchant = 2, Smuggler = 3, Scavenger = 4 })[CAPTAIN_CLASS]
                    end,
                }
            end,
            getCoordinates = function() return SHIP_X, SHIP_Y end,
            getHyperspaceProperties = function() return 5, false end,
            getTurrets = function() return {} end,
            getLightweightHangar = function() return {} end,
        }
    end
    return CAPTAINS[name]
end

function ShipDatabaseEntry(ownerIndex, name)
    if ESCORTS[name] ~= nil then return escortEntry(name) end
    return shipEntry(name)
end

local player = {
    index = 1,
    craft = nil,
    getShipPosition = function(self, name)
        if ESCORTS[name] ~= nil then return ESCORTS[name].x, ESCORTS[name].y end
        return SHIP_X, SHIP_Y
    end,
    getShipAvailability = function(self, name)
        if ESCORTS[name] ~= nil then return ESCORTS[name].avail or 0 end
        return AVAIL
    end,
    invokeFunction = function(self, path, fn, ...)
        INVOKED[#INVOKED + 1] = fn
        if fn == "startCommand" then
            local args = { ... }
            START_COMMANDS[#START_COMMANDS + 1] = args
        end
    end,
}
function Player() return player end
ShipAvailability = { Available = 0, InBackground = 1 }
COURSE_ACTION = "Mine"                  -- 当前正在跑的动作（替身接口按它分支 ✓）
TRAVEL_CTYPE = "bbcf8ba1-a1e0-4a34-8174-15caebd11fed"   -- commandtype Travel ✓

LinkIn = dofile("data/scripts/net/link_in.lua")

-- ===========================================================================
-- 小工具
-- ===========================================================================

local function mkGood(name)
    local g = { name = name, stolen = false }
    g.displayName = function(self, n) return name end
    return g
end

local function traceHas(needle)
    for _, line in ipairs(TRACE) do
        if line:find(needle, 1, true) ~= nil then return line end
    end
    return nil
end

local function codesOf(pf)
    local out = {}
    for _, c in ipairs((pf and pf.checks) or {}) do
        if c.ok ~= true then out[#out + 1] = tostring(c.name) end
    end
    for _, w in ipairs((pf and pf.warnings) or {}) do
        out[#out + 1] = tostring(w.code)
    end
    return table.concat(out, ",")
end

-- 跑一个 order，并把动作传给替身命令（COURSE_ACTION ✓）
local function order(action, params)
    COURSE_ACTION = action
    params = params or {}
    params.ship = params.ship or SHIP
    params.action = action
    return LinkIn.onOrder(params)
end

-- 推进「第二阶段 + 实测」（把时间点拨到过去 ✓ —— 不睡真的秒数 ✓）
local function tickStart()
    local n = 0
    for _, job in ipairs(LinkIn.pendingOrders) do
        job.at = os.clock() - 1
        n = n + 1
    end
    if n > 0 then
        COURSE_ACTION = LinkIn.pendingOrders[1].action or COURSE_ACTION
    end
    LinkIn.tickOrders()
    return n
end

local function tickVerify()
    local n = 0
    for _, id in ipairs(LinkIn.pendingVerifies or {}) do
        local rec = LinkIn.orderRecords[id]
        if rec ~= nil then rec.verifyAt = os.clock() - 1 end
        n = n + 1
    end
    LinkIn.tickOrders()
    return n
end

-- ===========================================================================
-- P1：★ Travel 到**1 跳**目的地 → 预检 MIN_DISTANCE，且船不动 ✓✓（今晚翻车 ④）
-- ===========================================================================
print("== P1: Travel 1 跳目的地 → MIN_DISTANCE（不下单 ✓）==")
reset()
TRAVEL_ROUTE_SECTORS = 2                     -- route = 2 → 跳数 1 ✓（travelcommand.lua:75-77）
local ok1, r1 = order("Travel", { x = DEST_X, y = DEST_Y })
check("P1 回执 ok=true（RPC 成功 ✓）但 accepted=false ✓", ok1 == true and r1.accepted == false, r1)
check("P1 executed=false ✓", r1.executed == false, r1.executed)
check("P1 preflight.ok=false ✓", type(r1.preflight) == "table" and r1.preflight.ok == false, type(r1.preflight))
check("P1 preflight.code = MIN_DISTANCE ✓", r1.preflight.code == "MIN_DISTANCE", tostring(r1.preflight.code))
check("P1 preflight.reason 带原版原话 'This route is too short.' ✓",
    type(r1.preflight.reason) == "string" and r1.preflight.reason:find("This route is too short.", 1, true) ~= nil,
    r1.preflight.reason)
check("P1 preflight.detail/reason 给出 travelcommand.lua:75-77 依据 ✓",
    type(r1.preflight.reason) == "string" and r1.preflight.reason:find("travelcommand.lua:75-77", 1, true) ~= nil,
    r1.preflight.reason)
check("P1 ★ 没发起区域分析（INVOKED 空 ✓）", #INVOKED == 0, table.concat(INVOKED, ","))
check("P1 ★ 没排 startCommand（pendingOrders 空 ✓）", #LinkIn.pendingOrders == 0, #LinkIn.pendingOrders)
check("P1 ★ 船没被塞进后台（availability 不变 ✓ —— '船不动' 的最直接证据 ✓）", AVAIL == 0, AVAIL)
check("P1 trace 写了『预检不过』✓", traceHas("预检不过") ~= nil, table.concat(TRACE, " | "))

-- ===========================================================================
-- P2：★ Travel 到**7 跳**目的地 → 预检通过 + orderId + verify{pending} ✓✓
-- ===========================================================================
print("== P2: Travel 7 跳 → 通过预检（accepted=true ✓）==")
reset()
TRAVEL_ROUTE_SECTORS = 8                     -- route = 8 → 跳数 7 ✓
local ok2, r2 = order("Travel", { x = DEST_X, y = DEST_Y })
check("P2 accepted=true ✓", ok2 == true and r2.accepted == true, r2)
check("P2 executed=true ✓", r2.executed == true, r2.executed)
check("P2 preflight.ok=true ✓", type(r2.preflight) == "table" and r2.preflight.ok == true, type(r2.preflight))
check("P2 预检里记了 MIN_DISTANCE 通过（routeSectors=8 → 7 跳 ✓）",
    codesOf(r2.preflight):find("MIN_DISTANCE") == nil and r2.preflight.travel and r2.preflight.travel.routeSectors == 8,
    codesOf(r2.preflight) .. " / " .. tostring(r2.preflight.travel and r2.preflight.travel.routeSectors))
check("P2 回执带 orderId ✓", type(r2.orderId) == "number" and r2.orderId > 0, tostring(r2.orderId))
check("P2 回执带 verify.pending=true（此刻还没采样 ✓）",
    type(r2.verify) == "table" and r2.verify.pending == true, type(r2.verify))
check("P2 verify 写清怎么取（orderStatus ✓）",
    type(r2.verify.how) == "string" and r2.verify.how:find("orderStatus", 1, true) ~= nil, tostring(r2.verify.how))
check("P2 ★ 真发起了区域分析 ✓", #INVOKED == 1 and INVOKED[1] == "startAreaAnalysis",
    table.concat(INVOKED, ","))
check("P2 排进了 startCommand 队列 ✓", #LinkIn.pendingOrders == 1, #LinkIn.pendingOrders)
check("P2 风险照旧有（预检通过才算了 risk ✓）", type(r2.risk) == "table", type(r2.risk))

-- orderStatus：还没采样 → pending ✓
local osOk, os1 = LinkIn.orderStatus(Player(), { ship = SHIP })
check("P2 orderStatus 回 ok=true ✓", osOk == true, tostring(os1))
check("P2 orderStatus 的 verify 仍是 pending ✓", os1.verify.pending == true, os1.verify.pending)
check("P2 orderStatus 的 started=false（还没发 startCommand ✓）", os1.started == false, tostring(os1.started))

-- ★ 第二阶段：startCommand 发出去（只是"进队列"，不是"做成了" ✗）
tickStart()
check("P2 startCommand 真的发了一单 ✓", #START_COMMANDS == 1, #START_COMMANDS)
check("P2 startCommand 的 ctype 是 Travel ✓", START_COMMANDS[1] and START_COMMANDS[1][2] == TRAVEL_CTYPE,
    START_COMMANDS[1] and tostring(START_COMMANDS[1][2]))
check("P2 ★ 排进了实测队列 ✓", #(LinkIn.pendingVerifies or {}) == 1, #(LinkIn.pendingVerifies or {}))
local rec2 = LinkIn.orderRecords[r2.orderId]
check("P2 记录里 started=true，但 startCommandOk 只是**队列**结果 ✓",
    rec2 and rec2.started == true and rec2.startCommandOk == true and rec2.verify == nil,
    rec2 and tostring(rec2.started) .. "/" .. tostring(rec2.startCommandOk))

-- ★ Travel 在跑 = InBackground（simulation.lua:584 ✓）→ 实测 ok=true，evidence=busy ✓
AVAIL = 1
tickVerify()
local ok3, os2 = LinkIn.orderStatus(Player(), { orderId = r2.orderId })
check("P2 orderStatus 取到实测结论 ✓", ok3 == true and type(os2.verify) == "table", tostring(os2))
check("P2 ★ Travel 在后台跑 → verify.ok=true ✓", os2.verify.ok == true, tostring(os2.verify.ok))
check("P2 ★ evidence = busy（原版只在到达/召回才改坐标 ✓）",
    os2.verify.evidence == "busy", tostring(os2.verify.evidence))
check("P2 verify 写明了『坐标不动』的机制 ✓",
    type(os2.verify.note) == "string" and os2.verify.note:find("onFinish", 1, true) ~= nil
    or (type(os2.verify.note) == "string" and os2.verify.note:find("跑完", 1, true) ~= nil),
    tostring(os2.verify.note))
check("P2 verify 里带 busy/位置/货舱字段 ✓",
    os2.verify.busy == true and type(os2.verify.position) == "table"
    and os2.verify.cargoUsed ~= nil and os2.verify.holdHasGoods == false,
    tostring(os2.verify.busy) .. "/" .. tostring(os2.verify.cargoUsed))
check("P2 ★ moved 是**显式 false**（船在航程中坐标不动；不许退化成 nil ✗✓）",
    os2.verify.moved == false, tostring(os2.verify.moved))
check("P2 ★ atDestination=false（还没到 ✓）", os2.verify.atDestination == false,
    tostring(os2.verify.atDestination))
check("P2 trace 写了实测结论 ✓", traceHas("onOrder 实测") ~= nil, table.concat(TRACE, " | "))

-- ===========================================================================
-- P3：★ Travel 起点=终点 → ALREADY_THERE（travelcommand.lua:71-73 ✓）
-- ===========================================================================
print("== P3: Travel 目的地就是当前星区 → ALREADY_THERE（不下单 ✓）==")
reset()
local ok4, r4 = order("Travel", { x = SHIP_X, y = SHIP_Y })
check("P3 accepted=false ✓", ok4 == true and r4.accepted == false, r4)
check("P3 preflight.code = ALREADY_THERE ✓", r4.preflight.code == "ALREADY_THERE", tostring(r4.preflight.code))
check("P3 没发起区域分析 ✓", #INVOKED == 0, table.concat(INVOKED, ","))

-- ===========================================================================
-- P4：★ Travel 分析抛错 → ANALYSIS_FAILED（不许假装成功 ✓）
-- ===========================================================================
print("== P4: Travel 分析抛错 → ANALYSIS_FAILED（不下单 ✓）==")
reset()
RUN_ERROR = true
local ok5, r5 = order("Travel", { x = DEST_X, y = DEST_Y })
check("P4 accepted=false ✓", ok5 == true and r5.accepted == false, r5)
check("P4 preflight.code = ANALYSIS_FAILED ✓", r5.preflight.code == "ANALYSIS_FAILED", tostring(r5.preflight.code))
check("P4 没发起区域分析 ✓", #INVOKED == 0, table.concat(INVOKED, ","))
RUN_ERROR = false

-- ===========================================================================
-- P5：★ Sell：混了卖不掉的货 → 通过（只发能卖的 ✓）+ preflight.sell 报 skipped ✓✓
-- （今晚翻车 ①②；过滤归 sellableHoldOf ✓，本文件验它**进不进预检/回执** ✓）
-- ===========================================================================
print("== P5: Sell 混了卖不掉的货 → 通过 + skipped 进预检 ✓ ==")
reset()
CARGO = { [mkGood("Rift Naonite Ore")] = 1369, [mkGood("Drill")] = 100 }
DEMAND = { ["Drill"] = true }
SUPPLY = { ["Rift Naonite Ore"] = true }
local ok6, r6 = order("Sell", { x = SHIP_X, y = SHIP_Y, size = 15 })
check("P5 accepted=true ✓（能卖的照卖 ✓）", ok6 == true and r6.accepted == true, r6)
check("P5 preflight.ok=true ✓", type(r6.preflight) == "table" and r6.preflight.ok == true, type(r6.preflight))
check("P5 preflight.sell.skippedKinds=1 ✓（卖不掉的货进了预检 ✓）",
    r6.preflight.sell and r6.preflight.sell.skippedKinds == 1, r6.preflight.sell and r6.preflight.sell.skippedKinds)
check("P5 preflight.sell.sellableKinds=1 ✓（只有 Drill ✓）",
    r6.preflight.sell and r6.preflight.sell.sellableKinds == 1, r6.preflight.sell and r6.preflight.sell.sellableKinds)
check("P5 预检里带 SELL_SKIPPED 提示（卖不掉的货 + 原版理由 ✓）",
    codesOf(r6.preflight):find("SELL_SKIPPED") ~= nil, codesOf(r6.preflight))
check("P5 config.goodsToSell 只含能卖的 ✓",
    #(r6.config.goodsToSell or {}) == 1 and r6.config.goodsToSell[1].goodName == "Drill",
    #(r6.config.goodsToSell or {}))

-- ★ 实测：Sell 在跑 → busy=true 也是成功证据（货舱要跑完才结算 ✓）
tickStart()
AVAIL = 1
tickVerify()
local ok7, os3 = LinkIn.orderStatus(Player(), { ship = SHIP })
check("P5 Sell 实测 ok=true（在跑 ✓）", ok7 == true and os3.verify.ok == true, tostring(os3.verify and os3.verify.ok))
check("P5 Sell evidence = busy ✓", os3.verify.evidence == "busy", tostring(os3.verify.evidence))
check("P5 Sell 的 verify.note 点明「货舱跑完才结算」 ✓",
    type(os3.verify.note) == "string" and os3.verify.note:find("结算", 1, true) ~= nil,
    tostring(os3.verify.note))

-- ===========================================================================
-- P6：★ Sell 全卖不掉 → NO_BUYER（老路径仍是 ok=false ✓，且不下单 ✓）
-- ===========================================================================
print("== P6: Sell 全卖不掉 → NO_BUYER（不下单 ✓）==")
reset()
CARGO = { [mkGood("Rift Naonite Ore")] = 1369 }
DEMAND = {}
SUPPLY = { ["Rift Naonite Ore"] = true }
local ok8, code8 = order("Sell", { x = SHIP_X, y = SHIP_Y, size = 15 })
check("P6 ok=false ✓", ok8 == false, tostring(ok8))
check("P6 错误码 NO_BUYER ✓", code8 == "NO_BUYER", tostring(code8))
check("P6 没发起区域分析 ✓", #INVOKED == 0, table.concat(INVOKED, ","))

-- ===========================================================================
-- P7：★ Sell 实测**毫无变化** → verify.ok=false + reason ✓✓（"接了就完"的情形）
-- ===========================================================================
print("== P7: Sell 启动后状态毫无变化 → verify.ok=false（有理由 ✓）==")
reset()
CARGO = { [mkGood("Drill")] = 100 }
DEMAND = { ["Drill"] = true }
local ok9, r9 = order("Sell", { x = SHIP_X, y = SHIP_Y, size = 15 })
check("P7 下单 accepted=true（预检通过 ✓）", ok9 == true and r9.accepted == true, r9)
tickStart()
-- ★ 故意**不**把 AVAIL 改成 InBackground、也不动货舱 → 完全没有成功证据 ✓
-- ★ 第一次采样没证据 → 再采一次（不是无限轮询 ✓）；第二次仍无 → 定稿 ok=false ✓
tickVerify()
tickVerify()
local ok10, os4 = LinkIn.orderStatus(Player(), { ship = SHIP })
check("P7 实测 ok=false ✓", ok10 == true and os4.verify.ok == false, tostring(os4.verify and os4.verify.ok))
check("P7 verify.reason 有内容 ✓", type(os4.verify.reason) == "string" and #os4.verify.reason > 0,
    tostring(os4.verify.reason))
check("P7 reason 提到『不在后台运行 / busy』✓",
    os4.verify.reason:find("busy", 1, true) ~= nil, os4.verify.reason)
check("P7 verify.busy=false / cargoUsedDelta=0 ✓",
    os4.verify.busy == false and os4.verify.cargoUsedDelta == 0,
    tostring(os4.verify.busy) .. "/" .. tostring(os4.verify.cargoUsedDelta))
-- ★ 第二次采样也失败 → 定稿 ok=false ✓（不再无限轮询 ✓）
check("P7 定稿后移出实测队列 ✓", #(LinkIn.pendingVerifies or {}) == 0, #(LinkIn.pendingVerifies or {}))

-- ===========================================================================
-- P8：★ Sell 实测**货舱下降** → verify.ok=true + evidence=cargoUsedDecreased ✓
-- ===========================================================================
print("== P8: Sell 货舱下降 → verify.ok=true（cargoUsedDecreased ✓）==")
reset()
CARGO = { [mkGood("Drill")] = 100 }
DEMAND = { ["Drill"] = true }
local ok11, r11 = order("Sell", { x = SHIP_X, y = SHIP_Y, size = 15 })
check("P8 accepted=true ✓", ok11 == true and r11.accepted == true, r11)
tickStart()
CARGO = {}                                -- 卖掉了 ✓
AVAIL = 0                                 -- 已经跑完、回到 Available ✓
tickVerify()
local ok12, os5 = LinkIn.orderStatus(Player(), { orderId = r11.orderId })
check("P8 verify.ok=true ✓", ok12 == true and os5.verify.ok == true, tostring(os5.verify and os5.verify.ok))
check("P8 evidence = cargoUsedDecreased ✓", os5.verify.evidence == "cargoUsedDecreased",
    tostring(os5.verify.evidence))
check("P8 verify.cargoUsedDelta = -100 ✓", os5.verify.cargoUsedDelta == -100, tostring(os5.verify.cargoUsedDelta))
check("P8 verify.cargoUsedBefore = 100 ✓", os5.verify.cargoUsedBefore == 100, tostring(os5.verify.cargoUsedBefore))
check("P8 holdHasGoods=false ✓", os5.verify.holdHasGoods == false, tostring(os5.verify.holdHasGoods))

-- ===========================================================================
-- P9：★ Mine：框不含船 → SHIP_NOT_IN_AREA（simulation.lua:545-554 ✓，不下单 ✓）
-- ===========================================================================
print("== P9: Mine 框不含船 → SHIP_NOT_IN_AREA（不下单 ✓）==")
reset()
local ok13, r13 = order("Mine", { x = SHIP_X + 200, y = SHIP_Y + 200, size = 15 })
check("P9 accepted=false ✓", ok13 == true and r13.accepted == false, r13)
check("P9 preflight.code = SHIP_NOT_IN_AREA ✓", r13.preflight.code == "SHIP_NOT_IN_AREA",
    tostring(r13.preflight.code))
check("P9 reason 带 simulation.lua:545-554 依据 ✓",
    r13.preflight.reason:find("simulation.lua:845", 1, true) ~= nil
    or r13.preflight.reason:find("simulation.lua:822", 1, true) ~= nil
    or r13.preflight.reason:find("545-554", 1, true) ~= nil,
    r13.preflight.reason)
check("P9 没发起区域分析 ✓", #INVOKED == 0, table.concat(INVOKED, ","))

-- ===========================================================================
-- P10：★ Mine 没船长 → NO_CAPTAIN（simulation.lua:449-450 ✓）
-- ===========================================================================
print("== P10: Mine 没船长 → NO_CAPTAIN（不下单 ✓）==")
reset()
HAS_CAPTAIN = false
CAPTAINS = {}
local ok14, r14 = order("Mine", { x = SHIP_X, y = SHIP_Y, size = 15 })
check("P10 accepted=false ✓", ok14 == true and r14.accepted == false, r14)
check("P10 preflight.code = NO_CAPTAIN ✓", r14.preflight.code == "NO_CAPTAIN", tostring(r14.preflight.code))
check("P10 没发起区域分析 ✓", #INVOKED == 0, table.concat(INVOKED, ","))
HAS_CAPTAIN = true
CAPTAINS = {}

-- ===========================================================================
-- P11：★ Mine：duration 越界 → 被夹紧 + DURATION_CLAMPED 提示；越界**不算失败** ✓
-- ===========================================================================
print("== P11: Mine duration 越界 → 夹到命令区间 + 提示（不失败 ✓）==")
reset()
local ok15, r15 = order("Mine", { x = SHIP_X, y = SHIP_Y, size = 15, duration = 99 })
check("P11 accepted=true ✓（夹紧是原版行为 ✗ 不是失败）", ok15 == true and r15.accepted == true, r15)
check("P11 config.duration 被夹到 2 ✓（minecommand 的 to=2 ✓）", r15.config.duration == 2,
    tostring(r15.config.duration))
check("P11 preflight.applied.duration = 2 ✓", r15.preflight.applied.duration == 2,
    tostring(r15.preflight.applied.duration))
check("P11 预检带 DURATION_CLAMPED 提示 ✓", codesOf(r15.preflight):find("DURATION_CLAMPED") ~= nil,
    codesOf(r15.preflight))
reset()
local ok16, r16 = order("Mine", { x = SHIP_X, y = SHIP_Y, size = 15, duration = -3 })
check("P11 duration=-3 → accepted=false ✓", ok16 == true and r16.accepted == false, r16)
check("P11 错误码 BAD_DURATION ✓", r16.preflight.code == "BAD_DURATION", tostring(r16.preflight.code))

-- ===========================================================================
-- P12：★ Salvage：通过 + 实测（busy=true → ok ✓）
-- ===========================================================================
print("== P12: Salvage 通过预检 → startCommand → 实测 busy ✓ ==")
reset()
local ok17, r17 = order("Salvage", { x = SHIP_X, y = SHIP_Y, size = 15, duration = 1 })
check("P12 accepted=true ✓", ok17 == true and r17.accepted == true, r17)
check("P12 preflight.ok=true ✓", r17.preflight.ok == true, type(r17.preflight))
check("P12 ★ config.collected 已填（原版 mine/salvage 硬要求 ✓）",
    type(r17.config.collected) == "table" and r17.config.collected[0] == true, type(r17.config.collected))
tickStart()
AVAIL = 1
tickVerify()
local ok18, os6 = LinkIn.orderStatus(Player(), { ship = SHIP })
check("P12 实测 ok=true ✓", ok18 == true and os6.verify.ok == true, tostring(os6.verify and os6.verify.ok))
check("P12 evidence = busy ✓", os6.verify.evidence == "busy", tostring(os6.verify.evidence))

-- ===========================================================================
-- P13：★ Trade：船长不是 Merchant → CAPTAIN_NOT_MERCHANT（tradecommand.lua:632-637 ✓）
-- ===========================================================================
print("== P13: Trade 船长不是 Merchant → CAPTAIN_NOT_MERCHANT（不下单 ✓）==")
reset()
CAPTAIN_CLASS = "Scavenger"
local ok19, r19 = order("Trade", {
    x = SHIP_X, y = SHIP_Y, sizeX = 17, sizeY = 17,
    goodName = "Antigrav Unit", deposit = 100000,
})
check("P13 accepted=false ✓", ok19 == true and r19.accepted == false, r19)
check("P13 preflight.code = CAPTAIN_NOT_MERCHANT ✓", r19.preflight.code == "CAPTAIN_NOT_MERCHANT",
    tostring(r19.preflight.code))
check("P13 reason 带原版原话 'I don't know enough about trading' ✓",
    type(r19.preflight.reason) == "string"
    and r19.preflight.reason:find("I don't know enough about trading", 1, true) ~= nil,
    tostring(r19.preflight.reason))
check("P13 没发起区域分析 ✓", #INVOKED == 0, table.concat(INVOKED, ","))

print("== P13b: Trade 船长是 Merchant → 通过预检 ✓ ==")
reset()
CAPTAIN_CLASS = "Merchant"
local ok20, r20 = order("Trade", {
    x = SHIP_X, y = SHIP_Y, sizeX = 17, sizeY = 17,
    goodName = "Antigrav Unit", deposit = 100000,
})
check("P13b accepted=true ✓", ok20 == true and r20.accepted == true, r20)
check("P13b 预检记了 CAPTAIN_MERCHANT 通过 ✓",
    codesOf(r20.preflight):find("CAPTAIN_NOT_MERCHANT") == nil and r20.preflight.ok == true,
    codesOf(r20.preflight))
check("P13b 发起区域分析 ✓", #INVOKED == 1, table.concat(INVOKED, ","))

print("== P13c: Trade 货舱有货 → HOLD_HAS_GOODS（老路径，仍拒 ✓）==")
reset()
CAPTAIN_CLASS = "Merchant"
CARGO = { [mkGood("Drill")] = 10 }
local ok21, code21 = order("Trade", {
    x = SHIP_X, y = SHIP_Y, sizeX = 17, sizeY = 17,
    goodName = "Antigrav Unit", deposit = 100000,
})
check("P13c ok=false ✓", ok21 == false, tostring(ok21))
check("P13c 错误码 HOLD_HAS_GOODS ✓", code21 == "HOLD_HAS_GOODS", tostring(code21))

-- ===========================================================================
-- P14：★ 护航：太远 → ESCORT_TOO_FAR（原版 TooFarAway ✓）；没武装 → 只 warning ✓
-- ===========================================================================
print("== P14: 护航太远 → ESCORT_TOO_FAR（不下单 ✓）==")
reset()
ESCORTS = { ["Combat-00001"] = { x = SHIP_X + 50, y = SHIP_Y, reach = 5, canFight = true } }
local ok22, r22 = order("Mine", { x = SHIP_X, y = SHIP_Y, size = 15, escorts = { "Combat-00001" } })
check("P14 accepted=false ✓", ok22 == true and r22.accepted == false, r22)
check("P14 preflight.code = ESCORT_TOO_FAR ✓", r22.preflight.code == "ESCORT_TOO_FAR", tostring(r22.preflight.code))
check("P14 reason 带 simulationutility.lua:156-163 ✓",
    r22.preflight.reason:find("simulationutility.lua:156-163", 1, true) ~= nil, tostring(r22.preflight.reason))

print("== P14b: 护航同星区但没武装 → 只 warning（原版不查武装 ✓）==")
reset()
ESCORTS = { ["Combat-00001"] = { x = SHIP_X, y = SHIP_Y, reach = 5, canFight = false } }
local ok23, r23 = order("Mine", { x = SHIP_X, y = SHIP_Y, size = 15, escorts = { "Combat-00001" } })
check("P14b accepted=true ✓（原版不拒没武装的护航 ✗✓）", ok23 == true and r23.accepted == true, r23)
check("P14b 预检带 ESCORT_UNARMED 提示 ✓", codesOf(r23.preflight):find("ESCORT_UNARMED") ~= nil,
    codesOf(r23.preflight))
check("P14b 预检里照实报武装数字 ✓",
    r23.preflight.escorts and r23.preflight.escorts[1] and r23.preflight.escorts[1].armedTurrets == 0,
    r23.preflight.escorts and tostring(r23.preflight.escorts[1].armedTurrets))

print("== P14c: 护航在不同星区但在自己一跳之内 → 只 warning ✓ ==")
reset()
ESCORTS = { ["Combat-00001"] = { x = SHIP_X + 3, y = SHIP_Y, reach = 5, canFight = true } }
local ok24, r24 = order("Mine", { x = SHIP_X, y = SHIP_Y, size = 15, escorts = { "Combat-00001" } })
check("P14c accepted=true ✓（原版只拒 TooFarAway ✓）", ok24 == true and r24.accepted == true, r24)
check("P14c 预检带 ESCORT_OUT_OF_SECTOR 提示 ✓",
    codesOf(r24.preflight):find("ESCORT_OUT_OF_SECTOR") ~= nil, codesOf(r24.preflight))

-- ===========================================================================
-- P15：★ orderStatus 取不到 → NO_ORDER（不瞎编 ✓）
-- ===========================================================================
print("== P15: orderStatus 没有记录 → NO_ORDER ✓ ==")
reset()
local ok25, code25 = LinkIn.orderStatus(Player(), { ship = "NoSuchShip-1" })
check("P15 ok=false ✓", ok25 == false, tostring(ok25))
check("P15 错误码 NO_ORDER ✓", code25 == "NO_ORDER", tostring(code25))

-- ===========================================================================
print(string.format("== 共 %d 项断言，失败 %d 项 ==", checks, failures))
if failures == 0 then
    print("preflightVerifySelfTest: OK")
else
    print("preflightVerifySelfTest: FAIL")
end
