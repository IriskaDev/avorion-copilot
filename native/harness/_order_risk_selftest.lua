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
--   build\harness\lua.exe native\harness\_order_risk_selftest.lua

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
local LAST_ESCORTS = nil                  -- 最近一次 calculatePrediction 收到的 config.escorts ✓

local function reset()
    nRun, nPred = 0, 0
    MODE = "JOB"
    PRED_ERROR = nil
    TRACE = {}
    LAST_ESCORTS = nil
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
    -- ★ 护航也会改概率（原版 SimulationUtility.calculateAttackProbability 把 escort 的
    --   dps/hp 加进 selfDps/selfHP、并且强护航再乘 0.75 ✓）—— 替身用 0.25 倍率模拟，
    --   这样「护航到底有没有传进 calculatePrediction」就能用**数字**断言 ✓（不是看日志猜 ✗）。
    local hasEscort = (type(config.escorts) == "table" and #config.escorts > 0)
    LAST_ESCORTS = hasEscort and config.escorts or nil
    local chance = JOB_CHANCE
    if hasEscort then chance = JOB_CHANCE * 0.25 end
    if config.safeMode == true then chance = chance * 0.5 end
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
-- R6：区域分析自己失败（run 抛错）→ ★ 预检直接拒（2026-10-17 新行为 ✓✓）
--
-- 旧断言是「分析失败也不影响下单」✗ —— 那正是主人今晚点破的病 ✓：
--   Travel 的分析算不出 route 时，原版 `startCommand` 会走
--   "No area analyzed for X."（simulation.lua:472-476）**静默 return** ✗，
--   于是回执 accepted:true、船却不动 ✓✓。
-- → 预检（link_in.lua preflightOf）在**下单前**就用同一份 predict 验 route：
--   算不出来 = `ANALYSIS_FAILED`、accepted=false、**什么都没发** ✓。
--   而"预测**数字**算不出来"（R5：predict 回 error，但 route 在 ✓）**仍然是照下单** ✓
--   —— 两件事别混 ✗✓。
-- ===========================================================================
print("== R6: run() 抛错 → 预检拒绝（ANALYSIS_FAILED，不下单 ✓）==")
reset()
MODE = "RUN_ERROR"
local invokedBefore = #INVOKED
local queuedBefore = #LinkIn.pendingOrders
local ok6, r6 = LinkIn.onOrder({ ship = SHIP, action = "Travel", x = DEST_X, y = DEST_Y })
check("R6 预检不过 → accepted=false ✓", ok6 == true and r6.accepted == false, r6)
if ok6 == true then
    check("R6 preflight.ok=false ✓", type(r6.preflight) == "table" and r6.preflight.ok == false,
        type(r6.preflight))
    check("R6 preflight.code = ANALYSIS_FAILED ✓",
        r6.preflight.code == "ANALYSIS_FAILED", tostring(r6.preflight.code))
    check("R6 preflight.reason 提到 jump route / area analysis ✓",
        type(r6.preflight.reason) == "string"
        and (r6.preflight.reason:find("jump route", 1, true) ~= nil
            or r6.preflight.reason:find("analysis", 1, true) ~= nil),
        r6.preflight.reason)
    check("R6 executed=false（没进 startCommand ✓）", r6.executed == false, r6.executed)
    check("R6 ★ 这一单没发起区域分析（INVOKED 没有新增 ✓）", #INVOKED == invokedBefore,
        table.concat(INVOKED, ","))
    check("R6 ★ 这一单没排进 startCommand 队列 ✓", #LinkIn.pendingOrders == queuedBefore,
        #LinkIn.pendingOrders)
    check("R6 没有 risk 字段（预检不过就不算风险 ✓）", r6.risk == nil, type(r6.risk))
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
-- R8 / R9 / R10：护航必须真的进 calculatePrediction ✓（2026-10-20 真机 87% vs 2% 的回归）
--
-- 病灶（修前）：`predict` 的**批量**形态只读每个 box 自己的 `b.escorts`
--   （predictOneBox → :6948-6953 / :6912-6916），顶层 `data.escorts` 被**静默丢弃** ✗
--   → 决策者按文档「boxes[] + 顶层 escorts」量框时，整批按"裸跑"算（真机 79%/87%），
--     而真下单回执（config.escorts → orderRiskOf）报 2% ✓✗ 三处数字互相打架。
-- 修后语义：box 自己的 escorts 优先，缺省继承顶层 ✓（与 tradeEvaluate / orderRiskOf 一致 ✓）。
-- ===========================================================================
print("== R8: 批量 boxes[] + 顶层 escorts → 护航必须生效 ✓ ==")
reset()
local ok8, r8 = LinkIn.predict(player, {
    what = "predict", ship = SHIP, action = "Mine",
    escorts = { "Raven" },
    boxes = {
        { x = SHIP_X, y = SHIP_Y, sizeX = 15, sizeY = 15 },
        { x = SHIP_X, y = SHIP_Y, sizeX = 15, sizeY = 15 },
    },
})
check("R8 批量 ok=true", ok8 == true and type(r8.boxes) == "table" and #r8.boxes == 2, r8)
if ok8 == true and type(r8.boxes) == "table" then
    local b1, b2 = r8.boxes[1], r8.boxes[2]
    check("R8 框1 风险 = 带护航的 0.0075 ✓（= 0.03 × 0.25 ✓）",
        b1 and b1.risk and b1.risk.attackChance == 0.0075, b1 and b1.risk and b1.risk.attackChance)
    check("R8 框2 风险 = 带护航的 0.0075 ✓", b2 and b2.risk and b2.risk.attackChance == 0.0075,
        b2 and b2.risk and b2.risk.attackChance)
    check("R8 每框回 escortsApplied = {Raven} ✓（护航到底进去没，回执直接可看 ✓）",
        b1 and type(b1.escortsApplied) == "table" and b1.escortsApplied[1] == "Raven"
        and b2 and type(b2.escortsApplied) == "table" and b2.escortsApplied[1] == "Raven",
        tostring(b1 and b1.escortsApplied and b1.escortsApplied[1]))
    check("R8 ★ 护航真的到了 calculatePrediction（替身收到 config.escorts ✓）",
        type(LAST_ESCORTS) == "table" and LAST_ESCORTS[1] == "Raven", tostring(LAST_ESCORTS))
end

print("== R8b: 批量**不带** escorts → 仍是裸跑数（对照 ✓）==")
reset()
local ok8b, r8b = LinkIn.predict(player, {
    what = "predict", ship = SHIP, action = "Mine",
    boxes = { { x = SHIP_X, y = SHIP_Y, sizeX = 15, sizeY = 15 } },
})
check("R8b 对照 ok=true 且风险 = 裸跑 0.03 ✓",
    ok8b == true and r8b.boxes and r8b.boxes[1].risk.attackChance == 0.03,
    ok8b == true and r8b.boxes and r8b.boxes[1].risk.attackChance)
check("R8b 没有 escortsApplied（没护航就不编 ✓）",
    ok8b == true and r8b.boxes and r8b.boxes[1].escortsApplied == nil,
    ok8b == true and r8b.boxes and tostring(r8b.boxes[1].escortsApplied))

print("== R9: 单框内嵌 escorts 与批量顶层 escorts **逐字同数** ✓ ==")
reset()
local ok9, r9 = LinkIn.predict(player, {
    what = "predict", ship = SHIP, action = "Mine",
    x = SHIP_X, y = SHIP_Y, sizeX = 15, sizeY = 15, escorts = { "Raven" },
})
check("R9 单框带护航 ok=true 且 0.0075 ✓",
    ok9 == true and r9.risk and r9.risk.attackChance == 0.0075, r9 and r9.risk and r9.risk.attackChance)
check("R9 两种写法同数 ✓（批量 vs 单框）",
    ok8 == true and ok9 == true and r8.boxes[1].risk.attackChance == r9.risk.attackChance,
    tostring(ok8 == true and r8.boxes[1].risk.attackChance) .. " vs " .. tostring(r9.risk.attackChance))
check("R9 两种写法同 riskKind ✓",
    ok8 == true and ok9 == true and r8.boxes[1].risk.riskKind == r9.risk.riskKind, "")

print("== R10: order 回执 risk == predict risk（带护航，三处对齐 ✓）==")
reset()
local ok10, r10 = LinkIn.onOrder({
    ship = SHIP, action = "Mine", x = SHIP_X, y = SHIP_Y, size = 15, duration = 1,
    escorts = { "Raven" },
})
check("R10 order 带护航 ok=true 且 accepted=true", ok10 == true and r10.accepted == true, r10)
if ok10 == true and r10.accepted == true then
    check("R10 回执 attackChance = 0.0075（护航进了原版函数 ✓）",
        r10.risk and r10.risk.attackChance == 0.0075, r10.risk and r10.risk.attackChance)
    check("R10 ★ 回执 == predict（同一份代码 ✓，修前这里是 0.03 vs 0.0075 ✗）",
        r10.risk and r9.risk and r10.risk.attackChance == r9.risk.attackChance
        and r10.risk.baseAttackChance == r9.risk.baseAttackChance,
        tostring(r10.risk and r10.risk.attackChance) .. " vs " .. tostring(r9.risk and r9.risk.attackChance))
end

-- ===========================================================================
print(string.format("== 共 %d 项断言，失败 %d 项 ==", checks, failures))
if failures == 0 then
    print("orderRiskSelfTest: OK")
else
    print("orderRiskSelfTest: FAIL")
end
