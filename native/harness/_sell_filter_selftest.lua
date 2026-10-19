-- _sell_filter_selftest.lua —— 「Sell 订单前过滤」离线自检 ✓ 2026-10-17
--
-- 不开游戏就能验：把游戏 API 全换成替身，然后**真的调**
-- data/scripts/net/link_in.lua 里的 `CopilotLinkIn.onOrder({action="Sell", ...})` ✓✓。
--
-- 为什么要有它（今晚实机血案 ✓✓）：
--   `Salvager-00001` 舱里 2889 单位 / 24 种，含 `Rift Naonite Ore` 1369 单位 ✗；
--   `fleet_order{Sell}` 回执 `accepted:true executed:true` ✓，**一件没卖** ✗（busy:false、cargoUsed 不变）；
--   根因 = 原版对"清单里有货没人收"是**整单拒绝**：
--     `simulation.lua:557-566`  → `command:getErrors(...)` 有错 → sendChatMessage(Error) → **return** ✗
--     `sellcommand.lua:397-411` → 任一货"这里没需求"就 `return "There is no demand for 'X' here."` ✗
--   ⇒ 修法 = **订单前过滤**（只把有买家的货写进 config.goodsToSell ✓）+ 回执给 sellable/skipped ✓。
--
-- 断言（主人这一轮点明的两条 ✓）：
--   ① 清单里有卖不掉的货 → **只发能卖的** ✓ + `skipped` 把卖不掉的货与**原版原话**报出来 ✓✓
--   ② 全都卖不掉 → `NO_BUYER` 明确失败 ✓，**不下单**（不发起区域分析 ✓、不进队列 ✓）、不假装成功 ✗✓
--   ③ 默认值 = "整舱里**能卖的那些**"（对齐原版 UI 的 Select All ✓，不是"全舱全塞" ✗）
--   ④ 白名单两种形状都收（`{goodName,…}` 与**纯字符串** ✓）；点名却不存在的货 → BAD_REQUEST ✓
--
-- ⚠️ 这里的 `FAKE_COMMAND:getErrors` 只是**替身**（判据抄自 sellcommand.lua:326-412，
--    只保留本自检需要的那几条；原版英文原话逐字保留 ✓）。真实运行时调的是**原版命令实例**的
--    getErrors（link_in.lua 的 sellableHoldOf 里 `command:getErrors(...)` ✓），所以口径不是我定的 ✗。
--
-- 跑法（★ 必须在 mod 仓库根跑）：
--   build\harness\lua.exe native\harness\_sell_filter_selftest.lua

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

local SHIP, SHIP_X, SHIP_Y = "Salvager-00001", -372, 61
local CAP = 4000
local CARGO = {}      -- good 对象 → 数量 ✓
local DEMAND = {}     -- 有需求的货名 → true ✓
local SUPPLY = {}     -- 只被供应的货名 → true ✓
local nRun, nPred = 0, 0

local TRACE = {}
local INVOKED = {}    -- ★ 记下 onOrder 真的调了哪些 simulation 呼叫（用来证明"没下单"✓）

local function resetAll()
    CARGO, DEMAND, SUPPLY = {}, {}, {}
    nRun, nPred = 0, 0
    TRACE = {}
    INVOKED = {}
end

-- ---------------------------------------------------------------------------
-- 游戏 API 的替身 ✓
-- ---------------------------------------------------------------------------

CopilotRpc = { trace = function(line) TRACE[#TRACE + 1] = tostring(line) end }

-- ★ goods 索引（替身）：`Rift Naonite Ore` 就是今晚实机那个卖不掉的货 ✓
local GOODS = {
    ["Rift Naonite Ore"] = { price = 3, size = 0.025, tags = { naonite = true, ore = true, rich = true } },
    ["Drill"]            = { price = 40, size = 1 },
    ["Oxygen"]           = { price = 12, size = 1 },
    ["Antigrav Unit"]    = { price = 900, size = 2 },
}
for _, g in pairs(GOODS) do g.good = function(self) return self end end

-- ★ 与 link_in.lua 的 sellableHoldOf 同一口径：一次 run 就是一份**局部市场分析** ✓
function run(factionIndex, shipName, ctype, area, callingPlayer)
    nRun = nRun + 1
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
    return shipName, ctype, area, results, callingPlayer
end

local FAKE_COMMAND = {}

function FAKE_COMMAND:getAreaSize(ownerIndex, shipName)
    return { x = 15, y = 15 }            -- sellcommand.lua:414-416 ✓
end

function FAKE_COMMAND:calculatePrediction(ownerIndex, shipName, area, config)
    nPred = nPred + 1
    return {
        attackChance = { value = 0.05 },
        duration = 3600,
        yield = 10000,
        percentages = {},
        pricesPerGood = {},
    }
end

-- ★ 替身 getErrors：判据抄 sellcommand.lua:326-412（原版原话逐字保留 ✓）
function FAKE_COMMAND:getErrors(ownerIndex, shipName, area, config)
    local entry = ShipDatabaseEntry(ownerIndex, shipName)
    local captain = entry:getCaptain()
    local isMerchant = captain:hasClass("Merchant")
    local isSmuggler = captain:hasClass("Smuggler")

    -- :326-332 —— 不在 goodsindex 里的货卖不了
    for _, toSell in pairs(config.goodsToSell) do
        if GOODS[toSell.goodName] == nil then
            return string.format("I don't know how to sell '%s' here.", toSell.goodName)
        end
    end
    -- :336-347 —— 数量 0
    for _, toSell in pairs(config.goodsToSell) do
        if toSell.amount == 0 then
            return string.format("No amount for %s selected!", toSell.goodName)
        end
    end
    -- :350-371 —— 货在船上 / 数量够
    for _, toSell in pairs(config.goodsToSell) do
        local found = false
        for g, amount in pairs(CARGO) do
            if g.name == toSell.goodName then
                found = true
                if toSell.amount > amount then
                    return string.format("Not enough of %s aboard!", toSell.goodName)
                end
                break
            end
        end
        if not found then return "Cargo to sell isn't on the ship!" end
    end
    -- :397-411 —— ★ 区域需求（这一条就是今晚血案的元凶 ✓✓）
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
    if name == "copilot/card" then return { shipCard = function() return { cargoCapacity = CAP } end } end
    error("unexpected include: " .. tostring(name))
end

local CAPTAIN = { hasClass = function(self, cls) return false end }

function ShipDatabaseEntry(ownerIndex, name)
    return {
        getCargo = function() return CARGO, CAP end,
        getFreeCargoSpace = function() return CAP end,
        getCaptain = function() return CAPTAIN end,
    }
end

local player = {
    index = 1,
    getShipPosition = function(self, name) return SHIP_X, SHIP_Y end,
    getShipAvailability = function(self, name) return 0 end,
    invokeFunction = function(self, path, fn, ...) INVOKED[#INVOKED + 1] = fn end,
}
function Player() return player end
ShipAvailability = { Available = 0, InBackground = 1 }

local LinkIn = dofile("data/scripts/net/link_in.lua")

local function mkGood(name)
    local g = { name = name, stolen = false }
    g.displayName = function(self, n) return name end
    return g
end

local function namesOf(list)
    local out = {}
    for _, g in ipairs(list or {}) do out[#out + 1] = g.goodName end
    table.sort(out)
    return table.concat(out, ",")
end

local function traceHas(needle)
    for _, line in ipairs(TRACE) do
        if line:find(needle, 1, true) ~= nil then return line end
    end
    return nil
end

-- ===========================================================================
-- T1：★ 清单里有卖不掉的货 → **只发能卖的** + skipped 报出原版理由 ✓✓
--   夹具照今晚实机：Rift Naonite Ore（只被供应、没需求 ✗）+ Drill + Oxygen（有需求 ✓）
-- ===========================================================================
print("== T1: 一种货没人收（Rift Naonite Ore）→ 只发能卖的那几种 ✓ ==")
resetAll()
CARGO = {
    [mkGood("Rift Naonite Ore")] = 1369,
    [mkGood("Drill")] = 100,
    [mkGood("Oxygen")] = 50,
}
DEMAND = { ["Drill"] = true, ["Oxygen"] = true }
SUPPLY = { ["Rift Naonite Ore"] = true }
local ok1, r1 = LinkIn.onOrder({ ship = SHIP, action = "Sell", x = SHIP_X, y = SHIP_Y, size = 15 })
check("T1 下单成功（ok=true ✓）", ok1 == true and r1.accepted == true, r1)
if ok1 == true then
    local sent = r1.config and r1.config.goodsToSell or {}
    check("T1 ★ config.goodsToSell **只含能卖的 2 种** ✓（不含 Rift Naonite Ore ✗✓）",
        #sent == 2 and namesOf(sent) == "Drill,Oxygen", namesOf(sent))
    check("T1 sellable.kinds = 2 ✓", r1.sellable and r1.sellable.kinds == 2,
        r1.sellable and r1.sellable.kinds)
    check("T1 sellable.units = 150 ✓（100 + 50 ✓）", r1.sellable and r1.sellable.units == 150,
        r1.sellable and r1.sellable.units)
    check("T1 sellable.goods 里逐项带 goodName/amount/stolen ✓",
        type(r1.sellable.goods) == "table" and #r1.sellable.goods == 2
        and r1.sellable.goods[1].goodName ~= nil and r1.sellable.goods[1].amount ~= nil
        and r1.sellable.goods[1].stolen ~= nil, "shape")
    check("T1 ★ skipped 有 1 条（卖不掉的货 ✓）", type(r1.skipped) == "table" and #r1.skipped == 1,
        r1.skipped and #r1.skipped)
    check("T1 skipped[1].goodName = Rift Naonite Ore ✓",
        r1.skipped and r1.skipped[1] and r1.skipped[1].goodName == "Rift Naonite Ore",
        r1.skipped and r1.skipped[1] and r1.skipped[1].goodName)
    check("T1 skipped[1].amount = 1369 ✓",
        r1.skipped and r1.skipped[1] and r1.skipped[1].amount == 1369,
        r1.skipped and r1.skipped[1] and r1.skipped[1].amount)
    check("T1 ★ skipped[1].reason 是**原版原话**（no demand for … here. ✓）",
        r1.skipped and r1.skipped[1]
        and type(r1.skipped[1].reason) == "string"
        and r1.skipped[1].reason:find("There is no demand for", 1, true) ~= nil
        and r1.skipped[1].reason:find("here.", 1, true) ~= nil,
        r1.skipped and r1.skipped[1] and r1.skipped[1].reason)
    check("T1 skippedKinds = 1 / skippedUnits = 1369 ✓",
        r1.skippedKinds == 1 and r1.skippedUnits == 1369,
        tostring(r1.skippedKinds) .. "/" .. tostring(r1.skippedUnits))
    check("T1 回执仍带 risk（不因过滤丢掉旧的字段 ✓）",
        type(r1.risk) == "table", type(r1.risk))
    check("T1 ★ Trace 里写明了卖不掉的货与理由 ✓",
        traceHas("卖不掉") ~= nil and traceHas("Rift Naonite Ore") ~= nil,
        table.concat(TRACE, " | "))
    check("T1 真的发起了区域分析（只发能卖的那些 → 命令会跑起来 ✓）",
        #INVOKED >= 1, #INVOKED)
end

-- ===========================================================================
-- T2：★ 白名单也**过滤**（点名的货里有卖不掉的 → 只发能卖的 + skipped ✓）
-- ===========================================================================
print("== T2: 白名单里混了卖不掉的货 → 仍然只发能卖的 ✓ ==")
resetAll()
CARGO = { [mkGood("Rift Naonite Ore")] = 1369, [mkGood("Drill")] = 100 }
DEMAND = { ["Drill"] = true }
SUPPLY = { ["Rift Naonite Ore"] = true }
local ok2, r2 = LinkIn.onOrder({
    ship = SHIP, action = "Sell", x = SHIP_X, y = SHIP_Y, size = 15,
    goodsToSell = { { goodName = "Drill", amount = 60 }, { goodName = "Rift Naonite Ore", amount = 1369 } },
})
check("T2 下单成功 ✓", ok2 == true and r2.accepted == true, r2)
if ok2 == true then
    check("T2 ★ 只发了 Drill（且数量按白名单夹到 60 ✓）",
        #r2.config.goodsToSell == 1 and r2.config.goodsToSell[1].goodName == "Drill"
        and r2.config.goodsToSell[1].amount == 60, namesOf(r2.config.goodsToSell))
    check("T2 skipped 里仍报出 Rift Naonite Ore ✓",
        #r2.skipped == 1 and r2.skipped[1].goodName == "Rift Naonite Ore", #r2.skipped)
end

-- ===========================================================================
-- T3：★ 全都卖不掉 → NO_BUYER（不下单、不假装成功 ✗✓）
-- ===========================================================================
print("== T3: 全都卖不掉 → NO_BUYER（一件也不发 ✓）==")
resetAll()
local pendingBefore = #(CopilotLinkIn and CopilotLinkIn.pendingOrders or {})
CARGO = { [mkGood("Rift Naonite Ore")] = 2889 }
DEMAND = {}
SUPPLY = { ["Rift Naonite Ore"] = true }
local ok3, code3, why3 = LinkIn.onOrder({ ship = SHIP, action = "Sell", x = SHIP_X, y = SHIP_Y, size = 15 })
check("T3 ★ ok=false ✓（不再假装成功 ✗✓）", ok3 == false, tostring(ok3))
check("T3 ★ 错误码 = NO_BUYER ✓", code3 == "NO_BUYER", tostring(code3))
check("T3 ★ 没有发起区域分析（INVOKED 仍空 ✓ —— 不下一张注定失败的单 ✗）",
    #INVOKED == 0, #INVOKED)
local pendingAfter = #(CopilotLinkIn and CopilotLinkIn.pendingOrders or {})
check("T3 ★ 没有排进 startCommand 队列（pendingOrders 没增加 ✓）",
    pendingAfter == pendingBefore, tostring(pendingBefore) .. " -> " .. tostring(pendingAfter))
check("T3 失败消息里带原版理由（no demand ✓）与货名 ✓",
    type(why3) == "string" and why3:find("buyer", 1, true) ~= nil
    and why3:find("Rift Naonite Ore", 1, true) ~= nil
    and why3:find("There is no demand for", 1, true) ~= nil, tostring(why3))

-- ===========================================================================
-- T4：★ 白名单 = 纯字符串（工具是 array，模型很可能直接写 ["Drill"] ✓）
-- ===========================================================================
print("== T4: 白名单用纯字符串也能认 ✓ ==")
resetAll()
CARGO = { [mkGood("Drill")] = 100, [mkGood("Oxygen")] = 50 }
DEMAND = { ["Drill"] = true, ["Oxygen"] = true }
local ok4, r4 = LinkIn.onOrder({
    ship = SHIP, action = "Sell", x = SHIP_X, y = SHIP_Y, size = 15,
    goodsToSell = { "Drill" },
})
check("T4 下单成功 ✓", ok4 == true and r4.accepted == true, r4)
if ok4 == true then
    check("T4 ★ 字符串白名单生效（只发 Drill ✓ —— 不被静默无视 ✗）",
        #r4.config.goodsToSell == 1 and r4.config.goodsToSell[1].goodName == "Drill",
        namesOf(r4.config.goodsToSell))
    check("T4 数量取船上全部 100 ✓", r4.config.goodsToSell[1].amount == 100,
        r4.config.goodsToSell[1].amount)
    check("T4 没有 skipped（点名的那货能卖 ✓）", #r4.skipped == 0, #r4.skipped)
end

-- ===========================================================================
-- T5：点名要卖的货**不在船上** → BAD_REQUEST（别静默退回"整舱全卖" ✗✓）
-- ===========================================================================
print("== T5: 白名单货不在船上 → BAD_REQUEST ✓ ==")
resetAll()
CARGO = { [mkGood("Drill")] = 100 }
DEMAND = { ["Drill"] = true }
local ok5, code5 = LinkIn.onOrder({
    ship = SHIP, action = "Sell", x = SHIP_X, y = SHIP_Y, size = 15,
    goodsToSell = { "Not-On-Board" },
})
check("T5 ok=false ✓", ok5 == false, tostring(ok5))
check("T5 错误码 = BAD_REQUEST ✓", code5 == "BAD_REQUEST", tostring(code5))

-- ===========================================================================
-- T6：全部都能卖 → skipped 空、sellable = 整舱（"Select All" 的语义 ✓）
-- ===========================================================================
print("== T6: 全部能卖 → skipped 空 ✓ ==")
resetAll()
CARGO = { [mkGood("Drill")] = 100, [mkGood("Oxygen")] = 50, [mkGood("Antigrav Unit")] = 5 }
DEMAND = { ["Drill"] = true, ["Oxygen"] = true, ["Antigrav Unit"] = true }
local ok6, r6 = LinkIn.onOrder({ ship = SHIP, action = "Sell", x = SHIP_X, y = SHIP_Y, size = 15 })
check("T6 下单成功 ✓", ok6 == true and r6.accepted == true, r6)
if ok6 == true then
    check("T6 ★ 3 种全发下去 ✓", #r6.config.goodsToSell == 3, namesOf(r6.config.goodsToSell))
    check("T6 sellable.units = 155 ✓（100+50+5）", r6.sellable.units == 155, r6.sellable.units)
    check("T6 skipped 空 ✓", #r6.skipped == 0 and r6.skippedKinds == 0,
        tostring(#r6.skipped) .. "/" .. tostring(r6.skippedKinds))
end

-- ===========================================================================
print(string.format("== 共 %d 项断言，失败 %d 项 ==", checks, failures))
if failures == 0 then
    print("sellFilterSelfTest: OK")
else
    print("sellFilterSelfTest: FAIL")
end
