-- _order_risk_selftest.lua —— 「这次下单的伏击风险评估」离线自检 ✓ 2026-10-17
--
-- 不开游戏就能验：把游戏 API 全换成替身（run / command:calculatePrediction / Job / goods ✓），
-- 然后**真的调** data/scripts/net/link_in.lua 里的 CopilotLinkIn.predict 与 CopilotLinkIn.onOrder ✓。
--
-- 覆盖（主人这一轮点出的每一条 ✓）：
--   ① Travel 的 predict **不要求框含船** ✓ —— Travel 的框是 1×1 终点，船本来就在别处
--      （原版 travelcommand.lua:472 `isShipRequiredInArea → false` ✓）
--   ② Travel 的风险 = **游戏自己的那个数** ✓（TravelCommand:calculatePrediction 的
--      attackChance.value ✓，travelcommand.lua:618-630）；且**没有** base →
--      baseAttackChanceKnown=false + 原因 ✓（**绝不**把 attackChance 抄成 base 装懂 ✗✓）
--   ③ order 回执里的 risk 与 predict **逐字相同** ✓（Travel / Mine 各一例 ✓✓）
--   ④ 算不出来 → known=false + unknownReason，attackChance=**nil**（绝不是 0 ✗✓），**订单照下** ✓
--   ⑤ Travel 的 trace 流水里有一行带风险数字 ✓（主人能在 rpc_trace.log 直接看到 ✓）
--   ⑥ 非 Travel 的动作**仍然**要求框含船 ✓（Travel 的例外没把别的动作带坏 ✗✓）
--
-- 跑法（★ 必须在 mod 仓库根跑）：
--   native\harness\lua.exe native\harness\_order_risk_selftest.lua

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

local SHIP, SHIP_X, SHIP_Y = "Scout-00001", -347, 21
local DEST_X, DEST_Y = -348, 32          -- 目的地（**不在**船的星区 ✓ —— 这正是 Travel 的正常情形 ✓）

local nRun, nPred = 0, 0
local MODE = "JOB"                        -- JOB / TRAVEL / RUN_ERROR
local TRAVEL_CHANCE = 0.07                -- 原版 Travel 命令给出的那个数 ✓
local JOB_CHANCE = 0.03
local PRED_ERROR = nil                    -- 非 nil → 替身 calculatePrediction 回 error ✓
local TRACE = {}

local function reset()
    nRun, nPred = 0, 0
    MODE = "JOB"
    PRED_ERROR = nil
    TRACE = {}
end

-- ---------------------------------------------------------------------------
-- 游戏 API 的替身 ✓
-- ---------------------------------------------------------------------------

CopilotRpc = { trace = function(line) TRACE[#TRACE + 1] = tostring(line) end }

local N_MAT = 2
function NumMaterials() return N_MAT end
function Material(i) return { name = ({ "Iron", "Titanium" })[i + 1] } end
function Rarity(v) return { value = v } end

local GOODS = {
    ["Iron Ore"]     = { price = 2, size = 0.025 },
    ["Titanium Ore"] = { price = 3, size = 0.025 },
}
for _, g in pairs(GOODS) do g.good = function(self) return self end end

function run(factionIndex, shipName, ctype, area, callingPlayer)
    nRun = nRun + 1
    if MODE == "RUN_ERROR" then error("simulated area analysis failure") end
    if MODE == "TRAVEL" then
        -- ★ 原版 travelcommand.lua:109-137 getAreaAnalysisSectors 交出来的形状 ✓：
        --   route = 从船位置到 area.lower 的跳路；origin/destination 也记下来 ✓
        return shipName, ctype, area, {
            route = {
                { x = SHIP_X, y = SHIP_Y },
                { x = SHIP_X + 3, y = SHIP_Y },
                { x = area.lower.x, y = area.lower.y },
            },
            origin = { x = SHIP_X, y = SHIP_Y },
            destination = { x = area.lower.x, y = area.lower.y },
            attackProbabilities = { 0.5, 0.3, 0.3 },   -- :165-184 逐星区 ✓
            travelTimeFactors = { 1, 1, 1 },
            sectors = 3, reachable = 3, unreachable = 0, reachableCoordinates = {},
        }, callingPlayer
    end
    return shipName, ctype, area, {
        routes = {}, materials = { 1, 1 }, safeMaterials = { 1, 1 },
        sectors = 225, reachable = 220, unreachable = 5, biggestFactionInArea = 1,
        reachableCoordinates = {}, safeSectors = { 1 }, asteroids = 9, wrecks = 9, volume = 500,
    }, callingPlayer
end

local FAKE_COMMAND = {}

function FAKE_COMMAND:getAreaSize() return { x = 15, y = 15 } end
function FAKE_COMMAND:getConfigurableValues()
    return {
        duration = { displayName = "Duration", from = 0.5, to = 2, default = 1 },
        safeMode = { displayName = "Safe Mode", default = false },
    }
end

function FAKE_COMMAND:calculatePrediction(ownerIndex, shipName, area, config)
    nPred = nPred + 1
    if PRED_ERROR ~= nil then
        return { attackChance = { value = 0 }, error = PRED_ERROR }
    end
    if MODE == "TRAVEL" then
        -- ★ Travel 的 predict 只认这些（travelcommand.lua:618-630）✓
        return { attackChance = { value = TRAVEL_CHANCE }, distance = 41.5, travelTime = 3600 }
    end
    -- Mine/Salvage：safeMode 会**修正**概率（原版 attackChanceModification 同义 ✓）
    local chance = JOB_CHANCE
    if config.safeMode == true then chance = JOB_CHANCE * 0.5 end
    return {
        attackChance = { value = chance },
        yields = { { from = 900, to = 1000 }, { from = 100, to = 120 } },
        items = { from = 1, to = 2 },
    }
end

function include(name)
    if name == "areaanalysis" then return nil end        -- 真的也返回 nil（只定义全局 run ✓）
    if name == "commandfactory" then
        return { makeCommand = function(ctype) return FAKE_COMMAND end }
    end
    if name == "copilot/job" then return dofile("data/scripts/lib/copilot/job.lua") end
    if name == "goods" then return GOODS end
    error("unexpected include: " .. tostring(name))
end

function ShipDatabaseEntry() return { getFreeCargoSpace = function() return 10000 end } end

local INVOKED = {}
local player = {
    index = 1,
    getShipPosition = function(self, name) return SHIP_X, SHIP_Y end,
    getShipAvailability = function(self, name) return 0 end,
    invokeFunction = function(self, path, fn, ...) INVOKED[#INVOKED + 1] = fn end,
}
function Player() return player end
ShipAvailability = { Available = 0, InBackground = 1 }

local LinkIn = dofile("data/scripts/net/link_in.lua")

local function traceHas(needle)
    for _, line in ipairs(TRACE) do
        if line:find(needle, 1, true) ~= nil then return line end
    end
    return nil
end

-- ===========================================================================
-- R1：Travel 的 predict **不要求框含船** ✓ —— 风险 = 游戏自己的那个数 ✓
-- ===========================================================================
print("== R1: Travel predict（框 = 1×1 终点，船不在框里 ✓）==")
reset()
MODE = "TRAVEL"
local ok1, r1 = LinkIn.predict(player, {
    what = "predict", ship = SHIP, action = "Travel",
    x = DEST_X, y = DEST_Y, sizeX = 1, sizeY = 1,
})
check("R1 ok=true（Travel **不**因框不含船被拒 ✓）", ok1 == true, r1)
if ok1 == true then
    check("R1 box.containsShip=false（如实报告 ✓）", r1.box and r1.box.containsShip == false,
        r1.box and r1.box.containsShip)
    check("R1 risk.known=true", r1.risk and r1.risk.known == true, r1.risk and r1.risk.known)
    check("R1 attackChance = 游戏给的 0.07 ✓", r1.risk and r1.risk.attackChance == 0.07,
        r1.risk and r1.risk.attackChance)
    check("R1 baseAttackChance = nil（原版没这个数 ✗ → 不编 ✓）",
        r1.risk and r1.risk.baseAttackChance == nil, r1.risk and r1.risk.baseAttackChance)
    check("R1 baseAttackChanceKnown=false + 原因非空 ✓",
        r1.risk and r1.risk.baseAttackChanceKnown == false
        and type(r1.risk.baseAttackChanceUnknownReason) == "string"
        and #r1.risk.baseAttackChanceUnknownReason > 20, r1.risk and r1.risk.baseAttackChanceUnknownReason)
    check("R1 riskKind 明说这是**整段航程**的 ✓",
        r1.risk and type(r1.risk.riskKind) == "string"
        and r1.risk.riskKind:find("travelRouteAmbushChance", 1, true) ~= nil, r1.risk and r1.risk.riskKind)
    check("R1 value.distance/travelTime 原样来自游戏 ✓",
        r1.value and r1.value.distance == 41.5 and r1.value.travelTime == 3600, r1.value and r1.value.distance)
    check("R1 routeSectors=3（航线 3 个星区 ✓）", r1.value and r1.value.routeSectors == 3,
        r1.value and r1.value.routeSectors)
    check("R1 一次预测 = 一次 run ✓", nRun == 1 and nPred == 1, nRun .. "/" .. nPred)
end

-- ===========================================================================
-- R2：Travel **下单回执**里的 risk 与 predict **逐字相同** ✓ + trace 有那行 ✓
-- ===========================================================================
print("== R2: Travel order 回执带风险（与 predict 同口径 ✓）==")
reset()
MODE = "TRAVEL"
local ok2, r2 = LinkIn.onOrder({ ship = SHIP, action = "Travel", x = DEST_X, y = DEST_Y })
check("R2 Travel 下单 ok=true（Travel 不需要 size ✓）", ok2 == true and r2.accepted == true, r2)
if ok2 == true then
    check("R2 回执带 risk ✓", type(r2.risk) == "table", type(r2.risk))
    check("R2 回执 attackChance = 0.07（= 游戏自己的数 ✓）", r2.risk.attackChance == 0.07, r2.risk.attackChance)
    check("R2 回执 known=true", r2.risk.known == true, r2.risk.known)
    check("R2 回执 baseAttackChance=nil 且 baseKnown=false ✓",
        r2.risk.baseAttackChance == nil and r2.risk.baseAttackChanceKnown == false,
        tostring(r2.risk.baseAttackChance) .. "/" .. tostring(r2.risk.baseAttackChanceKnown))
    check("R2 回执 riskKind 与 R1 一致 ✓（同一份代码 ✓）",
        ok1 == true and r2.risk.riskKind == r1.risk.riskKind, r2.risk.riskKind)
    check("R2 Travel 的框是 1×1 ✓（回执 area 原样 ✓）",
        r2.area and r2.area.lower.x == DEST_X and r2.area.lower.y == DEST_Y
        and r2.area.upper.x == DEST_X and r2.area.upper.y == DEST_Y, "")
    local line = traceHas("onOrder 风险")
    check("R2 Trace 流水里有一行「onOrder 风险」✓", line ~= nil, table.concat(TRACE, " | "))
    check("R2 那行里有 0.07 与 riskKind ✓",
        line ~= nil and line:find("0.07", 1, true) ~= nil and line:find("travelRouteAmbushChance", 1, true) ~= nil,
        tostring(line))
    check("R2 riskNote 明说 known=false 别当 0 用 ✓",
        type(r2.riskNote) == "string" and r2.riskNote:find("known=false", 1, true) ~= nil, r2.riskNote)
end

-- ===========================================================================
-- R3：Mine（job 动作）回执 risk == predict risk ✓（口径一致 ✓）
-- ===========================================================================
print("== R3: Mine predict vs order 回执（逐字相同 ✓）==")
reset()
local ok3, r3 = LinkIn.predict(player, {
    what = "predict", ship = SHIP, action = "Mine",
    x = SHIP_X, y = SHIP_Y, sizeX = 15, sizeY = 15,
})
check("R3 predict Mine ok=true", ok3 == true and r3.risk ~= nil, r3)
reset()
local ok3b, r3b = LinkIn.onOrder({ ship = SHIP, action = "Mine", x = SHIP_X, y = SHIP_Y, size = 15 })
check("R3 order Mine ok=true", ok3b == true and r3b.accepted == true, r3b)
if ok3 == true and ok3b == true then
    check("R3 attackChance 一致 ✓（0.03）",
        r3b.risk.attackChance == r3.risk.attackChance and r3b.risk.attackChance == 0.03,
        tostring(r3b.risk.attackChance) .. " vs " .. tostring(r3.risk.attackChance))
    check("R3 baseAttackChance 一致 ✓", r3b.risk.baseAttackChance == r3.risk.baseAttackChance,
        tostring(r3b.risk.baseAttackChance) .. " vs " .. tostring(r3.risk.baseAttackChance))
    check("R3 riskKind 一致 ✓", r3b.risk.riskKind == r3.risk.riskKind, r3b.risk.riskKind)
    check("R3 job 动作的 base 是已知的 ✓（baseAttackChanceKnown=true）",
        r3b.risk.baseAttackChanceKnown == true and r3.risk.baseAttackChanceKnown == true, "")
    check("R3 order 只为风险算一次预测（run 恰好 1 次 ✓）", nRun == 1, nRun)
end

-- ===========================================================================
-- R4：safeMode → attackChance 被修正、baseAttackChance 仍是基准 ✓
-- ===========================================================================
print("== R4: Mine + safeMode（修正值与基准值分开给 ✓）==")
reset()
local ok4, r4 = LinkIn.onOrder({ ship = SHIP, action = "Mine", x = SHIP_X, y = SHIP_Y, size = 15, safeMode = true })
check("R4 order Mine safeMode=true ok=true", ok4 == true, r4)
if ok4 == true then
    check("R4 attackChance = 修正后的 0.015 ✓", r4.risk.attackChance == 0.015, r4.risk.attackChance)
    check("R4 baseAttackChance = 基准 0.03 ✓（判断<10% 只看它 ✓）", r4.risk.baseAttackChance == 0.03,
        r4.risk.baseAttackChance)
end

-- ===========================================================================
-- R5：游戏**算不出来** → known=false + 原因，attackChance=nil（**绝不是 0** ✗✓），订单照下 ✓
-- ===========================================================================
print("== R5: 预测失败 → known=false（不填 0 ✓，订单照下 ✓）==")
reset()
PRED_ERROR = "I don't know enough about this."
local ok5, r5 = LinkIn.onOrder({ ship = SHIP, action = "Mine", x = SHIP_X, y = SHIP_Y, size = 15 })
check("R5 预测失败**不影响下单** ✓（accepted/executed 都是 true ✓）",
    ok5 == true and r5.accepted == true and r5.executed == true, r5)
if ok5 == true then
    check("R5 risk.known=false ✓", r5.risk.known == false, r5.risk.known)
    check("R5 attackChance = nil（**不是 0** ✗✓）", r5.risk.attackChance == nil, tostring(r5.risk.attackChance))
    check("R5 unknownReason 写明原因 ✓",
        type(r5.risk.unknownReason) == "string" and #r5.risk.unknownReason > 0, r5.risk.unknownReason)
    check("R5 baseAttackChanceKnown=false ✓", r5.risk.baseAttackChanceKnown == false, "")
    local line = traceHas("未知原因")
    check("R5 Trace 那行写了「未知原因」✓", line ~= nil, table.concat(TRACE, " | "))
end

-- ===========================================================================
-- R6：区域分析自己失败（run 抛错）→ 也走 known=false ✓
-- ===========================================================================
print("== R6: run() 抛错 → known=false + 原因 ✓ ==")
reset()
MODE = "RUN_ERROR"
local ok6, r6 = LinkIn.onOrder({ ship = SHIP, action = "Travel", x = DEST_X, y = DEST_Y })
check("R6 分析失败也不影响下单 ✓", ok6 == true and r6.accepted == true, r6)
if ok6 == true then
    check("R6 known=false ✓", r6.risk.known == false, r6.risk.known)
    check("R6 attackChance=nil ✓", r6.risk.attackChance == nil, tostring(r6.risk.attackChance))
    check("R6 原因里提到 area analysis ✓",
        type(r6.risk.unknownReason) == "string" and r6.risk.unknownReason:find("analysis", 1, true) ~= nil,
        r6.risk.unknownReason)
end

-- ===========================================================================
-- R7：非 Travel 的动作**仍然**要求框含船 ✓（Travel 的例外没带坏别人 ✗✓）
-- ===========================================================================
print("== R7: Mine 的框不含船 → 仍然 SHIP_NOT_IN_AREA ✓ ==")
reset()
local ok7, code7 = LinkIn.predict(player, {
    what = "predict", ship = SHIP, action = "Mine",
    x = DEST_X, y = DEST_Y, sizeX = 15, sizeY = 15,
})
check("R7 Mine 框不含船 → ok=false ✓", ok7 == false, tostring(ok7))
check("R7 错误码 = SHIP_NOT_IN_AREA ✓", code7 == "SHIP_NOT_IN_AREA", tostring(code7))

-- ===========================================================================
print(string.format("== 共 %d 项断言，失败 %d 项 ==", checks, failures))
if failures == 0 then
    print("orderRiskSelfTest: OK")
else
    print("orderRiskSelfTest: FAIL")
end
