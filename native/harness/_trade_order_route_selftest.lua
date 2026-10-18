-- _trade_order_route_selftest.lua —— 「order 的 Trade 路线查找」离线自检 ✓ 2026-10-18
--
-- 背景（真机血案 2026-10-18 12:53Z ✓）：
--   `tradeEvaluate` 查到 `Electro Magnet` → 7 秒后 `order` 同一框同一货 → 回执 risk = NO_ROUTE
--   → 游戏侧 `verify.ok=false busy=false`（什么都没做 ✗）。
--
-- 本文件守住的契约（主人钦点 ✓✓）：
--   (a) 两条路径共用**同一份**「框 → 路线清单」实现（tradeBoxRoutesOf ✓）：
--       同框同货 → tradeEvaluate 有 ⇒ onOrder **必能找到** ✓，而且**风险逐字相同** ✓✓
--   (b) onOrder 只跑**一次** `run()`（不再有"第三次采样" ✗✓）
--   (c) NO_ROUTE 的回执**必须带候选** ✓：noRoute.candidates（前 8 个）+ routeCount + didYouMean ✓
--   (d) 路线校验不过 ⇒ **一个字节都不发** ✗✓（不调 startAreaAnalysis、不排 pendingOrders ✓）
--   (e) 名字比较仍是**逐字**（原版 tradecommand.lua:743 ✓）；只是**提示** didYouMean，不改写 ✗✓
--
-- 跑法（★ 必须在 mod 仓库根跑，脚本按相对路径读文件 ✓）：
--   native\harness\lua.exe native\harness\_trade_order_route_selftest.lua

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

local SHIP, SHIP_X, SHIP_Y = "Trader-00001", -374, 34
local nRun, nPred = 0, 0
local CUR_ROUTES = {}
-- ★ 按**框的形状**给不同清单（真机事实：同一框心 17x17/29x11 有 Electro Magnet，
--   11x29 只有 Display/Scrap Metal ✓ —— 这就是"29x11 写成 11x29"血案的自证 ✓）
local SHAPE_ROUTES = {}
local TRACE = {}
local INVOKE_CALLS = {}

-- ---------------------------------------------------------------------------
-- 替身：商品 / 路线 / 预测
-- ---------------------------------------------------------------------------

local function good(price, size)
    local g = { price = price, size = size }
    g.good = function(self) return self end
    return g
end

local GOODS = {}
for _, n in ipairs({ "Electro Magnet", "Display", "Scrap Metal", "Antigrav Generator",
                     "G1", "G2", "G3", "G4", "G5", "G6", "G7", "G8", "G9", "G10" }) do
    GOODS[n] = good(20.443, 1)
end

-- 每件商品的预测数字（原版 calculatePrediction 的形状 ✓）
local PRED = {}
local function defPred(name, chance, low, high, ff, ft, ftime, max)
    PRED[name] = { chance = chance, low = low, high = high, ff = ff, ft = ft, ftime = ftime, max = max }
end

local function setRoutes(names, shapeKey)
    local list = {}
    for i, nm in ipairs(names) do
        list[i] = {
            name = nm, lowest = -0.06, highest = 0.16, profitPerSize = 18,
            from = { x = SHIP_X + i, y = SHIP_Y },
            to = { x = SHIP_X + i + 3, y = SHIP_Y },
        }
    end
    if shapeKey ~= nil then
        SHAPE_ROUTES[shapeKey] = list
    else
        CUR_ROUTES = list
    end
end

local function routesForShape(area)
    local w = area.upper.x - area.lower.x + 1
    local h = area.upper.y - area.lower.y + 1
    return SHAPE_ROUTES[w .. "x" .. h] or CUR_ROUTES
end

-- ---------------------------------------------------------------------------
-- 替身：游戏 API ✓
-- ---------------------------------------------------------------------------

CopilotRpc = { trace = function(line) TRACE[#TRACE + 1] = tostring(line) end }

function run(factionIndex, shipName, ctype, area, callingPlayer)
    nRun = nRun + 1
    return shipName, ctype, area, {
        routes = routesForShape(area), sectors = 289, reachable = 280, unreachable = 9,
        biggestFactionInArea = 1, reachableCoordinates = {},
    }, callingPlayer
end

local FAKE_COMMAND = {}

function FAKE_COMMAND:getAreaSize(ownerIndex, shipName)
    return { x = 17, y = 17 }, { x = 29, y = 11 }, { x = 11, y = 29 }
end

function FAKE_COMMAND:getConfigurableValues(ownerIndex, shipName)
    return {}
end

function FAKE_COMMAND:isShipRequiredInArea(ownerIndex, shipName)
    return true
end

function FAKE_COMMAND:getErrors(ownerIndex, shipName, area, config)
    return nil
end

function FAKE_COMMAND:calculatePrediction(ownerIndex, shipName, area, config)
    nPred = nPred + 1
    local p = PRED[config.goodName]
    if p == nil then
        -- ★ 原版在"清单里没这条"时就是这样（tradecommand.lua:762-765 ✓）
        return { attackChance = { value = 0 }, error = "No route selected." }
    end
    local out = {
        profitPerFlight = { from = p.low, to = p.high },
        flights = { from = p.ff, to = p.ft },
        flightTime = { value = p.ftime },
        maxAvailable = { value = p.max },
        transportedPerFlight = 100,
    }
    if p.chance ~= nil then out.attackChance = { value = p.chance } end
    return out
end

local CAPTAIN = { primaryClass = 3 }
function CAPTAIN:hasClass(want) return want == 3 end

local ENTRY = {}
function ENTRY:getCargo() return {} end
function ENTRY:getCaptain() return CAPTAIN end
function ENTRY:getFreeCargoSpace() return 3498 end
function ENTRY:getHyperspaceProperties() return 4.1, false end

function include(name)
    if name == "areaanalysis" then return nil end        -- 真的也返回 nil（它只定义全局 run ✓）
    if name == "commandfactory" then
        return { makeCommand = function(ctype) return FAKE_COMMAND end }
    end
    if name == "goods" then return GOODS end
    if name == "captainutility" then return { ClassType = { Merchant = 3, Miner = 1, Scavenger = 2 } } end
    if name == "copilot/card" then return { } end
    if name == "copilot/job" then return { } end
    if name == "copilot/trade" then return { } end
    error("unexpected include: " .. tostring(name))
end

function ShipDatabaseEntry(ownerIndex, name) return ENTRY end
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
    invokeFunction = function(self, path, fn, ...)
        INVOKE_CALLS[#INVOKE_CALLS + 1] = tostring(fn)
        return true
    end,
}
function Player() return player end

local LinkIn = dofile("data/scripts/net/link_in.lua")

local function reset()
    nRun, nPred = 0, 0
    INVOKE_CALLS = {}
    LinkIn.pendingOrders = {}
    LinkIn.pendingVerifies = {}
    LinkIn.orderRecords = {}
    LinkIn.lastOrderOf = {}
    LinkIn.orderSeq = 0
    LinkIn.orders = 0
    LinkIn.pendingOrders = {}
end

local function orderOf(goodName, extra)
    local d = {
        ship = SHIP, action = "Trade",
        x = SHIP_X, y = SHIP_Y, sizeX = 17, sizeY = 17,
        goodName = goodName, deposit = 1000000,
    }
    for k, v in pairs(extra or {}) do d[k] = v end
    return d
end

local function startedAnalysis()
    for _, fn in ipairs(INVOKE_CALLS) do
        if fn == "startAreaAnalysis" then return true end
    end
    return false
end

-- ===========================================================================
-- T1：★ 同框同货 —— tradeEvaluate 有 ⇒ onOrder **必能找到** ✓✓（同一份实现）
-- ===========================================================================
print("== T1: 同框同货 —— evaluate 有 ⇒ order 必找到（且风险逐字相同 ✓✓）==")
setRoutes({ "Electro Magnet", "Display" })
defPred("Electro Magnet", 0.05, 245000, 277400, 2, 2, 780, 3800)
defPred("Display", 0.05, 54900, 61000, 3, 5, 780, 500)
reset()

local okE, rE = LinkIn.tradeEvaluate(player, {
    what = "tradeEvaluate", ship = SHIP,
    boxes = { { x = SHIP_X, y = SHIP_Y, sizeX = 17, sizeY = 17 } }, deposits = { 1000000 },
})
check("T1 tradeEvaluate ok=true", okE == true, rE)
local ev = nil
if okE == true then
    for _, e in ipairs(rE.results) do if e.goodName == "Electro Magnet" then ev = e break end end
end
check("T1 evaluate 里有 Electro Magnet ✓", ev ~= nil, okE == true and #rE.results or rE)
local nRunEval = nRun
check("T1 evaluate 只跑 1 次 run()", nRunEval == 1, nRunEval)

nRun, nPred = 0, 0
local okO, rO = LinkIn.onOrder(orderOf("Electro Magnet"))
check("T1 onOrder ok=true（契约 = true, receipt ✓）", okO == true, rO)
check("T1 回执 accepted=true（真的下单了 ✓）", type(rO) == "table" and rO.accepted == true, rO)
check("T1 onOrder 只跑 **1 次** run()（没有『第三次采样』 ✗✓）", nRun == 1, nRun)
check("T1 确实发起了区域分析（startAreaAnalysis ✓）", startedAnalysis() == true,
    table.concat(INVOKE_CALLS, ","))
check("T1 排进了 startCommand 队列（pendingOrders=1 ✓）", #LinkIn.pendingOrders == 1, #LinkIn.pendingOrders)
check("T1 回执 risk.known=true ✓（不再是 NO_ROUTE ✗）",
    type(rO.risk) == "table" and rO.risk.known == true, rO.risk and rO.risk.unknownReason)
check("T1 回执 risk.attackChance == evaluate 的 attackChance（**同一份分析** ✓✓）",
    type(rO.risk) == "table" and ev ~= nil and rO.risk.attackChance == ev.attackChance,
    tostring(rO.risk and rO.risk.attackChance) .. " vs " .. tostring(ev and ev.attackChance))
check("T1 回执 risk.baseAttackChance 与 evaluate 相同 ✓",
    type(rO.risk) == "table" and ev ~= nil and rO.risk.baseAttackChance == ev.baseAttackChance,
    tostring(rO.risk and rO.risk.baseAttackChance) .. " vs " .. tostring(ev and ev.baseAttackChance))
check("T1 预检里有 TRADE_ROUTE ok=true ✓", (function()
    for _, c in ipairs((rO.preflight or {}).checks or {}) do
        if c.name == "TRADE_ROUTE" and c.ok == true then return true end
    end
    return false
end)(), rO.preflight)
check("T1 预检 trade 段带候选清单 ✓（routeCount=2 ✓）",
    type(rO.preflight) == "table" and type(rO.preflight.trade) == "table"
    and rO.preflight.trade.routeCount == 2, rO.preflight and rO.preflight.trade)

-- ===========================================================================
-- T2：★ 名字不匹配 → NO_ROUTE + 候选（前 8 个）+ didYouMean，且**什么都不发** ✓✓
-- ===========================================================================
print("== T2: 名字不匹配 → NO_ROUTE + 候选清单 ✓（一个字节都不发 ✗✓）==")
setRoutes({ "Electro Magnet", "Display" })
reset()
local okN, rN = LinkIn.onOrder(orderOf("Electro Magnets"))    -- 单复数不同 ✗
check("T2 onOrder ok=true（回执契约，不是 RPC 崩 ✓）", okN == true, rN)
check("T2 accepted=false（**没有下单** ✓）", type(rN) == "table" and rN.accepted == false, rN)
check("T2 executed=false", rN.executed == false, rN.executed)
check("T2 error 以 NO_ROUTE 开头 ✓",
    type(rN.error) == "string" and string.sub(rN.error, 1, 8) == "NO_ROUTE", rN.error)
check("T2 noRoute.candidates == 该框此刻的 2 条路线 ✓（顺序也照原版清单 ✓）",
    type(rN.noRoute) == "table" and type(rN.noRoute.candidates) == "table"
    and #rN.noRoute.candidates == 2 and rN.noRoute.candidates[1] == "Electro Magnet"
    and rN.noRoute.candidates[2] == "Display", rN.noRoute)
check("T2 noRoute.routeCount == 2", rN.noRoute.routeCount == 2, rN.noRoute.routeCount)
check("T2 didYouMean 给单复数提示（但**不改写**单 ✗✓）",
    rN.noRoute.didYouMean == nil, rN.noRoute.didYouMean)   -- 单复数**不**猜 ✓（逐字口径）
check("T2 **没有**发起区域分析 ✗✓", startedAnalysis() == false, table.concat(INVOKE_CALLS, ","))
check("T2 **没有**排 startCommand ✗✓", #LinkIn.pendingOrders == 0, #LinkIn.pendingOrders)
check("T2 拒绝时为给候选跑了 1 次 run()、为兄弟框再跑 2 次（最多 3 次 ✓）、零次预测 ✓",
    nRun == 3 and nPred == 0, string.format("run=%d pred=%d", nRun, nPred))
check("T2 hint 指向候选清单 ✓",
    type(rN.hint) == "string" and string.find(rN.hint, "noRoute.candidates", 1, true) ~= nil, rN.hint)

-- 大小写 / 首尾空格 → 给 didYouMean（仍是同一个名字 ✓），但不改写 ✓
reset()
local okN2, rN2 = LinkIn.onOrder(orderOf("electro magnet"))
check("T2b 大小写不同 → 仍 NO_ROUTE（原版逐字 ✓）",
    type(rN2) == "table" and rN2.accepted == false
    and type(rN2.error) == "string" and string.sub(rN2.error, 1, 8) == "NO_ROUTE", rN2.error)
check("T2b didYouMean == 'Electro Magnet' ✓（只提示 ✗ 不改写）",
    rN2.noRoute.didYouMean == "Electro Magnet", rN2.noRoute.didYouMean)
check("T2b 仍然什么都没发 ✗✓", startedAnalysis() == false and #LinkIn.pendingOrders == 0, nil)

-- ===========================================================================
-- T3：★ 候选上限 = 8（原版最多 4 条，但接口按主人要求留 8 ✓）
-- ===========================================================================
print("== T3: 候选上限 8 ✓ ==")
setRoutes({ "G1", "G2", "G3", "G4", "G5", "G6", "G7", "G8", "G9", "G10" })
for i = 1, 10 do defPred("G" .. i, 0.05, 100, 120, 2, 2, 600, 500) end
reset()
local okL, rL = LinkIn.onOrder(orderOf("Electro Magnet"))
check("T3 10 条路线时 NO_ROUTE ✓", type(rL) == "table" and rL.accepted == false, rL)
check("T3 noRoute.candidates 恰好 8 个 ✓", #rL.noRoute.candidates == 8, #rL.noRoute.candidates)
check("T3 candidates[1..3] = G1/G2/G3 ✓",
    rL.noRoute.candidates[1] == "G1" and rL.noRoute.candidates[2] == "G2"
    and rL.noRoute.candidates[3] == "G3", table.concat(rL.noRoute.candidates, ","))
check("T3 noRoute.routeCount == 10（总数照实 ✓）", rL.noRoute.routeCount == 10, rL.noRoute.routeCount)

-- ===========================================================================
-- T4：★ 框里 0 条路线 → NO_ROUTE + candidates={}（不是 ERR_UNKNOWN ✓）
-- ===========================================================================
print("== T4: 框里 0 条路线 ✓ ==")
setRoutes({})
reset()
local okZ, rZ = LinkIn.onOrder(orderOf("Electro Magnet"))
check("T4 accepted=false + NO_ROUTE ✓", type(rZ) == "table" and rZ.accepted == false
    and string.sub(tostring(rZ.error), 1, 8) == "NO_ROUTE", rZ.error)
check("T4 candidates 是空表（不是 nil ✗）", type(rZ.noRoute) == "table"
    and type(rZ.noRoute.candidates) == "table" and #rZ.noRoute.candidates == 0, rZ.noRoute)
check("T4 routeCount == 0 ✓", rZ.noRoute.routeCount == 0, rZ.noRoute.routeCount)
check("T4 什么都没发 ✓", startedAnalysis() == false and #LinkIn.pendingOrders == 0, nil)

-- ===========================================================================
-- T5：★ predict（单框）也带候选 → 与 order 完全同一份 ✓
-- ===========================================================================
print("== T5: predict 的 NO_ROUTE 也带候选（同一份实现 ✓）==")
setRoutes({ "Display", "Scrap Metal" })
reset()
local okP, rP = LinkIn.predict(player, {
    what = "predict", ship = SHIP, action = "Trade",
    x = SHIP_X, y = SHIP_Y, sizeX = 17, sizeY = 17,
    goodName = "Electro Magnet", deposit = 1000000,
})
check("T5 predict ok=true + error 以 NO_ROUTE 开头 ✓",
    okP == true and type(rP.error) == "string" and string.sub(rP.error, 1, 8) == "NO_ROUTE", rP)
check("T5 predict 结果里 candidates 平铺可见 ✓（2 条 ✓）",
    type(rP.candidates) == "table" and #rP.candidates == 2
    and rP.candidates[1] == "Display" and rP.candidates[2] == "Scrap Metal", rP.candidates)
check("T5 predict 结果里 noRoute.box 带 lower/upper ✓",
    type(rP.noRoute) == "table" and type(rP.noRoute.box) == "table"
    and type(rP.noRoute.box.lower) == "table", rP.noRoute)

-- ===========================================================================
-- T6：★ 参数校验仍在（缺 goodName / deposit 时**先**报 BAD_REQUEST，不跑分析 ✓）
-- ===========================================================================
print("== T6: 参数校验优先 ✓ ==")
reset()
local okB, codeB = LinkIn.onOrder({ ship = SHIP, action = "Trade", x = SHIP_X, y = SHIP_Y,
    sizeX = 17, sizeY = 17, deposit = 1000000 })
check("T6 缺 goodName → BAD_REQUEST ✓", okB == false and codeB == "BAD_REQUEST", codeB)
reset()
local okB2, codeB2 = LinkIn.onOrder({ ship = SHIP, action = "Trade", x = SHIP_X, y = SHIP_Y,
    sizeX = 17, sizeY = 17, goodName = "Display", deposit = 0 })
check("T6 deposit=0 → BAD_REQUEST ✓", okB2 == false and codeB2 == "BAD_REQUEST", codeB2)
check("T6 两次都**没跑分析** ✓（参数校验在前 ✓）", nRun == 0, nRun)

-- ===========================================================================
-- T7：★ 回执里"同一份"的硬证据：order 的 risk 与 evaluate 的 risk 全等 ✓✓
-- ===========================================================================
print("== T7: 同框同货的 risk 全等（evaluate vs order ✓✓）==")
setRoutes({ "Antigrav Generator" })
defPred("Antigrav Generator", 0.08, 271900, 305000, 2, 2, 900, 900)
reset()
local okE7, rE7 = LinkIn.tradeEvaluate(player, {
    what = "tradeEvaluate", ship = SHIP,
    boxes = { { x = SHIP_X, y = SHIP_Y, sizeX = 17, sizeY = 17 } }, deposits = { 1500000 },
})
setRoutes({ "Antigrav Generator" })
reset()
local okO7, rO7 = LinkIn.onOrder(orderOf("Antigrav Generator", { deposit = 1500000 }))
local e7 = (okE7 == true) and rE7.results[1] or nil
check("T7 evaluate 与 order 都成功 ✓", okE7 == true and okO7 == true and rO7.accepted == true, rO7)
check("T7 attackChance 全等 ✓", e7 ~= nil and rO7.risk.attackChance == e7.attackChance,
    tostring(e7 and e7.attackChance) .. " vs " .. tostring(rO7.risk and rO7.risk.attackChance))
check("T7 baseAttackChance 全等 ✓", e7 ~= nil and rO7.risk.baseAttackChance == e7.baseAttackChance,
    tostring(e7 and e7.baseAttackChance) .. " vs " .. tostring(rO7.risk and rO7.risk.baseAttackChance))
check("T7 evaluate 的 netProfitLow 与 order 用的那份预测一致 ✓（同框同货同本金 ✓）",
    e7 ~= nil and e7.netProfitLow ~= nil and rO7.preflight.trade.routeCount == 1
    and rO7.preflight.trade.deposit == 1500000,
    tostring(e7 and e7.netProfitLow) .. " / routeCount=" .. tostring(rO7.preflight.trade.routeCount))
check("T7 order 的配置里 goodName/deposit 原样 ✓",
    rO7.config.goodName == "Antigrav Generator" and rO7.config.deposit == 1500000,
    tostring(rO7.config.goodName) .. "/" .. tostring(rO7.config.deposit))

-- ===========================================================================
-- T8：★ 真机血案本体 —— 「29x11 写成 11x29」→ NO_ROUTE + **兄弟框自证** ✓✓
--     （实测：同一框心 17x17 / 29x11 里有 Electro Magnet，11x29 里只有 Display / Scrap Metal）
-- ===========================================================================
print("== T8: 29x11 写成 11x29 → 兄弟框自证（swapHint ✓✓）==")
SHAPE_ROUTES = {}
setRoutes({ "Electro Magnet", "Display" })                 -- 17x17 与 29x11 的清单 ✓
setRoutes({ "Display", "Scrap Metal" }, "11x29")           -- 11x29 只有这两条 ✓
defPred("Electro Magnet", 0.05, 249660, 277400, 2, 2, 780, 3800)
reset()
local okS, rS = LinkIn.onOrder(orderOf("Electro Magnet", { sizeX = 11, sizeY = 29 }))
check("T8 accepted=false + NO_ROUTE ✓", type(rS) == "table" and rS.accepted == false
    and string.sub(tostring(rS.error), 1, 8) == "NO_ROUTE", rS and rS.error)
check("T8 noRoute.candidates = 11x29 框的真实清单（Display / Scrap Metal ✓）",
    type(rS.noRoute) == "table" and #rS.noRoute.candidates == 2
    and rS.noRoute.candidates[1] == "Display" and rS.noRoute.candidates[2] == "Scrap Metal",
    rS.noRoute and table.concat(rS.noRoute.candidates or {}, ","))
check("T8 siblingBoxes 有 3-1=2 个（另两种合法形状 ✓）",
    type(rS.noRoute.siblingBoxes) == "table" and #rS.noRoute.siblingBoxes == 2,
    rS.noRoute and #(rS.noRoute.siblingBoxes or {}))
check("T8 siblingBoxes 里 29x11 的 hasGood=true ✓（货在那边 ✗ 不在你给的形状里 ✓）",
    (function()
        for _, sb in ipairs(rS.noRoute.siblingBoxes or {}) do
            if sb.sizeX == 29 and sb.sizeY == 11 then return sb.hasGood == true end
        end
        return false
    end)(), rS.noRoute and rS.noRoute.siblingBoxes)
check("T8 siblingBoxes 里 17x17 的 hasGood=true ✓",
    (function()
        for _, sb in ipairs(rS.noRoute.siblingBoxes or {}) do
            if sb.sizeX == 17 and sb.sizeY == 17 then return sb.hasGood == true end
        end
        return false
    end)(), nil)
check("T8 swapHint 点名 29x11 / 11x29 ✓（'很容易写反' ✓）",
    type(rS.noRoute.swapHint) == "string"
    and string.find(rS.noRoute.swapHint, "29x11", 1, true) ~= nil
    and string.find(rS.noRoute.swapHint, "11x29", 1, true) ~= nil, rS.noRoute.swapHint)
check("T8 swapHint 也进了 error 串 ✓（一眼就能看到）",
    string.find(tostring(rS.error), "29x11", 1, true) ~= nil, rS.error)
check("T8 被拒时多跑了 2 次 run()（兄弟框，最多 2 次 ✓）；**没发起分析、没排单** ✓",
    nRun == 3 and startedAnalysis() == false and #LinkIn.pendingOrders == 0,
    string.format("run=%d", nRun))
check("T8 正向对照：同一个货换成 29x11 框 → 通过校验、算得出 risk ✓",
    (function()
        reset()
        local okOk, rOk = LinkIn.onOrder(orderOf("Electro Magnet", { sizeX = 29, sizeY = 11 }))
        return okOk == true and type(rOk) == "table" and rOk.accepted == true
            and type(rOk.risk) == "table" and rOk.risk.known == true
    end)(), nil)

print(string.format("== 共 %d 项断言，失败 %d 项 ==", checks, failures))
if failures == 0 then
    print("tradeOrderRouteSelfTest: OK")
else
    print("tradeOrderRouteSelfTest: FAIL")
    os.exit(1)
end
