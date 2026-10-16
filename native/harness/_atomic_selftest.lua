-- _atomic_selftest.lua —— 原子接口（list / predict / tradeRoutes）的离线自检 ✓
--
-- 不开游戏就能验：把游戏 API 全换成替身（run / command / ShipDatabaseEntry / goods ✓），
-- 然后**真的调** data/scripts/net/link_in.lua 里的 CopilotLinkIn.predict / tradeRoutes，
-- 以及 onQuery 的 list / ship 分支 ✓✓。
--
-- 断言点（对应主人的规格 ✓）：
--   · 列表接口**不含**每船完整状态 / 货舱明细 / 预测 ✗✓（只有 name/busy/hasCaptain/sector ✓）
--   · 单船接口**只查一艘** ✓（一张卡，不带别的船 ✗）
--   · 计算原子：单框只算一框 / 批量 N 只算 N 框 ✓（用 run() 调用次数当计数 ✓）
--   · 非法框（不含船）明确报错 SHIP_NOT_IN_AREA ✓
--   · 口径与旧路径（tradePlan）**逐字一致** ✓（predict 的净收益/风险 == tradePlan 的推荐 ✓）
--   · tradeRoutes 只回该框的路线与逐货数字，不排序/不推荐 ✗
--
-- 跑法：  native\harness\lua.exe native\harness\_atomic_selftest.lua

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

local SHIP, SHIP_X, SHIP_Y = "Trader-00001", -412, 73
local nRun, nPred = 0, 0        -- ★ 昂贵调用的计数（衡量"一框算一框" ✓）

-- ---------------------------------------------------------------------------
-- 游戏 API 的替身
-- ---------------------------------------------------------------------------

CopilotRpc = { trace = function() end }

local function good(price, size)
    local g = { price = price, size = size }
    g.good = function(self) return self end
    return g
end

local GOODS = {
    ["Drill"]         = good(20.443, 1),
    ["Antigrav Unit"] = good(25.391, 1),
}

-- chance = 基准伏击概率；low/high = 每航班利润下界/上界；flights = 航班数
local PRED = {
    ["Drill"]         = { chance = 0.05, low = 100, high = 120, flights = 2 },   -- 净 200
    ["Antigrav Unit"] = { chance = 0.06, low = 50,  high = 60,  flights = 1 },   -- 净 50
}

function run(factionIndex, shipName, ctype, area, callingPlayer)
    nRun = nRun + 1
    local routes = {
        { name = "Drill", lowest = -0.06, highest = 0.16, profitPerSize = 18,
          from = { x = 1, y = 1 }, to = { x = 2, y = 2 } },
    }
    return shipName, ctype, area, {
        routes = routes, sectors = 289, reachable = 280, unreachable = 9,
        biggestFactionInArea = 1, reachableCoordinates = {},
    }, callingPlayer
end

local FAKE_COMMAND = {}

function FAKE_COMMAND:getAreaSize(ownerIndex, shipName)
    return { x = 17, y = 17 }, { x = 29, y = 11 }, { x = 11, y = 29 }
end

function FAKE_COMMAND:getConfigurableValues(ownerIndex, shipName)
    return { duration = { from = 0.5, to = 2 } }
end

function FAKE_COMMAND:calculatePrediction(ownerIndex, shipName, area, config)
    nPred = nPred + 1
    local p = PRED[config.goodName]
    if p == nil then return { attackChance = { value = 0 }, error = "No route selected." } end
    local chance = p.chance
    if type(config.escorts) == "table" and #config.escorts > 0 then chance = chance * 0.5 end
    return {
        attackChance = { value = chance },
        profitPerFlight = { from = p.low, to = p.high },
        flights = { from = p.flights, to = p.flights },
        flightTime = { value = 700 },
        maxAvailable = { value = 5000 },
        transportedPerFlight = 100,
    }
end

function include(name)
    if name == "areaanalysis" then return nil end      -- 真的也返回 nil（它只定义全局 run ✓）
    if name == "commandfactory" then
        return { makeCommand = function(ctype) return FAKE_COMMAND end }
    end
    if name == "copilot/trade" then return dofile("data/scripts/lib/copilot/trade.lua") end
    if name == "copilot/job" then return dofile("data/scripts/lib/copilot/job.lua") end
    if name == "goods" then return GOODS end
    if name == "copilot/card" then return dofile("data/scripts/lib/copilot/card.lua") end
    if name == "captainutility" then return { ClassType = {} } end
    error("unexpected include: " .. tostring(name))
end

function ShipDatabaseEntry(ownerIndex, name)
    return {
        getFreeCargoSpace = function() return 10000 end,
        getCaptain = function() return {} end,
        getCargo = function() return {}, 5000 end,
        getTurrets = function() return {} end,
        getHyperspaceProperties = function() return 12, true end,
    }
end

ShipAvailability = { Available = 0, InBackground = 1 }
function valid(v) return v ~= nil end
function Balancing_GetSectorRichnessFactor(x, y) return 1.0 end
function Balancing_GetMaterialProbability(x, y) return {} end
function Balancing_InsideRing(x, y) return false end
function NumMaterials() return 7 end

local player = {
    index = 1,
    craft = nil,                                  -- ★ 玩家没在开船 ✓（list 里 piloted=nil ✓）
    getShipPosition = function(self, name) return SHIP_X, SHIP_Y end,
    getKnownSector = function(self, x, y) return {} end,
    getValue = function(self, key)
        if key == "copilot_auto_ships" then return "Trader-00001\nMiner-00001\n" end
        return ""
    end,
    getShipAvailability = function(self, name) return ShipAvailability.InBackground end,
}

local LinkIn = dofile("data/scripts/net/link_in.lua")

-- onQuery 顶部会调 Player()（游戏全局 ✓）—— 替身返回上面那张 player ✓
function Player() return player end

-- ---------------------------------------------------------------------------
-- ① 列表：只有 name/busy/hasCaptain/sector（索引级 ✓）—— 不含每船完整状态 ✗
-- ---------------------------------------------------------------------------
print("== ① list：索引级清单（绝不含每船完整状态）==")
local okL, rL = LinkIn.onQuery({ what = "list" })
check("① list ok=true", okL == true, rL)
if okL == true then
    check("① list 有两艘船（排除玩家在开的那条 ✓）", #rL.ships == 2, #rL.ships)
    local idxOk = true
    local forbidden = { "cargoUsed", "cargoCapacity", "freeCargoSpace", "depth", "actions",
        "turretCount", "holdHasGoods", "captainClass", "sectorFacts", "cargoState" }
    for _, s in ipairs(rL.ships) do
        if type(s.name) ~= "string" or s.busy == nil or s.hasCaptain == nil then idxOk = false end
        for _, f in ipairs(forbidden) do
            if s[f] ~= nil then idxOk = false break end
        end
    end
    check("① list 每条只有索引级字段（name/busy/hasCaptain/sector，无货舱/深度/动作/预测 ✓）", idxOk, "有船带了多余字段 ✗")
    check("① list 每条都有 sector（挑船要用 ✓）", rL.ships[1].sector ~= nil and rL.ships[1].sector.x == SHIP_X, "")
    check("① list 不含 fleetSnapshot 的完整卡（ships[1] 无 cargoUsed ✓）", rL.ships[1].cargoUsed == nil, rL.ships[1].cargoUsed)
end

-- ---------------------------------------------------------------------------
-- ② 单船：只查那一艘（一张卡，不带别的船 ✗）
-- ---------------------------------------------------------------------------
print("== ② ship：只查指定那一艘 ==")
local okS, rS = LinkIn.onQuery({ what = "ship", ship = SHIP })
check("② ship ok=true", okS == true, rS)
if okS == true then
    check("② ship 返回的是**这一艘**的卡（name 对 ✓）", rS.name == SHIP, rS.name)
    check("② ship 是**单卡**不是名册（无 .ships 数组 ✓）", rS.ships == nil, rS.ships)
    check("② ship 的完整卡有 actions（与 list 的索引级区分 ✓）", type(rS.actions) == "table", rS.actions)
end

-- ---------------------------------------------------------------------------
-- ③ tradeRoutes：某框内的路线 + 逐货数字（不排序/不推荐 ✗）
-- ---------------------------------------------------------------------------
print("== ③ tradeRoutes：某框内的贸易路线 ==")
local okT, rT = LinkIn.tradeRoutes(player, { ship = SHIP, x = SHIP_X, y = SHIP_Y, sizeX = 17, sizeY = 17 })
check("③ tradeRoutes ok=true", okT == true, rT)
if okT == true then
    check("③ box.containsShip=true", rT.box.containsShip == true, rT.box.containsShip)
    check("③ routeCount=1", rT.routeCount == 1, rT.routeCount)
    check("③ 路线名 = Drill", rT.routes[1] and rT.routes[1].name == "Drill", rT.routes[1] and rT.routes[1].name)
    check("③ 逐货数字在（basePrice/unitSize/profitPerSize ✓）",
        rT.routes[1] and rT.routes[1].basePrice == 20.443 and rT.routes[1].unitSize == 1
        and rT.routes[1].profitPerSize == 18, rT.routes[1] and rT.routes[1].basePrice)
    check("③ 不含预测（无 netProfit / attackChance ✗）", rT.routes[1] and rT.routes[1].netProfitLow == nil, "")
    check("③ 不含排序/推荐字段 ✗", rT.recommendation == nil and rT.areaRanking == nil, "")
end

-- ---------------------------------------------------------------------------
-- ④ predict 单框：只算一框 ✓（run 恰好 1 次 ✓）
-- ---------------------------------------------------------------------------
print("== ④ predict 单框（Trade）—— 只算一框 ==")
nRun, nPred = 0, 0
local okP, rP = LinkIn.predict(player, {
    what = "predict", ship = SHIP, action = "Trade",
    x = SHIP_X, y = SHIP_Y, sizeX = 17, sizeY = 17,
    goodName = "Drill", deposit = 752000,
})
check("④ predict 单框 ok=true", okP == true, rP)
if okP == true then
    check("④ box.containsShip=true", rP.box.containsShip == true, rP.box.containsShip)
    check("④ 单框只算一框（run 恰好 1 次 ✓）", nRun == 1, nRun)
    check("④ 风险 attackChance=0.05", rP.risk and rP.risk.attackChance == 0.05, rP.risk and rP.risk.attackChance)
    check("④ 风险标签 riskKind=tradeAmbushChance", rP.risk and rP.risk.riskKind == "tradeAmbushChance(whole task, this box)", rP.risk and rP.risk.riskKind)
    -- 口径（风险调整期望）：p=0.05, low=100, high=120, flights=2 →
    --   best = 200/240；exp = 0.95*200 + 0.05*100 = 195 / 0.95*240 + 0.05*120 = 234
    check("④ 净收益 netProfitLow=195（风险调整 ✓）", rP.value and rP.value.netProfitLow == 195, rP.value and rP.value.netProfitLow)
    check("④ 净收益 netProfitHigh=234（风险调整 ✓）", rP.value and rP.value.netProfitHigh == 234, rP.value and rP.value.netProfitHigh)
    check("④ bestCaseLow/High=200/240", rP.value and rP.value.bestCaseLow == 200 and rP.value.bestCaseHigh == 240,
        rP.value and (tostring(rP.value.bestCaseLow) .. "/" .. tostring(rP.value.bestCaseHigh)))
    check("④ profitBasis=netProfit(riskAdjusted)", rP.value and rP.value.profitBasis == "netProfit(riskAdjusted)", rP.value and rP.value.profitBasis)
    check("④ deposit 原样回显", rP.value and rP.value.deposit == 752000, rP.value and rP.value.deposit)
end

-- ---------------------------------------------------------------------------
-- ⑤ predict 批量 N=2：只算 N 框 ✓（run 恰好 2 次 ✓）
-- ---------------------------------------------------------------------------
print("== ⑤ predict 批量 N=2 —— 只算 N 框 ==")
nRun, nPred = 0, 0
local okB, rB = LinkIn.predict(player, {
    what = "predict", ship = SHIP, action = "Trade",
    boxes = {
        { x = SHIP_X, y = SHIP_Y, sizeX = 17, sizeY = 17, goodName = "Drill", deposit = 1000000 },
        { x = SHIP_X + 4, y = SHIP_Y, sizeX = 17, sizeY = 17, goodName = "Drill", deposit = 1000000 },
    },
})
check("⑤ 批量 ok=true", okB == true, rB)
if okB == true then
    check("⑤ boxCount=2", rB.boxCount == 2, rB.boxCount)
    check("⑤ 批量 N=2 只算 2 框（run 恰好 2 次 ✓）", nRun == 2, nRun)
    check("⑤ 每框独立（第 1 框含船 ✓）", rB.boxes[1] and rB.boxes[1].box.containsShip == true, "")
end

-- ---------------------------------------------------------------------------
-- ⑥ 非法框（不含船）→ 明确报错 SHIP_NOT_IN_AREA ✓
-- ---------------------------------------------------------------------------
print("== ⑥ 非法框：不含船 → SHIP_NOT_IN_AREA ==")
nRun, nPred = 0, 0
local okBad, codeBad, whyBad = LinkIn.predict(player, {
    what = "predict", ship = SHIP, action = "Trade",
    x = 0, y = 0, sizeX = 17, sizeY = 17, goodName = "Drill", deposit = 1000000,
})
check("⑥ 不含船 → ok=false + SHIP_NOT_IN_AREA", okBad == false and codeBad == "SHIP_NOT_IN_AREA", tostring(codeBad))
check("⑥ 不含船时不跑分析（run 0 次 ✓）", nRun == 0, nRun)

-- 批量里一个不含船 → 标出来，不中断整批 ✓
local okBad2, rBad2 = LinkIn.predict(player, {
    what = "predict", ship = SHIP, action = "Trade",
    boxes = {
        { x = 0, y = 0, sizeX = 17, sizeY = 17, goodName = "Drill", deposit = 1000000 },
        { x = SHIP_X, y = SHIP_Y, sizeX = 17, sizeY = 17, goodName = "Drill", deposit = 1000000 },
    },
})
check("⑥ 批量：不含船的框被标注 SHIP_NOT_IN_AREA（不中断整批 ✓）",
    okBad2 == true and rBad2.boxes[1].error == "SHIP_NOT_IN_AREA" and rBad2.boxes[2].box.containsShip == true,
    rBad2 and tostring(rBad2.boxes and rBad2.boxes[1] and rBad2.boxes[1].error))

-- ---------------------------------------------------------------------------
-- ⑦ 口径与旧路径一致：predict(同一框同一路线) == tradePlan 的推荐 ✓
-- ---------------------------------------------------------------------------
print("== ⑦ 口径一致：predict == tradePlan 推荐 ==")
local okTP, rTP = LinkIn.tradePlan(player, { ship = SHIP })
check("⑦ tradePlan ok=true", okTP == true, rTP)
if okTP == true and rTP.recommendation ~= nil then
    local rec = rTP.recommendation
    local okC, rC = LinkIn.predict(player, {
        what = "predict", ship = SHIP, action = "Trade",
        x = rec.x, y = rec.y, sizeX = rec.sizeX or 17, sizeY = rec.sizeY or 17,
        goodName = rec.goodName, deposit = rec.deposit,
    })
    check("⑦ predict 口径 ok=true", okC == true, rC)
    if okC == true then
        check("⑦ 净收益 low 与 tradePlan 推荐一致 ✓",
            rC.value.netProfitLow == rec.netProfitLow,
            tostring(rC.value.netProfitLow) .. " vs " .. tostring(rec.netProfitLow))
        check("⑦ 净收益 high 与 tradePlan 推荐一致 ✓",
            rC.value.netProfitHigh == rec.netProfitHigh,
            tostring(rC.value.netProfitHigh) .. " vs " .. tostring(rec.netProfitHigh))
        check("⑦ 伏击概率与 tradePlan 推荐一致 ✓",
            rC.risk.attackChance == rec.attackChance,
            tostring(rC.risk.attackChance) .. " vs " .. tostring(rec.attackChance))
        check("⑦ bestCase 与 tradePlan 推荐一致 ✓",
            rC.value.bestCaseLow == rec.bestCaseLow,
            tostring(rC.value.bestCaseLow) .. " vs " .. tostring(rec.bestCaseLow))
    end
end

-- ---------------------------------------------------------------------------
print(string.format("== 共 %d 项断言，失败 %d 项 ==", checks, failures))
if failures == 0 then
    print("atomicSelfTest: OK")
else
    print("atomicSelfTest: FAIL")
end
