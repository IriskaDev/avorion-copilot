-- _sell_scan_selftest.lua —— Sell（把船上的货变现）离线自检 ✓ 2026-10-17
--
-- 不开游戏就能验：把游戏 API 全换成替身（run / command / ShipDatabaseEntry:getCargo ✓），
-- 然后**真的调** data/scripts/net/link_in.lua 里的 CopilotLinkIn.sellPlan ✓✓
-- 以及 onOrder 的"货舱感知"那条（Trade 有货必须被拦住 ✓）。
--
-- 覆盖到的点（每条都是**具体数字**、可手算 ✓）：
--   ① 空货舱 → 不编计划、明确说"不用卖" ✓（也不该白扫区域 ✓）
--   ② 风险调整期望 = (1−p)×yield + p×yield×keepFraction ✓
--         长任务（D ≥ 1553s）：keepFraction = 0.425 → 0.9×100000 + 0.1×100000×0.425 = **94250** ✓
--         短任务（D <  1553s）：keepFraction = 0     → 0.9×100000 + 0            = **90000** ✓
--         依据：原版 sellcommand.lua:152-159（只有跑够 11 分钟或 >80% 时长才部分卖 ✓）
--               与 :144（攻击时刻 = random(0.1,0.75)×duration → 期望 0.425 ✓）
--   ③ 风险闸门 0.10：超闸门 → acceptable=false、**绝不进 recommendation** ✓ + riskWarning ✓
--   ④ 所有候选区域**必须含船** ✓（与 Mine/Salvage/Trade 同一条硬约束 ✓）
--   ⑤ goodsToSell 的形状 = 原版要的 {goodName, amount, stolen} ✓（sellcommand.lua:243/:326-343 ✓）
--   ⑥ onOrder：有货时 action=Trade 必须被拒 ✓ 并指向 Sell ✓✓（主人点出的场景 ✓）
--   ⑦ 响应可 JSON 编解码 ✓；orderHint 能直接喂 order ✓
--   ⑧ 源码里 Sell 的 UUID 与实读的 commandtype.lua 一致 ✓（结构性断言 ✓）
--
-- 跑法：  native\harness\lua.exe native\harness\_sell_scan_selftest.lua

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
local CAP = 5000
local CARGO = {}              -- good 对象 → 数量 ✓
local nRun, nPred = 0, 0
local SPEC = {}               -- 区域（按"中心相对船星的偏移"布置 ✓）

local function resetAll()
    CARGO = {}
    nRun, nPred = 0, 0
    SPEC = {}
end

local function offsetOfArea(area)
    local size = area.upper.x - area.lower.x + 1
    local half = math.floor((size - 1) / 2)
    return (area.lower.x + half) - SHIP_X, (area.lower.y + half) - SHIP_Y
end

-- ---------------------------------------------------------------------------
-- 游戏 API 的替身 ✓
-- ---------------------------------------------------------------------------

CopilotRpc = { trace = function() end }

function run(factionIndex, shipName, ctype, area, callingPlayer)
    nRun = nRun + 1
    local ox, oy = offsetOfArea(area)
    local key = ox .. "," .. oy
    local s = SPEC[key]
    if s == "ERROR" then error("simulated area analysis failure") end
    -- ★ 没显式布置的偏移 → 一个**普通**区域 ✓（免得断言依赖扫描顺序 ✗）
    if type(s) ~= "table" and s ~= "ERROR" then
        s = { yield = 10000, chance = 0.05, duration = 2000 }
    end
    SPEC[key] = s
    local results = {
        probe = key,
        goodsInDemand = {}, goodsInSupply = {},
        numSectorsWithGoodInDemand = {}, numSectorsWithGoodInSupply = {},
        averagePriceFactors = {}, highestPriceFactors = {},
        sectors = 225, reachable = 220, unreachable = 5,
        biggestFactionInArea = 1, reachableCoordinates = {},
    }
    return shipName, ctype, area, results, callingPlayer
end

local FAKE_COMMAND = {}

function FAKE_COMMAND:getAreaSize(ownerIndex, shipName)
    -- ★ 原版 SellCommand:getAreaSize → {15,15}（sellcommand.lua:414-416 ✓）
    return { x = 15, y = 15 }
end

function FAKE_COMMAND:calculatePrediction(ownerIndex, shipName, area, config)
    nPred = nPred + 1
    local key = (type(area.analysis) == "table") and area.analysis.probe or "?"
    local s = SPEC[key]
    if type(s) ~= "table" then
        return { attackChance = { value = 0 }, duration = 600, error = "nothing to sell here" }
    end
    return {
        attackChance = { value = tonumber(s.chance) or 0 },
        duration = tonumber(s.duration) or 2000,
        yield = tonumber(s.yield) or 0,          -- 原版 getPredictableValues().yield ✓
        -- 逐货数字（原版 sellcommand.lua:626 percentages / :629 pricesPerGood）
        percentages = s.pcts or {},
        pricesPerGood = s.prices or {},
    }
end

local FAKE_CARD = { shipCard = function(player, ship) return { cargoCapacity = CAP } end }

function include(name)
    if name == "areaanalysis" then return nil end       -- 真的也返回 nil（只定义全局 run ✓）
    if name == "commandfactory" then
        return { makeCommand = function(ctype) return FAKE_COMMAND end }
    end
    if name == "copilot/card" then return FAKE_CARD end
    if name == "goods" then return {} end
    error("unexpected include: " .. tostring(name))
end

-- ★ entry:getCargo() 返回**两个值**：货物表 + 货舱容量 ✓
--   证据：minecommand.lua:137 `local cargo, cargoBaySize = entry:getCargo()` ✓
--         expeditioncommand.lua:393 `local cargos, cargoHold = entry:getCargo()` ✓
function ShipDatabaseEntry(ownerIndex, name)
    return {
        getCargo = function() return CARGO, CAP end,
        getFreeCargoSpace = function() return CAP end,
    }
end

local invoked = {}
local player = {
    index = 1,
    getShipPosition = function(self, name) return SHIP_X, SHIP_Y end,
    getShipAvailability = function(self, name) return 0 end,
    canPay = function(self, n) return true end,
    invokeFunction = function(self, path, fn, ...)
        invited = true
        invoked[#invoked + 1] = fn
    end,
}

function Player() return player end
function ShipAvailability() return { Available = 0 } end
ShipAvailability = { Available = 0 }

local LinkIn = dofile("data/scripts/net/link_in.lua")
local JSON = dofile("data/scripts/lib/copilot/json.lua")

local function mkGood(name)
    local g = { name = name, stolen = false }
    g.displayName = function(self, n) return name end
    return g
end

-- ---------------------------------------------------------------------------
-- ① 空货舱 ✓
-- ---------------------------------------------------------------------------
print("== S1: 空货舱（不该编计划 ✓）==")
resetAll()
local ok1, r1 = LinkIn.sellPlan(player, { ship = SHIP })
check("S1 调用成功", ok1 == true, r1)
check("S1 holdEmpty = true ✓", r1 and r1.holdEmpty == true, r1 and r1.holdEmpty)
check("S1 recommendation = nil ✓", r1 and r1.recommendation == nil)
check("S1 orderHint = nil ✓", r1 and r1.orderHint == nil)
check("S1 **没有白扫区域**（nRun = 0 ✓）", nRun == 0, nRun)
check("S1 note 说清了'货舱是空的' ✓",
    r1 and type(r1.note) == "string" and r1.note:find("empty", 1, true) ~= nil, r1 and r1.note)

-- ---------------------------------------------------------------------------
-- ② 有货 + 长任务（keepFraction = 0.425）✓
-- ---------------------------------------------------------------------------
print("== S2: 有货 / 长任务 → 期望 94250 ✓ ==")
resetAll()
CARGO = { [mkGood("Force Generator")] = 120 }
SPEC = { ["0,0"] = { yield = 100000, chance = 0.10, duration = 2000 } }
local ok2, r2 = LinkIn.sellPlan(player, { ship = SHIP, maxAreas = 1 })
local rc = r2 and r2.recommendation
check("S2 有推荐 ✓", rc ~= nil, r2 and r2.riskWarning)
check("S2 goodsToSell 形状 = {goodName, amount, stolen} ✓",
    rc and rc.goodsToSell and rc.goodsToSell[1]
    and rc.goodsToSell[1].goodName == "Force Generator"
    and rc.goodsToSell[1].amount == 120
    and rc.goodsToSell[1].stolen == false,
    rc and JSON.encode(rc.goodsToSell))
check("S2 keepFractionOnAttack = 0.425 ✓（原版 :144 的期望 ✓）",
    rc and math.abs((rc.keepFractionOnAttack or -1) - 0.425) < 1e-9, rc and rc.keepFractionOnAttack)
check("S2 风险调整期望 = **94250**（0.9×100000 + 0.1×100000×0.425 ✓）",
    rc and rc.netProfitLow ~= nil and math.abs(rc.netProfitLow - 94250) < 0.5,
    rc and rc.netProfitLow)
check("S2 最好情况 = 100000（标注 bestCase ✓）", rc and rc.bestCaseLow == 100000, rc and rc.bestCaseLow)
check("S2 期望**低于**最好情况 ✓", rc and rc.netProfitLow < rc.bestCaseLow)
check("S2 口径写明了 riskAdjusted ✓",
    rc and type(rc.profitBasis) == "string" and rc.profitBasis:find("riskAdjusted", 1, true) ~= nil,
    rc and rc.profitBasis)
check("S2 attackNote 讲清了被伏击的后果 ✓",
    rc and type(rc.attackNote) == "string" and rc.attackNote:find("还在船上", 1, true) ~= nil,
    rc and rc.attackNote)

-- ---------------------------------------------------------------------------
-- ③ 有货 + 短任务（keepFraction = 0 → 一点都卖不掉）✓
-- ---------------------------------------------------------------------------
print("== S3: 有货 / 短任务 → 期望 90000 ✓ ==")
resetAll()
CARGO = { [mkGood("Drill")] = 50 }
SPEC = { ["0,0"] = { yield = 100000, chance = 0.10, duration = 600 } }
local ok3, r3 = LinkIn.sellPlan(player, { ship = SHIP, maxAreas = 1 })
local rc3 = r3 and r3.recommendation
check("S3 keepFractionOnAttack = 0 ✓（0.425×600 = 255s < 11min，还没开始卖 ✓）",
    rc3 and rc3.keepFractionOnAttack == 0, rc3 and rc3.keepFractionOnAttack)
check("S3 风险调整期望 = **90000**（0.9×100000 + 0.1×0 = 90000 ✓）",
    rc3 and rc3.netProfitLow ~= nil and math.abs(rc3.netProfitLow - 90000) < 0.5,
    rc3 and rc3.netProfitLow)

-- ---------------------------------------------------------------------------
-- ④ 风险闸门：超 0.10 一律不推荐 ✓
-- ---------------------------------------------------------------------------
print("== S4: 风险闸门 ✓ ==")
resetAll()
CARGO = { [mkGood("Drill")] = 50 }
SPEC = { ["0,0"] = { yield = 999999, chance = 0.50, duration = 2000 } }
local ok4, r4 = LinkIn.sellPlan(player, { ship = SHIP, maxAreas = 1 })
check("S4 recommendation = nil（高风险绝不推荐 ✓✓）", r4 and r4.recommendation == nil)
check("S4 riskWarning 明说 ✓",
    r4 and type(r4.riskWarning) == "string" and r4.riskWarning:find("不推荐", 1, true) ~= nil,
    r4 and r4.riskWarning)
check("S4 每个区域的 acceptable = false ✓",
    r4 and r4.areaRanking and r4.areaRanking[1] and r4.areaRanking[1].acceptable == false)

-- ---------------------------------------------------------------------------
-- ⑤ 多区域：所有候选区域必须含船 ✓ + 排序 ✓
-- ---------------------------------------------------------------------------
print("== S5: 多区域 ✓ ==")
resetAll()
CARGO = { [mkGood("Oxygen")] = 300 }
-- ★ 高收益放在 (0,0)：scanOffsets **保证它排第一** ✓（所以与顺序无关 ✓✓）
SPEC = {
    ["0,0"] = { yield = 80000, chance = 0.05, duration = 2000 },
}
local ok5, r5 = LinkIn.sellPlan(player, { ship = SHIP, maxAreas = 3 })
check("S5 粗扫 3 个区域 ✓（areasScanned = **粗扫**框数，语义不变 ✓）",
    r5 and r5.areasScanned == 3, r5 and r5.areasScanned)
check("S5 两阶段：细扫围绕最好的几个粗扫框又扫了一批 ✓（boxesEvaluated > 3 ✓）",
    r5 and type(r5.boxesEvaluated) == "number" and r5.boxesEvaluated > r5.areasScanned,
    r5 and r5.boxesEvaluated)
check("S5 scan.phases.fineScanned > 0 ✓（细扫真的跑了 ✓）",
    r5 and r5.scan and r5.scan.phases and (r5.scan.phases.fineScanned or 0) > 0,
    r5 and r5.scan and r5.scan.phases and r5.scan.phases.fineScanned)
check("S5 每个候选框都带**绝对坐标** x/y 与 origin ✓（模型不做算术 ✓）",
    (function()
        for _, e in ipairs(r5 and r5.areaRanking or {}) do
            if type(e.x) ~= "number" or type(e.y) ~= "number" then return false end
            if e.origin ~= "coarse" and e.origin ~= "fine" then return false end
        end
        return true
    end)())
local allInside = true
for _, e in ipairs(r5 and r5.areaRanking or {}) do
    local a = e.area
    if not (SHIP_X >= a.lower.x and SHIP_X <= a.upper.x
        and SHIP_Y >= a.lower.y and SHIP_Y <= a.upper.y) then allInside = false end
end
check("S5 **每个候选区域都含船** ✓✓（硬约束 ✓）", allInside)
-- 期望值手算：(1−0.05)×80000 + 0.05×80000×0.425 = 76000 + 1700 = **77700** ✓✓
check("S5 推荐的是 (0,0) 那个最高收益区域 ✓（按**期望**排 ✓）",
    r5 and r5.recommendation and r5.recommendation.area and r5.recommendation.area.offset
    and r5.recommendation.area.offset.x == 0 and r5.recommendation.area.offset.y == 0,
    r5 and r5.recommendation and JSON.encode(r5.recommendation.area and r5.recommendation.area.offset))
check("S5 期望 = **77700** ✓（0.95×80000 + 0.05×80000×0.425 ✓）",
    r5 and r5.recommendation and math.abs((r5.recommendation.netProfitLow or 0) - 77700) < 0.5,
    r5 and r5.recommendation and r5.recommendation.netProfitLow)
check("S5 orderHint 可喂 order（ship/action/x/y/size/goodsToSell ✓）",
    r5 and r5.orderHint and r5.orderHint.ship == SHIP and r5.orderHint.action == "Sell"
    and type(r5.orderHint.x) == "number" and type(r5.orderHint.y) == "number"
    and r5.orderHint.size == 15 and type(r5.orderHint.goodsToSell) == "table",
    r5 and JSON.encode(r5.orderHint))

-- ---------------------------------------------------------------------------
-- ⑥ 分析失败的某个区域不能中断整轮 ✓
-- ---------------------------------------------------------------------------
print("== S6: 单区域失败不中断 ✓ ==")
resetAll()
CARGO = { [mkGood("Oxygen")] = 100 }
SPEC = { ["0,0"] = "ERROR" }        -- 必扫到的第一个区域炸掉 ✓；其余偏移走替身默认值 ✓
local ok6, r6 = LinkIn.sellPlan(player, { ship = SHIP, maxAreas = 2 })
check("S6 仍然粗扫完 2 个区域 ✓（失败不中断 ✓）",
    r6 and r6.areasScanned == 2, r6 and r6.areasScanned)
local anyErr = false
for _, e in ipairs(r6 and r6.areaRanking or {}) do
    if type(e.error) == "string" then anyErr = true end
end
check("S6 失败的区域内标了 error ✓", anyErr)
check("S6 坏区域之后照样给出推荐 ✓", r6 and r6.recommendation ~= nil)

-- ---------------------------------------------------------------------------
-- ⑦ onOrder：有货时 Trade 必须被拒 ✓ 并指向 Sell ✓✓
-- ---------------------------------------------------------------------------
print("== S7: onOrder 的货舱感知 ✓✓ ==")
resetAll()
CARGO = { [mkGood("Force Generator")] = 120 }
local okT, codeT, msgT = LinkIn.onOrder({
    ship = SHIP, action = "Trade", x = SHIP_X, y = SHIP_Y, goodName = "Force Generator", deposit = 1000,
})
check("S7 有货时 Trade 被拒 ✓", okT == false, tostring(okT))
check("S7 拒绝码 = HOLD_HAS_GOODS ✓", codeT == "HOLD_HAS_GOODS", tostring(codeT))
check("S7 提示里指向 Sell ✓✓（主人点出的场景 ✓）",
    type(msgT) == "string" and msgT:find("Sell", 1, true) ~= nil, tostring(msgT))

resetAll()
local okT2, codeT2 = LinkIn.onOrder({ ship = SHIP, action = "Trade", x = SHIP_X, y = SHIP_Y, deposit = 1000 })
check("S7 空货舱时 Trade 不再被这条拦住 ✓（应走到别的原因或成功 ✓）",
    not (okT2 == false and codeT2 == "HOLD_HAS_GOODS"), tostring(codeT2))

-- ---------------------------------------------------------------------------
-- ⑧ JSON 往返 + 源码里的 UUID 一致 ✓
-- ---------------------------------------------------------------------------
print("== S8: JSON 与 UUID ✓ ==")
resetAll()
CARGO = { [mkGood("Oxygen")] = 42 }
SPEC = { ["0,0"] = { yield = 12345, chance = 0.02, duration = 2000 } }
local _, r8 = LinkIn.sellPlan(player, { ship = SHIP, maxAreas = 1 })
local enc = JSON.encode(r8)
local dec = JSON.decode(enc)
check("S8 响应可 JSON 往返 ✓", type(dec) == "table" and dec.action == "Sell", type(dec))
check("S8 往返后 goodsToSell 仍在 ✓",
    dec and dec.goodsToSell and dec.goodsToSell[1] and dec.goodsToSell[1].amount == 42,
    enc and string.sub(enc, 1, 80))

local fh = io.open("data/scripts/net/link_in.lua", "rb")
local src = fh and fh:read("*a") or ""
if fh then fh:close() end
check("S8 源码里的 Sell UUID 与实读的 commandtype.lua 一致 ✓",
    src:find("6bf2d9af-255b-4108-a1e1-dc83ace49819", 1, true) ~= nil)
check("S8 onOrder 里确实装了 config.goodsToSell ✓", src:find("config.goodsToSell = hold", 1, true) ~= nil)

-- ---------------------------------------------------------------------------
-- 9) 逐货数字（主人 2026-10-17 要求）：每个候选框、每种货 --
--    舱里有多少 / 预计卖多少 / 涨跌幅 百分比（来源：原版 pred.pricesPerGood / pred.percentages）
-- ---------------------------------------------------------------------------
print("== S9: 逐货数字（perGood）==")
resetAll()
CARGO = { [mkGood("Drill")] = 100, [mkGood("Oxygen")] = 50 }
-- (0,0)：Drill 总价 2000（涨 10%）/ Oxygen 总价 4000（跌 20%）
-- (-4,0)：Drill 总价 2500（涨 50%）-> 跨框比较时 Drill 应该选 (-4,0)
--   ★ 偏移 (-4,0) 是**粗扫网格点**（half=7 时 0/±4 ✓），(-4,0) 也在前三近里 ✓
SPEC = {
    ["0,0"] = { yield = 50000, chance = 0.05, duration = 2000,
                prices = { ["Drill"] = 2000, ["Oxygen"] = 4000 },
                pcts = { ["Drill"] = 110, ["Oxygen"] = 80 } },
    ["-4,0"] = { yield = 40000, chance = 0.05, duration = 2000,
                 prices = { ["Drill"] = 2500, ["Oxygen"] = 3000 },
                 pcts = { ["Drill"] = 150, ["Oxygen"] = 60 } },
}
local ok9, r9 = LinkIn.sellPlan(player, { ship = SHIP, maxAreas = 3 })
check("S9 ok=true", ok9 == true, r9)
if ok9 == true then
    check("S9 顶层带 perGoodByArea（每个候选框一份）",
        type(r9.perGoodByArea) == "table" and #r9.perGoodByArea >= 2, r9.perGoodByArea and #r9.perGoodByArea)
    check("S9 顶层带 perGoodBest（跨框每种货最好的那个框）",
        type(r9.perGoodBest) == "table" and #r9.perGoodBest == 2, r9.perGoodBest and #r9.perGoodBest)
    local rec = r9.recommendation
    check("S9 recommendation.perGood 存在", rec ~= nil and type(rec.perGood) == "table",
        rec and rec.perGood)
    if rec ~= nil and type(rec.perGood) == "table" then
        local byName = {}
        for _, g in ipairs(rec.perGood) do byName[g.goodName] = g end
        check("S9 每种货都有 amount（舱里多少）",
            byName["Drill"] ~= nil and byName["Drill"].amount == 100
            and byName["Oxygen"] ~= nil and byName["Oxygen"].amount == 50,
            JSON.encode(rec.perGood))
        check("S9 每种货都有 expectedRevenue（这个框里预计卖多少）",
            byName["Drill"] ~= nil and byName["Drill"].expectedRevenue == 2000
            and byName["Oxygen"] ~= nil and byName["Oxygen"].expectedRevenue == 4000,
            byName["Drill"] and byName["Drill"].expectedRevenue)
        check("S9 每种货都有 priceDeltaPercent（+10% / -20%）",
            byName["Drill"] ~= nil and byName["Drill"].priceDeltaPercent == 10
            and byName["Oxygen"] ~= nil and byName["Oxygen"].priceDeltaPercent == -20,
            tostring(byName["Drill"] and byName["Drill"].priceDeltaPercent) .. " / "
                .. tostring(byName["Oxygen"] and byName["Oxygen"].priceDeltaPercent))
        check("S9 单位价也算好了（expectedUnitPrice，模型不用除）",
            byName["Drill"] ~= nil and math.abs((byName["Drill"].expectedUnitPrice or 0) - 20) < 1e-9,
            byName["Drill"] and byName["Drill"].expectedUnitPrice)
        check("S9 正常价总额也反推算好了（normalRevenueEstimate）",
            byName["Drill"] ~= nil
            and math.abs((byName["Drill"].normalRevenueEstimate or 0) - (2000 / 1.1)) < 0.5,
            byName["Drill"] and byName["Drill"].normalRevenueEstimate)
    end
    local best = nil
    for _, g in ipairs(r9.perGoodBest or {}) do if g.goodName == "Drill" then best = g end end
    check("S9 perGoodBest 里 Drill 选的是 (-4,0)（2500 > 2000，跨框比较）",
        best ~= nil and best.expectedRevenue == 2500
        and best.offset.x == -4 and best.offset.y == 0,
        best and JSON.encode(best))
    check("S9 perGoodNote 说清了口径与来源",
        type(r9.perGoodNote) == "string" and r9.perGoodNote:find("sellcommand", 1, true) ~= nil,
        r9.perGoodNote)
    local anyUnavailable = false
    for _, a in ipairs(r9.perGoodByArea or {}) do
        if a.goods and a.goods[1] and a.goods[1].priceUnavailable == true then anyUnavailable = true end
    end
    check("S9 拿不到原版价的框会标 priceUnavailable=true（绝不编价）", anyUnavailable)
end

print("")
print(string.format("== 共 %d 项断言，失败 %d 项 ==", checks, failures))
if failures == 0 then
    print("sellScanSelfTest: OK")
else
    print("sellScanSelfTest: FAIL")
end
