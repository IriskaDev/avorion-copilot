-- _trade_evaluate_selftest.lua —— 贸易评估原子（query what="tradeEvaluate"）的离线自检 ✓ 2026-10-18
--
-- 不开游戏就能验：把游戏 API 全换成替身（run / command:calculatePrediction / ShipDatabaseEntry / goods ✓），
-- 然后**真的调** data/scripts/net/link_in.lua 里的 CopilotLinkIn.tradeEvaluate（以及 onQuery 的分发 ✓）。
--
-- 断言点（对应主人的规格 ✓）：
--   (a) 排序键 = netProfitLow / 停留小时数（profitPerHour）✓ —— 且**故意构造**净收益大、单位时间反而小的
--       一对（A: net 1910 / 8.33h；B: net 975 / 0.33h）→ 必须 B 在前 ✓✓
--   (b) flights.from == 0 → rejected（EMPTY_RUN）+ 原因 ✓
--   (c) 伏击概率 > 0.10 → rejected（RISK_OVER_GATE）+ 原因 ✓
--   (d) 风险算不出来（attackChance=nil）→ rejected（RISK_UNKNOWN）、attackChance **留 nil**（不是 0 ✗✓）、
--       netProfit/profitPerHour 照算但不填 0 ✓
--   (e) 组合上限：6 框 × 4 商品 × 3 本金 = 72 > 60 → TOO_MANY_COMBINATIONS，且**一次预测都没跑** ✓
--   (f) 与单次 predict **逐字一致** ✓（同框同商品同本金 → 净收益/风险/航班数/派生 profitPerHour 全等 ✓）
--   (g) 一个框只跑**一次** run() ✓（3 框 × 2 商品 × 2 本金 = 12 组合 → run 恰好 3 次 ✓）
--   (h) 非法输入明确报错（框 > 6 / 本金 > 3 / 形状非法 / 缺参数 ✓）；不含船的框标 SHIP_NOT_IN_AREA 不中断 ✓
--   (i) goodsFilter 生效；全部不匹配 → 框级 GOODS_FILTER_MATCHED_NOTHING ✓
--   (j) 不含 recommendation / orderHint / bestRouteName 等"替你选"的字段 ✗✓
--   (k) caps 自声明里真的有 tradeEvaluate + tradeEvaluateParams ✓
--
-- 跑法（★ 必须在 mod 仓库根跑，脚本按相对路径读文件 ✓）：
--   native\harness\lua.exe native\harness\_trade_evaluate_selftest.lua

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

local function near(a, b)
    if a == nil or b == nil then return false end
    return math.abs(a - b) < 1e-6
end

local SHIP, SHIP_X, SHIP_Y = "Trader-00001", -381, 57
local nRun, nPred = 0, 0
local CUR_ROUTES = {}
local TRACE = {}

-- ---------------------------------------------------------------------------
-- 替身数据：路线 / 每件商品的预测数字
-- ---------------------------------------------------------------------------

local function good(price, size)
    local g = { price = price, size = size }
    g.good = function(self) return self end
    return g
end

local GOODS = {}
for _, n in ipairs({ "A", "B", "C", "D", "E", "X1", "X2", "X3", "X4" }) do
    GOODS[n] = good(20.443, 1)
end

-- chance = 基准伏击概率（nil = 游戏**没给**这个数 ✓）；low/high = 每航班利润；
-- ff/ft = flights.from/to；ftime = 单班秒数；max = maxAvailable
local PRED = {}
local function defPred(name, chance, low, high, ff, ft, ftime, max)
    PRED[name] = { chance = chance, low = low, high = high, ff = ff, ft = ft, ftime = ftime, max = max }
end

local function setRoutes(names)
    CUR_ROUTES = {}
    for i, nm in ipairs(names) do
        CUR_ROUTES[i] = {
            name = nm, lowest = -0.06, highest = 0.16, profitPerSize = 18,
            from = { x = SHIP_X + i, y = SHIP_Y },
            to = { x = SHIP_X + i + 3, y = SHIP_Y },
        }
    end
end

-- ---------------------------------------------------------------------------
-- 游戏 API 的替身 ✓
-- ---------------------------------------------------------------------------

CopilotRpc = { trace = function(line) TRACE[#TRACE + 1] = tostring(line) end }

function run(factionIndex, shipName, ctype, area, callingPlayer)
    nRun = nRun + 1
    return shipName, ctype, area, {
        routes = CUR_ROUTES, sectors = 289, reachable = 280, unreachable = 9,
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
    local out = {
        profitPerFlight = { from = p.low, to = p.high },
        flights = { from = p.ff, to = p.ft },
        flightTime = { value = p.ftime },
        maxAvailable = { value = p.max },
        transportedPerFlight = 100,
    }
    -- ★ chance=nil 时**没有** attackChance 键 → fillPrediction 拿到 nil → 风险未知 ✓
    if p.chance ~= nil then out.attackChance = { value = p.chance } end
    return out
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
    craft = nil,
    getShipPosition = function(self, name) return SHIP_X, SHIP_Y end,
    getKnownSector = function(self, x, y) return {} end,
    getValue = function(self, key) return "" end,
    getShipAvailability = function(self, name) return ShipAvailability.Available end,
    invokeFunction = function(self, path, fn, ...) return true end,
}
function Player() return player end

local LinkIn = dofile("data/scripts/net/link_in.lua")

local function boxAt(dx, dy, sx, sy)
    return { x = SHIP_X + (dx or 0), y = SHIP_Y + (dy or 0), sizeX = sx or 17, sizeY = sy or 17 }
end

-- ===========================================================================
-- T1：★ 排序键 = netProfitLow / 停留小时数（不是 netProfitLow ✗✓）
-- ===========================================================================
print("== T1: 排序键 = profitPerHour（净收益大但慢的必须排后面 ✓）==")
setRoutes({ "A", "B" })
-- A: p=0.05, low=200, fl=10, ftime=3000s → netLow=200*(9.5+0.05)=1910；hours=10*3000/3600=8.3333 → 229.2/h
-- B: p=0.05, low=500, fl=2,  ftime=600s  → netLow=500*(1.9+0.05)=975；  hours=2*600/3600=0.3333 → 2925/h
defPred("A", 0.05, 200, 220, 10, 10, 3000, 1000)
defPred("B", 0.05, 500, 520, 2, 2, 600, 600)
nRun, nPred = 0, 0
local ok1, r1 = LinkIn.tradeEvaluate(player, {
    what = "tradeEvaluate", ship = SHIP,
    boxes = { boxAt(0, 0) }, deposits = { 200000 },
})
check("T1 ok=true", ok1 == true, r1)
local e1, e2 = nil, nil
if ok1 == true then
    check("T1 组合数 = 2（1 框 × 2 商品 × 1 本金 ✓）", r1.combinationCount == 2, r1.combinationCount)
    check("T1 一个框只跑一次 run() ✓", nRun == 1, nRun)
    check("T1 两次预测（每组合一次 ✓）", nPred == 2, nPred)
    check("T1 results 有 2 条", #r1.results == 2, #r1.results)
    e1, e2 = r1.results[1], r1.results[2]
    check("T1 第 1 名 = B（单位时间 2925/h ✓，虽然净收益 975 < A 的 1910 ✗✓）",
        e1 and e1.goodName == "B", e1 and e1.goodName)
    check("T1 第 2 名 = A", e2 and e2.goodName == "A", e2 and e2.goodName)
    check("T1 B 的 netProfitLow=975（与 predict 口径一致 ✓）", e1 and near(e1.netProfitLow, 975), e1 and e1.netProfitLow)
    check("T1 A 的 netProfitLow=1910（比 B 大 ✓ —— 证明排序不是按它 ✗）",
        e2 and near(e2.netProfitLow, 1910), e2 and e2.netProfitLow)
    check("T1 A 的 profitPerHour≈229.17", e2 and near(e2.profitPerHour, 1910 / (10 * 3000 / 3600)),
        e2 and e2.profitPerHour)
    check("T1 B 的 profitPerHour≈2925", e1 and near(e1.profitPerHour, 975 / (2 * 600 / 3600)),
        e1 and e1.profitPerHour)
    check("T1 B 的 durationHours≈0.3333", e1 and near(e1.durationHours, 2 * 600 / 3600),
        e1 and e1.durationHours)
    check("T1 B 的排序键确实大于 A ✓",
        e1 and e2 and e1.profitPerHour > e2.profitPerHour, nil)
    check("T1 字段齐全（x/y/sizeX/sizeY/goodName/deposit/flightsFrom/flightsTo/"
        .. "profitPerFlightFrom/maxAvailable/attackChance/baseAttackChance/riskKnown/netProfitLow/netProfitHigh ✓）",
        e1 ~= nil and e1.x == SHIP_X and e1.y == SHIP_Y and e1.sizeX == 17 and e1.sizeY == 17
        and e1.deposit == 200000 and e1.flightsFrom == 2 and e1.flightsTo == 2
        and e1.profitPerFlightFrom == 500 and e1.maxAvailable == 600
        and e1.attackChance == 0.05 and e1.baseAttackChance == 0.05 and e1.riskKnown == true
        and e1.netProfitHigh ~= nil, e1)
    check("T1 不含 recommendation / orderHint / bestRouteName ✗✓",
        r1.recommendation == nil and r1.orderHint == nil and r1.bestRouteName == nil
        and r1.areaRanking == nil, "出现了'替你选'字段 ✗")
end

-- ===========================================================================
-- T2：★ 与单次 predict **逐字一致** ✓✓
-- ===========================================================================
print("== T2: 与单次 predict 逐字一致（同框同商品同本金 ✓）==")
local okP, rP = LinkIn.predict(player, {
    what = "predict", ship = SHIP, action = "Trade",
    x = SHIP_X, y = SHIP_Y, sizeX = 17, sizeY = 17,
    goodName = "B", deposit = 200000,
})
check("T2 predict ok=true", okP == true, rP)
if okP == true and ok1 == true and e1 ~= nil then
    local v = rP.value
    check("T2 netProfitLow 逐字相同 ✓", v.netProfitLow == e1.netProfitLow,
        tostring(v.netProfitLow) .. " vs " .. tostring(e1.netProfitLow))
    check("T2 netProfitHigh 逐字相同 ✓", v.netProfitHigh == e1.netProfitHigh,
        tostring(v.netProfitHigh) .. " vs " .. tostring(e1.netProfitHigh))
    check("T2 flights.from / to 逐字相同 ✓",
        v.flights.from == e1.flightsFrom and v.flights.to == e1.flightsTo,
        tostring(v.flights.from) .. " vs " .. tostring(e1.flightsFrom))
    check("T2 profitPerFlight.from 逐字相同 ✓", v.profitPerFlight.from == e1.profitPerFlightFrom,
        tostring(v.profitPerFlight.from) .. " vs " .. tostring(e1.profitPerFlightFrom))
    check("T2 maxAvailable 逐字相同 ✓", v.maxAvailable == e1.maxAvailable,
        tostring(v.maxAvailable) .. " vs " .. tostring(e1.maxAvailable))
    check("T2 attackChance 逐字相同 ✓", rP.risk.attackChance == e1.attackChance,
        tostring(rP.risk.attackChance) .. " vs " .. tostring(e1.attackChance))
    check("T2 baseAttackChance 逐字相同 ✓", rP.risk.baseAttackChance == e1.baseAttackChance,
        tostring(rP.risk.baseAttackChance) .. " vs " .. tostring(e1.baseAttackChance))
    check("T2 profitBasis 逐字相同 ✓", v.profitBasis == e1.profitBasis,
        tostring(v.profitBasis) .. " vs " .. tostring(e1.profitBasis))
    local derived = v.netProfitLow / (v.flights.to * tonumber(v.flightTime) / 3600)
    check("T2 派生 profitPerHour == netProfitLow/(flightsTo×flightTime/3600) ✓",
        near(e1.profitPerHour, derived), tostring(e1.profitPerHour) .. " vs " .. tostring(derived))
end

-- ===========================================================================
-- T3：★ 丢掉的必须说明：空跑 / 超闸门 / 风险算不出来（不填 0 ✓）
-- ===========================================================================
print("== T3: rejected —— 空跑 / 超闸门 / 风险未知（不填 0 ✓）==")
setRoutes({ "C", "D", "E" })
defPred("C", 0.35, 200, 220, 2, 2, 600, 600)    -- 超闸门
defPred("D", 0.05, 100, 120, 0, 0, 600, 0)      -- 空跑（flights 0→0）
defPred("E", nil, 500, 520, 2, 2, 600, 600)     -- 游戏没给伏击概率
nRun, nPred = 0, 0
local ok3, r3 = LinkIn.tradeEvaluate(player, {
    what = "tradeEvaluate", ship = SHIP,
    boxes = { boxAt(0, 0) }, deposits = { 100000 },
})
check("T3 ok=true", ok3 == true, r3)
if ok3 == true then
    check("T3 results 为空（三条全被拒 ✓）", #r3.results == 0, #r3.results)
    check("T3 rejected 有 3 条", #r3.rejected == 3, #r3.rejected)
    local byName = {}
    for _, x in ipairs(r3.rejected) do byName[x.goodName] = x end
    local c, d, e = byName["C"], byName["D"], byName["E"]
    check("T3 C 被拒：RISK_OVER_GATE ✓", c and c.reasonKind == "RISK_OVER_GATE", c and c.reasonKind)
    check("T3 C 的原因带概率与闸门 ✓",
        c and type(c.reason) == "string" and c.reason:find("0.35", 1, true) ~= nil
        and c.reason:find("0.1", 1, true) ~= nil, c and c.reason)
    check("T3 D 被拒：EMPTY_RUN（flights.from=0 ✓）", d and d.reasonKind == "EMPTY_RUN", d and d.reasonKind)
    check("T3 D 的 flightsFrom=0 且 profitPerHour 留 nil（不编数字 ✓）",
        d and d.flightsFrom == 0 and d.profitPerHour == nil,
        d and (tostring(d.flightsFrom) .. "/" .. tostring(d.profitPerHour)))
    check("T3 E 被拒：RISK_UNKNOWN ✓", e and e.reasonKind == "RISK_UNKNOWN", e and e.reasonKind)
    check("T3 E 的 riskKnown=false ✓", e and e.riskKnown == false, e and e.riskKnown)
    check("T3 E 的 attackChance = **nil**（绝不是 0 ✗✓）", e and e.attackChance == nil,
        e and tostring(e.attackChance))
    check("T3 E 仍给出 netProfitLow=1000（未做风险调整口径 ✓，不是 0 ✗）",
        e and near(e.netProfitLow, 1000), e and e.netProfitLow)
    check("T3 E 的 profitPerHour≈3000（能算的照算 ✓）", e and near(e.profitPerHour, 3000),
        e and e.profitPerHour)
    check("T3 E 的 profitBasis 明说 chance unknown ✓",
        e and type(e.profitBasis) == "string" and e.profitBasis:find("chance unknown", 1, true) ~= nil,
        e and e.profitBasis)
    check("T3 E 的原因提到'不填 0' ✓",
        e and type(e.reason) == "string" and e.reason:find("不填 0", 1, true) ~= nil, e and e.reason)
end

-- ===========================================================================
-- T4：★ 一个框只跑一次 run()（组合数 ≠ 分析次数 ✓）
-- ===========================================================================
print("== T4: 3 框 × 2 商品 × 2 本金 = 12 组合 → run 恰好 3 次 ✓ ==")
setRoutes({ "A", "B" })
nRun, nPred = 0, 0
local ok4, r4 = LinkIn.tradeEvaluate(player, {
    what = "tradeEvaluate", ship = SHIP,
    boxes = { boxAt(0, 0), boxAt(2, 0), boxAt(-2, -2) },
    deposits = { 100000, 200000 },
})
check("T4 ok=true", ok4 == true, r4)
if ok4 == true then
    check("T4 combinationCount=12", r4.combinationCount == 12, r4.combinationCount)
    check("T4 run 恰好 3 次（每框一次 ✓，不是 12 次 ✗）", nRun == 3, nRun)
    check("T4 预测恰好 12 次（每组合一次 ✓）", nPred == 12, nPred)
    check("T4 结果 12 条（都过闸门 ✓）", #r4.results == 12, #r4.results)
    check("T4 三档框都含船 ✓", r4.boxes[1].containsShip == true and r4.boxes[2].containsShip == true
        and r4.boxes[3].containsShip == true, "")
end

-- ===========================================================================
-- T5：★ 组合上限（72 > 60 → TOO_MANY_COMBINATIONS，且一次预测都不跑 ✓）
-- ===========================================================================
print("== T5: 组合上限 60（TOO_MANY_COMBINATIONS + 建议缩参 ✓）==")
setRoutes({ "X1", "X2", "X3", "X4" })
for _, n in ipairs({ "X1", "X2", "X3", "X4" }) do defPred(n, 0.05, 100, 120, 2, 2, 600, 600) end
nRun, nPred = 0, 0
local ok5, code5, why5 = LinkIn.tradeEvaluate(player, {
    what = "tradeEvaluate", ship = SHIP,
    boxes = { boxAt(0, 0), boxAt(2, 0), boxAt(4, 0), boxAt(-2, 0), boxAt(-4, 0), boxAt(-6, 0) },
    deposits = { 100000, 200000, 500000 },
})
check("T5 6 框 × 4 商品 × 3 本金 = 72 → ok=false ✓", ok5 == false, ok5)
check("T5 错误码 = TOO_MANY_COMBINATIONS ✓", code5 == "TOO_MANY_COMBINATIONS", tostring(code5))
check("T5 原因写明 72 与上限 60 ✓",
    type(why5) == "string" and why5:find("72", 1, true) ~= nil and why5:find("60", 1, true) ~= nil,
    why5)
check("T5 原因给缩参建议（boxes / deposit tiers / goodsFilter ✓）",
    type(why5) == "string" and why5:find("goodsFilter", 1, true) ~= nil, why5)
check("T5 超限时**一次预测都没跑**（nPred=0 ✓）", nPred == 0, nPred)
check("T5 但 6 个框都做了分析（nRun=6 ✓ —— 因为路线要跑完才知道 ✓）", nRun == 6, nRun)

-- 边界：5 框 × 4 商品 × 3 本金 = 60 = 上限 → 允许 ✓
nRun, nPred = 0, 0
local ok5b, r5b = LinkIn.tradeEvaluate(player, {
    what = "tradeEvaluate", ship = SHIP,
    boxes = { boxAt(0, 0), boxAt(2, 0), boxAt(4, 0), boxAt(-2, 0), boxAt(-4, 0) },
    deposits = { 100000, 200000, 500000 },
})
check("T5 正好 60 组合 → 允许 ✓", ok5b == true, r5b)
if ok5b == true then
    check("T5 60 组合 = 60 次预测 ✓", nPred == 60 and #r5b.results + #r5b.rejected == 60,
        tostring(nPred) .. "/" .. tostring(#r5b.results + #r5b.rejected))
    check("T5 combinationLimit=60 如实回显 ✓", r5b.combinationLimit == 60, r5b.combinationLimit)
end

-- ===========================================================================
-- T6：非法输入 → 明确报错（不猜、不自动缩 ✗）
-- ===========================================================================
print("== T6: 非法输入明确报错 ✓ ==")
setRoutes({ "A" })
nRun, nPred = 0, 0
local ok6a, code6a = LinkIn.tradeEvaluate(player, {
    what = "tradeEvaluate", ship = SHIP,
    boxes = { boxAt(0, 0), boxAt(2, 0), boxAt(4, 0), boxAt(-2, 0), boxAt(-4, 0), boxAt(-6, 0), boxAt(6, 0) },
    deposits = { 100000 },
})
check("T6 7 个框 → BAD_REQUEST ✓", ok6a == false and code6a == "BAD_REQUEST", tostring(code6a))
local ok6b, code6b = LinkIn.tradeEvaluate(player, {
    what = "tradeEvaluate", ship = SHIP,
    boxes = { boxAt(0, 0) }, deposits = { 1, 2, 3, 4 },
})
check("T6 4 档本金 → BAD_REQUEST ✓", ok6b == false and code6b == "BAD_REQUEST", tostring(code6b))
local ok6c, code6c, why6c = LinkIn.tradeEvaluate(player, {
    what = "tradeEvaluate", ship = SHIP,
    boxes = { boxAt(0, 0, 15, 15) }, deposits = { 100000 },
})
check("T6 非法形状 15x15 → BAD_REQUEST ✓", ok6c == false and code6c == "BAD_REQUEST", tostring(code6c))
check("T6 形状错误里列出合法形状 ✓",
    type(why6c) == "string" and why6c:find("17x17", 1, true) ~= nil, why6c)
local ok6d, code6d = LinkIn.tradeEvaluate(player, {
    what = "tradeEvaluate", ship = SHIP,
    boxes = { { x = SHIP_X, y = SHIP_Y } }, deposits = { 100000 },
})
check("T6 框缺 sizeX/sizeY → BAD_REQUEST ✓", ok6d == false and code6d == "BAD_REQUEST", tostring(code6d))
local ok6e, code6e = LinkIn.tradeEvaluate(player, {
    what = "tradeEvaluate", ship = SHIP, boxes = { boxAt(0, 0) },
})
check("T6 没给本金档 → BAD_REQUEST ✓", ok6e == false and code6e == "BAD_REQUEST", tostring(code6e))
check("T6 非法输入都没跑分析（nRun=0 ✓）", nRun == 0, nRun)

-- ===========================================================================
-- T7：goodsFilter + 全部不匹配
-- ===========================================================================
print("== T7: goodsFilter ✓ ==")
setRoutes({ "A", "B" })
nRun, nPred = 0, 0
local ok7, r7 = LinkIn.tradeEvaluate(player, {
    what = "tradeEvaluate", ship = SHIP,
    boxes = { boxAt(0, 0) }, deposits = { 100000 }, goodsFilter = { "A" },
})
check("T7 ok=true", ok7 == true, r7)
if ok7 == true then
    check("T7 只算 A（1 组合 ✓）", r7.combinationCount == 1 and #r7.results == 1
        and r7.results[1].goodName == "A", r7.combinationCount)
    check("T7 框上如实回报 routeCount=2 / 过滤后=1 ✓",
        r7.boxes[1].routeCount == 2 and r7.boxes[1].routeCountAfterGoodsFilter == 1,
        tostring(r7.boxes[1].routeCount) .. "/" .. tostring(r7.boxes[1].routeCountAfterGoodsFilter))
    check("T7 goodsFilter 原样回显 ✓", type(r7.goodsFilter) == "table" and r7.goodsFilter[1] == "A",
        r7.goodsFilter and r7.goodsFilter[1])
end
local ok7b, r7b = LinkIn.tradeEvaluate(player, {
    what = "tradeEvaluate", ship = SHIP,
    boxes = { boxAt(0, 0) }, deposits = { 100000 }, goodsFilter = { "Nope" },
})
check("T7b 过滤后没有路线 → ok=true（框级标错，不中断 ✓）", ok7b == true, r7b)
if ok7b == true then
    check("T7b 框级错误 = GOODS_FILTER_MATCHED_NOTHING ✓",
        r7b.boxes[1].error == "GOODS_FILTER_MATCHED_NOTHING", r7b.boxes[1].error)
    check("T7b 组合数 = 0 ✓", r7b.combinationCount == 0, r7b.combinationCount)
end

-- ===========================================================================
-- T8：不含船的框 → SHIP_NOT_IN_AREA（不跑分析、不中断整批 ✓）
-- ===========================================================================
print("== T8: 不含船的框 → SHIP_NOT_IN_AREA（其它框照算 ✓）==")
setRoutes({ "A" })
nRun, nPred = 0, 0
local ok8, r8 = LinkIn.tradeEvaluate(player, {
    what = "tradeEvaluate", ship = SHIP,
    boxes = { { x = 0, y = 0, sizeX = 17, sizeY = 17 }, boxAt(0, 0) },
    deposits = { 100000 },
})
check("T8 ok=true", ok8 == true, r8)
if ok8 == true then
    check("T8 第 1 框标 SHIP_NOT_IN_AREA ✓", r8.boxes[1].error == "SHIP_NOT_IN_AREA", r8.boxes[1].error)
    check("T8 第 1 框**没跑**分析（nRun=1 ✓）", nRun == 1, nRun)
    check("T8 第 2 框照算出一组结果 ✓", #r8.results == 1, #r8.results)
end

-- ===========================================================================
-- T9：onQuery 分发 + caps 自声明 ✓
-- ===========================================================================
print("== T9: onQuery 分发 / caps ✓ ==")
setRoutes({ "A" })
local ok9, r9 = LinkIn.onQuery({
    what = "tradeEvaluate", ship = SHIP,
    boxes = { boxAt(0, 0) }, deposits = { 200000 },
})
check("T9 what=tradeEvaluate 走通 onQuery ✓（契约 = true, payload ✓）", ok9 == true and type(r9) == "table"
    and type(r9.results) == "table", r9)
local okC, rC = LinkIn.onQuery({ what = "caps" })
check("T9 caps ok=true", okC == true, rC)
if okC == true then
    local has = false
    for _, w in ipairs(rC.what or {}) do if w == "tradeEvaluate" then has = true end end
    check("T9 caps.what 里有 tradeEvaluate ✓", has, table.concat(rC.what or {}, ","))
    check("T9 caps 带 tradeEvaluateParams ✓", type(rC.tradeEvaluateParams) == "table", rC.tradeEvaluateParams)
    check("T9 caps 仍带 predictParams / tradeRoutesParams（不退化 ✗）",
        type(rC.predictParams) == "table" and type(rC.tradeRoutesParams) == "table", "")
end

-- ===========================================================================
-- T10：体积（替身环境下的 JSON 字节 —— 与真实响应同形状 ✓）
-- ===========================================================================
print("== T10: 体积（60 组合满编）==")
do
    local JSON = dofile("data/scripts/lib/copilot/json.lua")
    setRoutes({ "X1", "X2", "X3", "X4" })
    local _, rb = LinkIn.tradeEvaluate(player, {
        what = "tradeEvaluate", ship = SHIP,
        boxes = { boxAt(0, 0), boxAt(2, 0), boxAt(4, 0), boxAt(-2, 0), boxAt(-4, 0) },
        deposits = { 100000, 200000, 500000 },
    })
    local okJ, txt = pcall(JSON.encode, rb)
    print(string.format("  [体积] 60 组合响应 = %d B（%s）", (okJ and #txt) or -1,
        okJ and "JSON 可编码 ✓" or tostring(txt)))
    check("T10 满编响应可 JSON 编码且 < 40 KB ✓", okJ and #txt < 40 * 1024, okJ and #txt)
end

-- ---------------------------------------------------------------------------
for _, line in ipairs(TRACE) do print("  [trace] " .. line) end
print(string.format("== 共 %d 项断言，失败 %d 项 ==", checks, failures))
if failures == 0 then
    print("tradeEvaluateSelfTest: OK")
else
    print("tradeEvaluateSelfTest: FAIL")
end
