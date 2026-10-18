-- _job_equipment_error_selftest.lua —— 「没有 XX 装备」这句报错的**数字补全**自检（2026-10-19 加 ✓）
--
-- 不开游戏就能验：把游戏 API 全部换成替身，然后**真的调** CopilotLinkIn.predict ✓✓。
--
-- 覆盖到的点（每条都是**具体字符串/数字**断言）：
--   ① Salvage：`turretCategories.Salvaging > 0` → predict **必须成功**（有 items / risk ✓）
--   ② Salvage：Salvaging = 0 但 Armed = 4 → 失败文案**带实测数字**，且点出原版
--      getErrors(:545) 与 calculatePrediction(:896) 对 armedSalvaging 的**自相矛盾** ✓
--   ③ Mine：Mining = 0 → 失败文案带数字，且写明"采矿没有武装备用口径" ✓
--   ④ Mine：Mining = 2 → predict 成功 ✓
--   ⑤ 船档案读不到 → 文案写 UNKNOWN，**绝不写 turretCount=0** ✗✓
--   ⑥ 非装备类报错（"This operation won't yield anything!"）→ **原样返回**（逐字相等 ✓）
--   ⑦ 中文原版文案（zh.po:44851「舰船缺少分解装备！」）也要认 ✓
--   ⑧ 缓存：一批 3 个都失败的框 → `Card.equipmentFacts` **只被调 1 次** ✓
--   ⑨ 补全后的文案仍是可 JSON 编解码的普通字符串 ✓
--
-- 跑法：  native\harness\lua.exe native\harness\_job_equipment_error_selftest.lua

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

local SHIP, SHIP_X, SHIP_Y = "Salvager-00001", -225, -40
local N_MAT = 7
local MAT_NAMES = { "Iron", "Titanium", "Naonite", "Trinium", "Xanion", "Ogonite", "Avorion" }

-- ---------------------------------------------------------------------------
-- 游戏 API 替身
-- ---------------------------------------------------------------------------

CopilotRpc = { trace = function() end }

function NumMaterials() return N_MAT end

function Material(i)
    local name = MAT_NAMES[i + 1]
    if name == nil then error("bad material index " .. tostring(i)) end
    return { name = name, costFactor = i + 1, strengthFactor = 1 }
end

function Rarity(v) return { value = v, name = "R" .. tostring(v) } end

local function good(price, size)
    local g = { price = price, size = size }
    g.good = function(self) return self end
    return g
end

local GOODS = {}
for i = 1, N_MAT do GOODS[MAT_NAMES[i] .. " Ore"] = good(2 + i, 0.025) end

-- ★ 船档案事实（每个用例改它 ✓）—— `Card.equipmentFacts` 的替身从这里取 ✓
local SHIP_FACTS = {
    unreadable = false,
    turretCount = 0,
    categories = {},
    fighters = 0,
}

local EQUIP_CALLS = 0

local FAKE_CARD = {}
function FAKE_CARD.equipmentFacts(_player, entry, card, notes)
    EQUIP_CALLS = EQUIP_CALLS + 1
    local f = (entry and entry.__facts) or SHIP_FACTS
    if f.unreadable then
        card.turretCountKnown = false
        notes.turrets = "simulated unreadable turret list"
        return
    end
    card.turretCount = f.turretCount
    card.turretCategories = f.categories
    card.turretCountKnown = true
    card.fighters = f.fighters or 0
    card.fightersKnown = true
end

function ShipDatabaseEntry(_ownerIndex, _name)
    return { __facts = SHIP_FACTS, getFreeCargoSpace = function() return 10000 end }
end

-- 区域分析替身（原版 areaanalysis.lua 只负责定义全局 run ✓）
function run(_factionIndex, shipName, ctype, area, callingPlayer)
    local results = {
        routes = {},
        materials = { 0, 0.5, 0.5, 0, 0, 0, 0 }, safeMaterials = { 0, 0.5, 0.5, 0, 0, 0, 0 },
        sectors = 225, reachable = 220, unreachable = 5,
        biggestFactionInArea = 1, reachableCoordinates = {},
        safeSectors = { 1, 2 }, asteroids = 0, wrecks = 12, volume = 500,
    }
    return shipName, ctype, area, results, callingPlayer
end

-- ★ 预测替身：三档 —— 成功 / 英文原版文案 / 中文原版文案 / 非装备类报错
local PROP = { ok = false, errText = nil }

local FAKE_COMMAND = {}

function FAKE_COMMAND:getAreaSize() return { x = 15, y = 15 } end

function FAKE_COMMAND:getConfigurableValues()
    return {
        duration = { displayName = "Duration", from = 0.5, to = 2, default = 1 },
        safeMode = { displayName = "Safe Mode", default = false },
        immediateDelivery = { displayName = "Immediate Delivery", default = false },
    }
end

function FAKE_COMMAND:getSalvagingProperties() return { materials = {}, cargoSpace = 10000 } end
function FAKE_COMMAND:getMiningProperties() return { materials = {}, cargoSpace = 10000 } end

function FAKE_COMMAND:calculatePrediction(_ownerIndex, _shipName, _area, _config)
    if not PROP.ok then
        return { attackChance = { value = 0 }, items = { from = 0, to = 0 }, yields = {},
                 error = PROP.errText or "The ship has no salvaging equipment!" }
    end
    local yields = {}
    for i = 1, N_MAT do
        local v = (i == 2) and 12 or 0            -- 只有 Titanium 有产出 ✓
        yields[i] = { from = v * 0.8, to = v }
    end
    return {
        attackChance = { value = 0.03 }, items = { from = 7, to = 10 },
        yields = yields, error = nil,
    }
end

function include(name)
    if name == "areaanalysis" then return nil end
    if name == "commandfactory" then
        return { makeCommand = function(_ctype) return FAKE_COMMAND end }
    end
    if name == "copilot/job" then return dofile("data/scripts/lib/copilot/job.lua") end
    if name == "copilot/card" then return FAKE_CARD end
    if name == "goods" then return GOODS end
    error("unexpected include: " .. tostring(name))
end

local player = {
    index = 1,
    getShipPosition = function(self, name) return SHIP_X, SHIP_Y end,
}

local LinkIn = dofile("data/scripts/net/link_in.lua")
local JSON = dofile("data/scripts/lib/copilot/json.lua")

-- ---------------------------------------------------------------------------
-- 小工具
-- ---------------------------------------------------------------------------

local function predict(action, extra)
    local data = { ship = SHIP, action = action, x = SHIP_X, y = SHIP_Y, sizeX = 15, sizeY = 15 }
    for k, v in pairs(extra or {}) do data[k] = v end
    local ok, a, b = pcall(LinkIn.predict, player, data)
    if not ok then return nil, "THREW: " .. tostring(a) end
    return { ok = a, first = b, second = nil }
end

local function jsonRoundTrip(v)
    local okE, s = pcall(function() return JSON.encode(v) end)
    if not okE then return nil, "encode threw: " .. tostring(s) end
    local okD, back = pcall(function() return JSON.decode(s) end)
    if not okD then return nil, "decode threw: " .. tostring(back) end
    return back
end

local function has(s, sub)
    return type(s) == "string" and s:find(sub, 1, true) ~= nil
end

-- ===========================================================================
print("① Salvage：Salvaging=4 → predict 必须成功（有 items / risk）")
-- ===========================================================================
SHIP_FACTS = { turretCount = 8, categories = { Armed = 4, Salvaging = 4 }, fighters = 0 }
PROP = { ok = true }
EQUIP_CALLS = 0
do
    local r = predict("Salvage")
    check("① a predict 返回 ok=true", r ~= nil and r.ok == true, tostring(r and r.ok))
    local body = r and r.first
    check("① b 有 value.items（7~10 件）",
        type(body) == "table" and type(body.value) == "table"
        and body.value.items and body.value.items.from == 7 and body.value.items.to == 10,
        body and body.value and body.value.items and (tostring(body.value.items.from) .. "~" .. tostring(body.value.items.to)))
    check("① c 有 risk.attackChance = 0.03",
        type(body) == "table" and type(body.risk) == "table" and body.risk.attackChance == 0.03,
        body and body.risk and tostring(body.risk.attackChance))
    check("① d 没有 predictionFailed", type(body) == "table" and body.predictionFailed == nil,
        body and tostring(body.predictionFailed))
    check("① e 成功路径**不读**装备事实（EQUIP_CALLS = 0）", EQUIP_CALLS == 0, "calls=" .. tostring(EQUIP_CALLS))
end

-- ===========================================================================
print("② Salvage：Salvaging=0 / Armed=4 → 文案必须带实测数字 + 点出原版自相矛盾")
-- ===========================================================================
SHIP_FACTS = { turretCount = 4, categories = { Armed = 4 }, fighters = 0 }
PROP = { ok = false, errText = "The ship has no salvaging equipment!" }
EQUIP_CALLS = 0
local salvageMsg = nil
do
    local r = predict("Salvage")
    check("② a predict 仍然失败（判定不改 ✓）", r ~= nil and r.ok == true and type(r.first) == "table"
        and r.first.predictionFailed ~= nil, tostring(r and r.ok))
    salvageMsg = r and r.first and r.first.predictionFailed
    check("② b 保留原版原文", has(salvageMsg, "The ship has no salvaging equipment!"), salvageMsg)
    check("② c 带 turretCount=4", has(salvageMsg, "turretCount=4"), salvageMsg)
    check("② d 带全 5 类逐项计数（Salvaging:0 / Armed:4）",
        has(salvageMsg, "turretCategories={Armed:4,Mining:0,Salvaging:0,Heal:0,None:0}"), salvageMsg)
    check("② e 带 fighters=0（舰载机也能捞 ✓）", has(salvageMsg, "fighters=0"), salvageMsg)
    check("② f 说明需要 Salvaging 类别 + 原版出处",
        has(salvageMsg, "category 'Salvaging'") and has(salvageMsg, "salvagecommand.lua:626-805"), salvageMsg)
    check("② g 点出 getErrors(:545) vs calculatePrediction(:896) 对 armedSalvaging 不一致",
        has(salvageMsg, "armedSalvaging") and has(salvageMsg, ":545") and has(salvageMsg, ":896")
        and has(salvageMsg, "4 armed turret(s)"), salvageMsg)
    check("② h 读装备事实**只调 1 次**", EQUIP_CALLS == 1, "calls=" .. tostring(EQUIP_CALLS))

    local back, err = jsonRoundTrip(r.first)
    check("② i 响应仍可 JSON 往返", back ~= nil, err)
    check("② j 往返后文案逐字相同", back ~= nil and back.predictionFailed == salvageMsg,
        back and back.predictionFailed)
end

-- ===========================================================================
print("③ Mine：Mining=0 → 文案带数字 + 写明采矿没有武装备用口径")
-- ===========================================================================
SHIP_FACTS = { turretCount = 8, categories = { Armed = 4, Salvaging = 4 }, fighters = 0 }
PROP = { ok = false, errText = "The ship has no mining equipment!" }
EQUIP_CALLS = 0
do
    local r = predict("Mine")
    local msg = r and r.first and r.first.predictionFailed
    check("③ a 失败且保留原文", has(msg, "The ship has no mining equipment!"), msg)
    check("③ b 带 turretCount=8",
        has(msg, "turretCount=8") and has(msg, "Mining:0") and has(msg, "Salvaging:4"), msg)
    check("③ c 说明需要 Mining 类别 + 原版出处（:570 / :612）",
        has(msg, "category 'Mining'") and has(msg, "minecommand.lua:545+") and has(msg, ":570"), msg)
    check("③ d 写明采矿**没有** armed fallback",
        has(msg, "mining has NO armed fallback"), msg)
    check("③ e **不**串到 salvage 那句（文案里没有 armedSalvaging 提示）",
        not has(msg, "armedSalvaging"), msg)
    check("③ f 读装备事实只调 1 次", EQUIP_CALLS == 1, "calls=" .. tostring(EQUIP_CALLS))
end

-- ===========================================================================
print("④ Mine：Mining=2 → predict 成功")
-- ===========================================================================
SHIP_FACTS = { turretCount = 2, categories = { Mining = 2 }, fighters = 0 }
PROP = { ok = true }
do
    local r = predict("Mine")
    local body = r and r.first
    check("④ a ok=true 且无 predictionFailed",
        r ~= nil and r.ok == true and type(body) == "table" and body.predictionFailed == nil,
        body and tostring(body.predictionFailed))
    local function near(a, b) return type(a) == "number" and math.abs(a - b) < 1e-9 end
    check("④ b 有 value 与层级数字（Titanium 档：weight=2 → 9.6*2 ~ 12*2）",
        type(body) == "table" and type(body.value) == "table"
        and near(body.value.valueHigh, 24) and near(body.value.valueLow, 19.2)
        and body.value.topTier == 2 and body.value.topMaterial == "Titanium",
        body and body.value and (tostring(body.value.valueLow) .. "~" .. tostring(body.value.valueHigh)
            .. " top=" .. tostring(body.value.topMaterial)))
end

-- ===========================================================================
print("⑤ 船档案读不到 → 文案写 UNKNOWN，**绝不写 turretCount=0**")
-- ===========================================================================
SHIP_FACTS = { unreadable = true }
PROP = { ok = false, errText = "The ship has no salvaging equipment!" }
do
    local r = predict("Salvage")
    local msg = r and r.first and r.first.predictionFailed
    check("⑤ a 带 UNKNOWN + 原因", has(msg, "[copilot facts: UNKNOWN") and has(msg, "simulated unreadable turret list"), msg)
    check("⑤ b **不**出现 turretCount=（读不到不许写 0 ✓）", not has(msg, "turretCount="), msg)
    check("⑤ c 保留原版原文", has(msg, "The ship has no salvaging equipment!"), msg)
end

-- ===========================================================================
print("⑥ 非装备类报错 → 原样返回（逐字相等）")
-- ===========================================================================
SHIP_FACTS = { turretCount = 8, categories = { Armed = 4, Salvaging = 4 }, fighters = 0 }
PROP = { ok = false, errText = "There are no sectors to salvage in in this area!" }
do
    local r = predict("Salvage")
    local msg = r and r.first and r.first.predictionFailed
    check("⑥ a 逐字相等（没被加料）", msg == "There are no sectors to salvage in in this area!", msg)
    check("⑥ b 没有 copilot facts 尾巴", not has(msg, "copilot facts"), msg)
end

-- ===========================================================================
print("⑦ 中文原版文案（zh.po:44851）也要认")
-- ===========================================================================
SHIP_FACTS = { turretCount = 4, categories = { Armed = 4 }, fighters = 0 }
PROP = { ok = false, errText = "舰船缺少分解装备！" }
do
    local r = predict("Salvage")
    local msg = r and r.first and r.first.predictionFailed
    check("⑦ a 中文原文保留", has(msg, "舰船缺少分解装备！"), msg)
    check("⑦ b 仍然补上数字", has(msg, "turretCount=4") and has(msg, "Salvaging:0"), msg)

    SHIP_FACTS = { turretCount = 8, categories = { Salvaging = 4, Armed = 4 }, fighters = 0 }
    PROP = { ok = false, errText = "舰船缺少采矿装备！" }
    local r2 = predict("Mine")
    local msg2 = r2 and r2.first and r2.first.predictionFailed
    check("⑦ c 中文采矿文案也认", has(msg2, "舰船缺少采矿装备！") and has(msg2, "category 'Mining'"), msg2)
end

-- ===========================================================================
print("⑧ 缓存：一批 3 个失败框 → Card.equipmentFacts 只调 1 次")
-- ===========================================================================
SHIP_FACTS = { turretCount = 4, categories = { Armed = 4 }, fighters = 0 }
PROP = { ok = false, errText = "The ship has no salvaging equipment!" }
EQUIP_CALLS = 0
do
    local boxes = {
        { x = SHIP_X, y = SHIP_Y, sizeX = 15, sizeY = 15 },
        { x = SHIP_X, y = SHIP_Y, sizeX = 15, sizeY = 15 },
        { x = SHIP_X, y = SHIP_Y, sizeX = 15, sizeY = 15 },
    }
    local ok, a, b = pcall(LinkIn.predict, player, { ship = SHIP, action = "Salvage", boxes = boxes })
    check("⑧ a 批量 predict 没抛异常", ok == true, tostring(a))
    local body = ok and b or a
    check("⑧ b 三个框都失败", type(body) == "table" and body.boxCount == 3, type(body) == "table" and tostring(body.boxCount))
    local allEnriched = true
    if type(body) == "table" and type(body.boxes) == "table" then
        for _, e in ipairs(body.boxes) do
            if not (type(e.predictionFailed) == "string" and has(e.predictionFailed, "turretCount=4")) then
                allEnriched = false
            end
        end
    else
        allEnriched = false
    end
    check("⑧ c 三个框的文案都带数字", allEnriched, "boxes enriched failed")
    check("⑧ d 装备事实**只读 1 次**（缓存生效 ✓）", EQUIP_CALLS == 1, "calls=" .. tostring(EQUIP_CALLS))
end

-- ===========================================================================
print("⑨ 全 0 门炮（turretCount=0）→ 明确说「真的没有该类装备」")
-- ===========================================================================
SHIP_FACTS = { turretCount = 0, categories = {}, fighters = 0 }
PROP = { ok = false, errText = "The ship has no salvaging equipment!" }
do
    local r = predict("Salvage")
    local msg = r and r.first and r.first.predictionFailed
    check("⑨ a turretCount=0 且 5 类全 0",
        has(msg, "turretCount=0") and has(msg, "turretCategories={Armed:0,Mining:0,Salvaging:0,Heal:0,None:0}"), msg)
    check("⑨ b 说清「那一刻真的没有该设备」（不是读错）",
        has(msg, "the ship really has no such device right now"), msg)
end

-- ===========================================================================
print(string.format(""))
print(string.format("checks=%d  failures=%d", checks, failures))
if failures > 0 then os.exit(1) end
print("ALL PASS")
