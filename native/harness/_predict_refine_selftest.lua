-- _predict_refine_selftest.lua —— 精炼原子（predict / onOrder + action="Refine"）的离线自检 ✓ 2026-10-17
--
-- 不开游戏就能验：把游戏 API 全换成替身（run / command:calculatePrediction / ShipDatabaseEntry:getCargo ✓），
-- 然后**真的调** data/scripts/net/link_in.lua 里的 CopilotLinkIn.predict / CopilotLinkIn.onOrder ✓。
--
-- 原版事实（全文实读 refinecommand.lua ✓，本自检的替身就按它成形）：
--   · 区域 31x31（:318-320）、isAreaFixed=true（:326-328）、船必须在区内（:330-332）
--   · 前置：**货舱里有原矿**（:443-446）、`config.refined[]` 必需（:427-435；缺省全选 :714-717）
--   · **不需要**精炼厂/阵营/友好度（:101-172 只是找精炼厂：找到 ÷2 时长、降税；没有 ×2 :463-468）
--   · 产出进**派系资源池**（addYield(…, 0, yields) :217），货舱原矿被扣掉（:185-211）
--   · attackChance **硬编码 0**（:364），且从不 registerForAttack（:51 只有框架注释）→ 无伏击
--
-- 覆盖（对应主人的规格 ✓）：
--   (a) predict Refine：一个框一次 run / 一次 calculatePrediction ✓
--   (b) risk：known=true、attackChance=0、riskKind 明说"原版硬编码 0 / 无伏击模型" ✓
--   (c) value：duration / tax / 逐材料 yields / 产出目的地 / 原料单位 ✓
--   (d) 尺寸不是 31 → REFINE_AREA_FIXED（明确拒绝，不猜）✓
--   (e) 框心不是船所在星区 → 与 simulation.lua:790-801 同口径**按船重新居中**，并如实回显 requestedCentre ✓
--   (f) 舱里没原矿 → predictionFailed + risk.known=false + attackChance=**nil**（绝不填 0 ✗）✓
--   (g) 批量 N 只算 N 框 ✓
--   (h) onOrder Refine：尺寸错 / 没原矿 → 明确拒绝，且**不发起**区域分析 ✓
--   (i) onOrder Refine 正常：config 只含必需项（refined 全 7 级；**没有** duration/safeMode）✓
--   (j) onOrder 回执 risk 与 predict **逐字相同** ✓ + trace 有 Refine 行 ✓
--
-- 跑法（★ 必须在 mod 仓库根跑，脚本按相对路径读文件 ✓）：
--   build\harness\lua.exe native\harness\_predict_refine_selftest.lua

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

local SHIP, SHIP_X, SHIP_Y = "Salvager-00001", -376, 60
local N_MAT = 7

-- 可变的替身状态 ---------------------------------------------------------------
local nRun, nPred = 0, 0
local MODE = "OK"                 -- OK / NO_ORES / RUN_ERROR
local CARGO = nil                 -- 由 reset() 重建（货物对象：{name, tags, amount}）
local LAST_AREA, LAST_CONFIG = nil, nil
local TRACE = {}
local INVOKED = {}

local function oreGood(name, tag, rich)
    return { name = name, tags = { ore = true, [tag] = true, rich = rich or nil } }
end

local function reset()
    nRun, nPred = 0, 0
    MODE = "OK"
    LAST_AREA, LAST_CONFIG = nil, nil
    TRACE, INVOKED = {}, {}
    CARGO = {
        -- ★ 富矿原样（tags.naonite + rich → 产出 ×4；goodsindex.lua:110 ✓）
        [oreGood("Rift Naonite Ore", "naonite", true)] = 1369,
        -- 普通原矿（tags.titanium，无 rich → 产出 ×1）
        [oreGood("Titanium Ore", "titanium", false)] = 100,
        -- 非原矿（tags 里没有任何 ore 材料 tag）→ 必须被忽略 ✓
        [{ name = "Bio Gas", tags = { basic = true } }] = 55,
    }
end

-- ---------------------------------------------------------------------------
-- 游戏 API 的替身 ✓
-- ---------------------------------------------------------------------------

CopilotRpc = { trace = function(line) TRACE[#TRACE + 1] = tostring(line) end }

function NumMaterials() return N_MAT end
function Material(i) return { name = ({ "Iron", "Titanium", "Naonite", "Trinium", "Xanion", "Ogonite", "Avorion" })[i + 1] } end
function Rarity(v) return { value = v } end

function run(factionIndex, shipName, ctype, area, callingPlayer)
    nRun = nRun + 1
    if MODE == "RUN_ERROR" then error("simulated area analysis failure") end
    LAST_AREA = area
    -- 原版 onAreaAnalysisFinished 会写进 results 的字段（refinecommand.lua:95-174 ✓）
    return shipName, ctype, area, {
        sectors = 961, reachable = 950, unreachable = 11,
        tax = 0.05, friendlySectorsFound = true, ownedRefineryFound = false, friendlyRefineryFound = true,
        biggestFactionInArea = 1, reachableCoordinates = {},
    }, callingPlayer
end

local FAKE_COMMAND = {}

function FAKE_COMMAND:getAreaSize() return { x = 31, y = 31 } end
function FAKE_COMMAND:getConfigurableValues() return {} end     -- ★ 原版 Refine 没有可配置参数（:334-337 ✓）

function FAKE_COMMAND:calculatePrediction(ownerIndex, shipName, area, config)
    nPred = nPred + 1
    LAST_AREA, LAST_CONFIG = area, config
    if MODE == "NO_ORES" then
        -- ★ 原版先写 attackChance=0/yields（:362-366），再在没发现矿时 return error（:443-446 ✓）
        return {
            attackChance = 0, tax = 0.05, duration = 0,
            yields = { 0, 0, 0, 0, 0, 0, 0 },
            error = "There are no ores or scrap metal on board the ship.",
        }
    end
    -- 成功路径：yields 是**数组**（1..NumMaterials ✓）；富矿 1369 → 5476，普通钛 100 → 100（税后）
    local yields = { 0, 100, 5476, 0, 0, 0, 0 }
    return {
        attackChance = 0,                 -- ★ 原版硬编码 0（:364 ✓）
        duration = 300,                   -- 区域里有精炼厂 → base 600/2（:463-465 ✓）
        tax = 0.05,
        nearbyRefinery = true,
        friendlySectorsFound = true,
        ownedRefineryFound = false,
        friendlyRefineryFound = true,
        yields = yields,
    }
end

function include(name)
    if name == "areaanalysis" then return nil end        -- 真的也返回 nil（只定义全局 run ✓）
    if name == "commandfactory" then
        return { makeCommand = function(ctype) return FAKE_COMMAND end }
    end
    if name == "copilot/job" then return nil end
    if name == "goods" then return {} end
    error("unexpected include: " .. tostring(name))
end

function ShipDatabaseEntry(ownerIndex, name)
    return {
        getCargo = function() return CARGO end,
        getFreeCargoSpace = function() return 500 end,
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

local function traceHas(needle)
    for _, line in ipairs(TRACE) do
        if line:find(needle, 1, true) ~= nil then return line end
    end
    return nil
end

-- ===========================================================================
-- R1：predict Refine 正常路径（一框一算 ✓ 数字来自原版预测 ✓）
-- ===========================================================================
print("== R1: predict Refine（形状 / 风险 / 产出 ✓）==")
reset()
local ok1, r1 = LinkIn.predict(player, {
    what = "predict", ship = SHIP, action = "Refine",
    x = SHIP_X, y = SHIP_Y, sizeX = 31, sizeY = 31,
})
check("R1 ok=true", ok1 == true, r1)
if ok1 == true then
    check("R1 box.containsShip=true", r1.box and r1.box.containsShip == true, r1.box and r1.box.containsShip)
    check("R1 框 = 31x31（sizeX/sizeY 原样 ✓）", r1.box.sizeX == 31 and r1.box.sizeY == 31, r1.box.sizeX .. "x" .. r1.box.sizeY)
    check("R1 单框只算一框（run 恰好 1 次 ✓）", nRun == 1, nRun)
    check("R1 预测恰好 1 次 ✓", nPred == 1, nPred)
    check("R1 risk.known=true", r1.risk and r1.risk.known == true, r1.risk and r1.risk.known)
    check("R1 attackChance=0（原版硬编码 ✓）", r1.risk and r1.risk.attackChance == 0, r1.risk and r1.risk.attackChance)
    check("R1 baseAttackChance=0（原版只有一个数 ✓）", r1.risk and r1.risk.baseAttackChance == 0, r1.risk and r1.risk.baseAttackChance)
    check("R1 riskKind 明说 hardcoded-zero / 无伏击模型 ✓",
        r1.risk and type(r1.risk.riskKind) == "string"
        and r1.risk.riskKind:find("refineVanillaHardcodedZero", 1, true) ~= nil, r1.risk and r1.risk.riskKind)
    check("R1 duration/tax 原样来自游戏 ✓",
        r1.value and r1.value.duration == 300 and r1.value.tax == 0.05,
        r1.value and (tostring(r1.value.duration) .. "/" .. tostring(r1.value.tax)))
    check("R1 yields 只列 >0 的材料（Titanium 100 / Naonite 5476 ✓）",
        r1.value and #r1.value.yields == 2
        and r1.value.yields[1].material == "Titanium" and r1.value.yields[1].units == 100
        and r1.value.yields[2].material == "Naonite" and r1.value.yields[2].units == 5476,
        r1.value and (tostring(#r1.value.yields) .. " 项"))
    check("R1 totalYield=5576", r1.value and r1.value.totalYield == 5576, r1.value and r1.value.totalYield)
    check("R1 产出目的地 = factionResources ✓", r1.value and r1.value.output == "factionResources", r1.value and r1.value.output)
    check("R1 原料单位：总数 1469 / 富矿 1369 ✓",
        r1.value and r1.value.oresToConsume == 1469 and r1.value.richOresToConsume == 1369,
        r1.value and (tostring(r1.value.oresToConsume) .. "/" .. tostring(r1.value.richOresToConsume)))
    check("R1 nearbyRefinery / durationRule 在 ✓",
        r1.value and r1.value.nearbyRefinery == true and type(r1.value.durationRule) == "string",
        r1.value and r1.value.nearbyRefinery)
    check("R1 calculatePrediction 收到 config.refined 全 7 级 ✓",
        type(LAST_CONFIG) == "table" and type(LAST_CONFIG.refined) == "table"
        and LAST_CONFIG.refined[1] == true and LAST_CONFIG.refined[7] == true, "refined 缺失")
end

-- ===========================================================================
-- R2：尺寸不是 31 → 明确拒绝（原版 isAreaFixed 只认 31x31 ✓）
-- ===========================================================================
print("== R2: 尺寸不是 31 → REFINE_AREA_FIXED ✓ ==")
reset()
local ok2, r2 = LinkIn.predict(player, {
    what = "predict", ship = SHIP, action = "Refine",
    x = SHIP_X, y = SHIP_Y, sizeX = 15, sizeY = 15,
})
check("R2 仍返回 ok=true + 载荷内 error（与其它动作的错误形状一致 ✓）", ok2 == true, ok2)
check("R2 error 以 REFINE_AREA_FIXED 开头 ✓",
    ok2 == true and type(r2.error) == "string" and r2.error:find("REFINE_AREA_FIXED", 1, true) == 1, r2 and r2.error)
check("R2 尺寸错时**不跑**分析（run 0 次 ✓）", nRun == 0, nRun)

-- ===========================================================================
-- R3：框心不是船所在星区 → 与原版 isAreaFixed 同口径按船重新居中 ✓
-- ===========================================================================
print("== R3: 框心 ≠ 船星区 → 按船重新居中（如实回显 ✓）==")
reset()
local ok3, r3 = LinkIn.predict(player, {
    what = "predict", ship = SHIP, action = "Refine",
    x = SHIP_X + 5, y = SHIP_Y - 4, sizeX = 31, sizeY = 31,
})
check("R3 ok=true", ok3 == true, r3)
if ok3 == true then
    check("R3 box.recentredOnShip=true ✓", r3.box and r3.box.recentredOnShip == true, r3.box and r3.box.recentredOnShip)
    check("R3 requestedCentre 如实回显你给的中心 ✓",
        r3.box and r3.box.requestedCentre and r3.box.requestedCentre.x == SHIP_X + 5
        and r3.box.requestedCentre.y == SHIP_Y - 4, r3.box and r3.box.requestedCentre)
    check("R3 实际框 = 船星区 ±15 ✓",
        r3.box.lower.x == SHIP_X - 15 and r3.box.lower.y == SHIP_Y - 15
        and r3.box.upper.x == SHIP_X + 15 and r3.box.upper.y == SHIP_Y + 15,
        r3.box and (tostring(r3.box.lower.x) .. "," .. tostring(r3.box.lower.y)))
    check("R3 分析用的也是船居中的框 ✓", LAST_AREA and LAST_AREA.lower.x == SHIP_X - 15, LAST_AREA and LAST_AREA.lower.x)
    check("R3 containsShip=true ✓", r3.box.containsShip == true, r3.box.containsShip)
end

-- ===========================================================================
-- R4：舱里没原矿 → 预测失败：known=false、attackChance=nil（绝不填 0 ✗）
-- ===========================================================================
print("== R4: 没有原矿 → predictionFailed + known=false（不填 0 ✓）==")
reset()
MODE = "NO_ORES"
CARGO = {
    [{ name = "Bio Gas", tags = { basic = true } }] = 55,
}
local ok4, r4 = LinkIn.predict(player, {
    what = "predict", ship = SHIP, action = "Refine",
    x = SHIP_X, y = SHIP_Y, sizeX = 31, sizeY = 31,
})
check("R4 ok=true（单框错误放在载荷里 ✓）", ok4 == true, r4)
if ok4 == true then
    check("R4 predictionFailed 写明原版原因 ✓",
        type(r4.predictionFailed) == "string"
        and r4.predictionFailed:find("no ores", 1, true) ~= nil, r4.predictionFailed)
    check("R4 risk.known=false ✓", r4.risk and r4.risk.known == false, r4.risk and r4.risk.known)
    check("R4 attackChance=nil（**不是 0** ✗✓）", r4.risk == nil or r4.risk.attackChance == nil,
        r4.risk and tostring(r4.risk.attackChance))
    check("R4 unknownReason 有内容 ✓",
        r4.risk and type(r4.risk.unknownReason) == "string" and #r4.risk.unknownReason > 10,
        r4.risk and r4.risk.unknownReason)
    check("R4 value.oresOnBoard=0（如实报告舱里没有原矿 ✓）",
        r4.value and r4.value.oresOnBoard == 0, r4.value and r4.value.oresOnBoard)
end

-- ===========================================================================
-- R5：批量 N=2 只算 N 框 ✓
-- ===========================================================================
print("== R5: 批量 N=2 只算 N 框 ✓ ==")
reset()
local ok5, r5 = LinkIn.predict(player, {
    what = "predict", ship = SHIP, action = "Refine",
    boxes = {
        { x = SHIP_X, y = SHIP_Y, sizeX = 31, sizeY = 31 },
        { x = SHIP_X, y = SHIP_Y, sizeX = 31, sizeY = 31 },
    },
})
check("R5 批量 ok=true", ok5 == true, r5)
if ok5 == true then
    check("R5 boxCount=2", r5.boxCount == 2, r5.boxCount)
    check("R5 run 恰好 2 次 ✓", nRun == 2, nRun)
    check("R5 预测恰好 2 次 ✓", nPred == 2, nPred)
end

-- ===========================================================================
-- R6：onOrder 尺寸错 → 明确拒绝，且**不发起**区域分析 ✓
-- ===========================================================================
print("== R6: onOrder 尺寸错 → REFINE_AREA_FIXED（不发起分析 ✓）==")
reset()
local ok6, code6 = LinkIn.onOrder({ ship = SHIP, action = "Refine", x = SHIP_X, y = SHIP_Y, size = 15 })
check("R6 ok=false ✓", ok6 == false, tostring(code6))
check("R6 错误码 = REFINE_AREA_FIXED ✓", code6 == "REFINE_AREA_FIXED", tostring(code6))
check("R6 没有发起区域分析（INVOKED 空 ✓）", #INVOKED == 0, #INVOKED)

-- ===========================================================================
-- R7：onOrder 没有原矿 → NO_ORES（拒绝，不替玩家补矿 ✓）
-- ===========================================================================
print("== R7: onOrder 没有原矿 → NO_ORES（不发起分析 ✓）==")
reset()
CARGO = { [{ name = "Bio Gas", tags = { basic = true } }] = 55 }
local ok7, code7 = LinkIn.onOrder({ ship = SHIP, action = "Refine", x = SHIP_X, y = SHIP_Y, size = 31 })
check("R7 ok=false ✓", ok7 == false, tostring(code7))
check("R7 错误码 = NO_ORES ✓", code7 == "NO_ORES", tostring(code7))
check("R7 没有发起区域分析（INVOKED 空 ✓）", #INVOKED == 0, #INVOKED)

-- ===========================================================================
-- R8：onOrder 正常 → config 只含必需项 + 回执 risk == predict risk ✓
-- ===========================================================================
print("== R8: onOrder 正常（最小参数 + 回执风险 ✓）==")
reset()
local okP, rP = LinkIn.predict(player, {
    what = "predict", ship = SHIP, action = "Refine",
    x = SHIP_X, y = SHIP_Y, sizeX = 31, sizeY = 31,
})
reset()
local ok8, r8 = LinkIn.onOrder({ ship = SHIP, action = "Refine", x = SHIP_X, y = SHIP_Y, size = 31 })
check("R8 order ok=true / accepted=true ✓", ok8 == true and r8.accepted == true, r8)
if ok8 == true then
    check("R8 发起了区域分析（INVOKED 有 1 项 ✓）", #INVOKED == 1 and INVOKED[1] == "startAreaAnalysis", #INVOKED)
    check("R8 config.refined 全 7 级 ✓",
        type(r8.config.refined) == "table" and r8.config.refined[1] == true and r8.config.refined[7] == true,
        r8.config.refined and tostring(r8.config.refined[1]))
    check("R8 config **没有** duration / safeMode（Refine 没有这些参数 ✓）",
        r8.config.duration == nil and r8.config.safeMode == nil,
        tostring(r8.config.duration) .. "/" .. tostring(r8.config.safeMode))
    check("R8 回执 risk.attackChance=0（= predict 的数 ✓）",
        r8.risk and r8.risk.attackChance == 0, r8.risk and tostring(r8.risk.attackChance))
    check("R8 riskKind 与 predict 一致 ✓",
        okP == true and r8.risk and r8.risk.riskKind == rP.risk.riskKind, r8.risk and r8.risk.riskKind)
    check("R8 riskNote 提到 Refine 的 0 是硬编码 ✓",
        type(r8.riskNote) == "string" and r8.riskNote:find("Refine", 1, true) ~= nil, r8.riskNote)
    local line = traceHas("onOrder Refine")
    check("R8 trace 有「onOrder Refine」行 ✓", line ~= nil, table.concat(TRACE, " | "))
    check("R8 trace 那行写了原矿单位 ✓",
        line ~= nil and line:find("1469", 1, true) ~= nil, tostring(line))
end

-- ===========================================================================
-- R9：order 给了别的框心（尺寸 31）→ 接受（原版会按船重算 ✓），风险仍是同一个数 ✓
-- ===========================================================================
print("== R9: order 框心 ≠ 船星区（尺寸 31）→ 接受 + 风险已知 ✓ ==")
reset()
local ok9, r9 = LinkIn.onOrder({ ship = SHIP, action = "Refine", x = SHIP_X + 7, y = SHIP_Y + 3, sizeX = 31, sizeY = 31 })
check("R9 ok=true（原版 isAreaFixed 会重算框心 ✓）", ok9 == true and r9.accepted == true, r9)
check("R9 回执 risk.known=true（预测按船居中算 ✓）", ok9 == true and r9.risk and r9.risk.known == true,
    r9 and r9.risk and tostring(r9.risk.known))

-- ===========================================================================
print(string.format("== 共 %d 项断言，失败 %d 项 ==", checks, failures))
if failures == 0 then
    print("predictRefineSelfTest: OK")
else
    print("predictRefineSelfTest: FAIL")
end
