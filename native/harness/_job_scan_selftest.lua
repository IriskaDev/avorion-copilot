-- _job_scan_selftest.lua —— Mine / Salvage 的 jobPlan（多区域 × 参数 × 层级加权）离线自检 ✓
--
-- 不开游戏就能验：把游戏 API 全部换成替身（run / command / NumMaterials / Material / Rarity / goods ✓），
-- 然后**真的调** data/scripts/net/link_in.lua 里的 CopilotLinkIn.jobPlan ✓✓。
--
-- 覆盖到的点（每条都是**具体数字**，不是"看起来对" ✓）：
--   ① 层级权重口径（原版矿价阶梯，带 scoreBasis ✓）
--   ② 「高阶矿区」压过「低阶但吨位更大的区」✓（主人钦定：尽可能采高级矿 ✓）
--   ③ 风险闸门 0.10：超闸门 = acceptable=false 且**绝不进入 recommendation** ✓
--   ④ 参数维度：safeMode / escorts / duration 三种救援与收益档 ✓
--   ⑤ 所有候选区域**必须含船** ✓；非法尺寸一律换回原版合法尺寸（15x15 ✓）
--   ⑥ Salvage：装备件数 × E[稀有度层级]（1.23 ✓）；fieldTier 只当次级键 ✓
--   ⑦ 响应可 JSON 编解码 + orderHint 能直接喂给 order ✓
--
-- 跑法：  build\harness\lua.exe native\harness\_job_scan_selftest.lua

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

local SHIP, SHIP_X, SHIP_Y = "Miner-00001", -412, 73
local N_MAT = 7
local MAT_NAMES = { "Iron", "Titanium", "Naonite", "Trinium", "Xanion", "Ogonite", "Avorion" }
-- ★ 原版矿价阶梯：goodsindex.lua（Iron Ore=2 … Avorion Ore=12 ✓，逐条可查 ✓）
local ORE_PRICE = { 2, 3, 4, 5, 7, 9, 12 }

local ALL_RISKY = false
local COST_FACTOR = nil          -- 给数组就走 costFactor 口径；nil 就走矿价口径 ✓
local CAN_MINE = {}              -- [i] = false → getMiningProperties 的 dps = 0 ✓
local nRun, nPred = 0, 0

-- ---------------------------------------------------------------------------
-- 游戏 API 的替身
-- ---------------------------------------------------------------------------

CopilotRpc = { trace = function() end }

function NumMaterials() return N_MAT end

function Material(i)
    local name = MAT_NAMES[i + 1]
    if name == nil then error("bad material index " .. tostring(i)) end
    local m = { name = name }
    if COST_FACTOR ~= nil then m.costFactor = COST_FACTOR[i + 1] end
    return m
end

-- 原版稀有度对象：Rarity(value).value == RarityType 枚举序号 ✓（Enums.html ✓）
function Rarity(v) return { value = v, name = "R" .. tostring(v) } end

local function good(price, size)
    local g = { price = price, size = size }
    g.good = function(self) return self end
    return g
end

local GOODS = {}
for i = 1, N_MAT do GOODS[MAT_NAMES[i] .. " Ore"] = good(ORE_PRICE[i], 0.025) end
GOODS["Oxygen"] = good(80, 1)

-- ---------------------------------------------------------------------------
-- 区域规格（按"区域中心相对船星的偏移"布置 ✓ —— 与 trade 自检同款做法 ✓）
-- ---------------------------------------------------------------------------

local SPEC = {}

local function resetSpec()
    SPEC = {}
    ALL_RISKY = false
    COST_FACTOR = nil
    CAN_MINE = {}
end

local function offsetOfArea(area)
    local size = area.upper.x - area.lower.x + 1
    local half = math.floor((size - 1) / 2)
    return (area.lower.x + half) - SHIP_X, (area.lower.y + half) - SHIP_Y
end

function run(factionIndex, shipName, ctype, area, callingPlayer)
    nRun = nRun + 1
    local ox, oy = offsetOfArea(area)
    local key = ox .. "," .. oy
    local s = SPEC[key]
    if s == "ERROR" then error("simulated area analysis failure") end

    local materials = {}
    for i = 1, N_MAT do materials[i] = 0 end
    if type(s) == "table" then
        for i, v in pairs(s.materials or {}) do materials[i] = v end
    end

    local results = {
        routes = {}, probe = key,
        materials = materials, safeMaterials = materials,
        sectors = 225, reachable = 220, unreachable = 5,
        biggestFactionInArea = 1, reachableCoordinates = {},
        safeSectors = { 1, 2 }, asteroids = 12, wrecks = 12, volume = 500,
    }
    return shipName, ctype, area, results, callingPlayer
end

local FAKE_COMMAND = {}

function FAKE_COMMAND:getAreaSize(ownerIndex, shipName)
    -- ★ 原版 Mine/Salvage 都是 15x15（minecommand.lua:494-496 / salvagecommand.lua:572-574 ✓）
    return { x = 15, y = 15 }
end

function FAKE_COMMAND:getConfigurableValues(ownerIndex, shipName)
    return {
        duration = { displayName = "Duration", from = 0.5, to = 2, default = 1 },
        safeMode = { displayName = "Safe Mode", default = false },
        immediateDelivery = { displayName = "Immediate Delivery", default = false },
    }
end

local function propertiesFor(self)
    local materials = {}
    for i = 1, N_MAT do
        local dps = 100
        if CAN_MINE[i] == false then dps = 0 end
        materials[i] = { dps = dps, refinedEfficiency = 1 }
    end
    return { materials = materials, refinedMining = true, refinedSalvaging = true, cargoSpace = 10000 }
end

function FAKE_COMMAND:getMiningProperties(ownerIndex, shipName) return propertiesFor(self) end
function FAKE_COMMAND:getSalvagingProperties(ownerIndex, shipName) return propertiesFor(self) end

function FAKE_COMMAND:calculatePrediction(ownerIndex, shipName, area, config)
    nPred = nPred + 1
    local key = (type(area.analysis) == "table") and area.analysis.probe or "?"
    local s = SPEC[key]
    if type(s) ~= "table" then
        return { attackChance = { value = 0 }, items = { from = 0, to = 0 }, yields = {},
                 error = "This operation won't yield anything!" }
    end

    local mode = config.safeMode and "safe" or "normal"
    local mult = s.perHour and config.duration or 1

    local yields = {}
    for i = 1, N_MAT do
        local base = 0
        if type(s.yields) == "table" and type(s.yields[mode]) == "table" then
            base = tonumber(s.yields[mode][i]) or 0
        end
        local to = base * mult
        yields[i] = { from = to * 0.8, to = to }
    end

    local chance = tonumber(s.chance) or 0
    if config.safeMode then chance = tonumber(s.safeChance) or 0 end
    if type(config.escorts) == "table" and #config.escorts > 0 then
        chance = tonumber(s.escortsChance) or chance
    end
    if s.perHourChance then chance = chance * config.duration end
    if ALL_RISKY then chance = 0.5 end

    local items = { from = 0, to = 0 }
    if type(s.items) == "table" and type(s.items[mode]) == "table" then
        items = { from = (tonumber(s.items[mode].from) or 0) * mult,
                  to = (tonumber(s.items[mode].to) or 0) * mult }
    end

    return { attackChance = { value = chance }, items = items, yields = yields }
end

function include(name)
    if name == "areaanalysis" then return nil end      -- 真的也返回 nil（它只定义全局 run ✓）
    if name == "commandfactory" then
        return { makeCommand = function(ctype) return FAKE_COMMAND end }
    end
    if name == "copilot/job" then return dofile("data/scripts/lib/copilot/job.lua") end
    if name == "goods" then return GOODS end
    error("unexpected include: " .. tostring(name))
end

function ShipDatabaseEntry(ownerIndex, name)
    return { getFreeCargoSpace = function() return 10000 end }
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

local function areaHasShip(a)
    return SHIP_X >= a.lower.x and SHIP_X <= a.upper.x
       and SHIP_Y >= a.lower.y and SHIP_Y <= a.upper.y
end

local function entryAt(resp, ox, oy)
    for _, e in ipairs(resp.areaRanking or {}) do
        if e.area.offset.x == ox and e.area.offset.y == oy then return e end
    end
    return nil
end

local function candOf(resp, tag)
    for _, c in ipairs(resp.candidates or {}) do
        if c.tag == tag then return c end
    end
    return nil
end

local function allInside(resp)
    for _, e in ipairs(resp.areaRanking or {}) do
        if not areaHasShip(e.area) then return false end
    end
    return true
end

local function gateOK(resp)
    for _, e in ipairs(resp.areaRanking or {}) do
        if e.acceptable and (e.attackChance or 0) > 0.10 then return false end
    end
    if resp.recommendation ~= nil and (resp.recommendation.attackChance or 0) > 0.10 then return false end
    return true
end

-- ===========================================================================
-- M1：口径与权重（costFactor 读不到 → 回退到原版**矿物商品价**阶梯 ✓）
-- ===========================================================================
print("== M1: 层级权重口径（原版矿价阶梯 goodsindex.lua ✓）==")
resetSpec()
SPEC["0,0"] = { materials = { [1] = 1 }, yields = { normal = { [1] = 1000 } }, chance = 0.02 }
CAN_MINE[7] = false          -- Avorion 采不动 → capability 必须如实报告 ✓
local okM1, rM1 = LinkIn.jobPlan(player, { ship = SHIP }, "Mine")
check("M1 ok=true", okM1 == true, rM1)
if okM1 ~= true then
    print("  致命：Mine jobPlan 失败，后续断言跳过")
else
    check("M1 weightSource = orePrice（因为 costFactor 读不到 ✓）", rM1.weightSource == "orePrice", rM1.weightSource)
    check("M1 scoreBasis 如实写明用了矿价口径",
        type(rM1.scoreBasis) == "string" and rM1.scoreBasis:find("矿物商品基准价", 1, true) ~= nil, rM1.scoreBasis)
    check("M1 权重 = 原版矿价阶梯 2/3/4/5/7/9/12",
        rM1.weights[1].weight == 2 and rM1.weights[5].weight == 7 and rM1.weights[7].weight == 12,
        rM1.weights[1].weight .. "," .. rM1.weights[5].weight .. "," .. rM1.weights[7].weight)
    check("M1 权重表里也带上了原版矿价（能审计 ✓）",
        rM1.weights[6].orePrice == 9, rM1.weights[6].orePrice)
    check("M1 区域尺寸 = 15x15（来自 getAreaSize，不是编的 ✓）",
        rM1.size == 15 and rM1.scan.size == 15, tostring(rM1.size))
    check("M1 legalSizes 里有 15x15", (function()
        for _, t in ipairs(rM1.scan.legalSizes or {}) do if t.x == 15 and t.y == 15 then return true end end
        return false
    end)())
    check("M1 areasScanned=9", rM1.areasScanned == 9, rM1.areasScanned)
    check("M1 每个候选区域都含船", allInside(rM1))
    check("M1 未知/低风险都过闸门，且没有任何推荐超过 10%", gateOK(rM1))
    check("M1 capability 如实报告这艘船采不动 Avorion（dps=0 ✓）",
        rM1.capability ~= nil and rM1.capability.materials[7].canMine == false
        and rM1.capability.materials[7].dps == 0,
        rM1.capability and tostring(rM1.capability.materials[7].dps))
    check("M1 capability 说明来自原版 getMiningProperties",
        rM1.capability ~= nil and rM1.capability.source == "MineCommand:getMiningProperties",
        rM1.capability and rM1.capability.source)
    local okEnc, txt = pcall(JSON.encode, rM1)
    check("M1 响应可 JSON 编码并往返", okEnc and type(JSON.decode(txt)) == "table", okEnc and #tostring(txt) or txt)
    print(string.format("  [成本] run()=%d 次；calculatePrediction()=%d 次；响应 JSON=%d 字节", nRun, nPred, okEnc and #txt or -1))
end

-- ===========================================================================
-- M2：层级加权 —— ★ 高阶矿区必须压过**吨位更大**的低阶矿区 ✓✓
--     显式给层级权重 {1..7}，纸上数字：
--       低阶区 (0,0) ：Iron 9000 → 9000 × 1 = **9000**
--       高阶区 (4,4) ：Ogonite 2000 → 2000 × 6 = **12000**  ← 吨位只有 2/9，但层级高 → 赢 ✓
-- ===========================================================================
print("== M2: 高阶矿压过低阶大吨位（层级加权，不是吨位）==")
resetSpec()
COST_FACTOR = nil
SPEC["0,0"] = { materials = { [1] = 1 }, yields = { normal = { [1] = 9000 } }, chance = 0.02 }
SPEC["4,4"] = { materials = { [6] = 1 }, yields = { normal = { [6] = 2000 } }, chance = 0.02 }
local okM2, rM2 = LinkIn.jobPlan(player, { ship = SHIP, tierWeights = { 1, 2, 3, 4, 5, 6, 7 } }, "Mine")
check("M2 ok=true", okM2 == true, rM2)
if okM2 == true then
    check("M2 weightSource = explicit", rM2.weightSource == "explicit", rM2.weightSource)
    local eIron, eOgo = entryAt(rM2, 0, 0), entryAt(rM2, 4, 4)
    check("M2 低阶区价值 = 9000（Iron 9000 × 1 ✓）",
        eIron ~= nil and eIron.valueHigh == 9000, eIron and eIron.valueHigh)
    check("M2 高阶区价值 = 12000（Ogonite 2000 × 6 ✓）",
        eOgo ~= nil and eOgo.valueHigh == 12000, eOgo and eOgo.valueHigh)
    check("M2 低阶区的最高矿层级 = 1", eIron ~= nil and eIron.topTier == 1, eIron and eIron.topTier)
    check("M2 高阶区的最高矿层级 = 6", eOgo ~= nil and eOgo.topTier == 6, eOgo and eOgo.topTier)
    check("M2 区域榜里高阶区排在低阶区**前面** ✓",
        eIron ~= nil and eOgo ~= nil and eOgo.valueHigh > eIron.valueHigh)
    check("M2 recommendation 选的是高阶矿区（Ogonite）✓",
        rM2.recommendation ~= nil and rM2.recommendation.topMaterial == "Ogonite",
        rM2.recommendation and rM2.recommendation.topMaterial)
    check("M2 recommendation 价值 = 12000~15000（保守 9600 = 1600×6 ✓）",
        rM2.recommendation ~= nil and rM2.recommendation.valueHigh == 12000
        and rM2.recommendation.valueLow == 9600,
        rM2.recommendation and (tostring(rM2.recommendation.valueLow) .. "/" .. tostring(rM2.recommendation.valueHigh)))
    check("M2 逐材料明细里 Ogonite 权重 6、产量 2000 ✓",
        (function()
            local c = candOf(rM2, "default")
            if c == nil or type(c.materials) ~= "table" then return false end
            for _, m in ipairs(c.materials) do
                if m.index == 6 then return m.weight == 6 and m.to == 2000 end
            end
            return false
        end)())
end

-- ===========================================================================
-- M3：风险闸门 —— 一个档位都过不了 → recommendation = nil + 明说 ✓
-- ===========================================================================
print("== M3: 全部超风险 → 明说不推荐（绝不偷偷挑）==")
resetSpec()
SPEC["0,0"] = { materials = { [1] = 1 }, yields = { normal = { [1] = 9000 } }, chance = 0.02 }
ALL_RISKY = true
local okM3, rM3 = LinkIn.jobPlan(player, { ship = SHIP }, "Mine")
ALL_RISKY = false
check("M3 ok=true（扫描本身成功 ✓）", okM3 == true, rM3)
if okM3 == true then
    check("M3 recommendation = nil", rM3.recommendation == nil, rM3.recommendation)
    check("M3 riskWarning 明说了'不推荐'",
        type(rM3.riskWarning) == "string" and rM3.riskWarning:find("不推荐", 1, true) ~= nil, rM3.riskWarning)
    check("M3 note 里也明说了", type(rM3.note) == "string"
        and rM3.note:find("不推荐", 1, true) ~= nil, rM3.note)
    local nAcc = 0
    for _, e in ipairs(rM3.areaRanking) do if e.acceptable then nAcc = nAcc + 1 end end
    check("M3 区域榜里没有达标项", nAcc == 0, nAcc)
    check("M3 仍然把不达标区域列出来（可见理由 ✓）", #rM3.areaRanking > 0, #rM3.areaRanking)
    check("M3 超闸门的区域标了 attackChance=0.5（不是被抹掉 ✓）",
        entryAt(rM3, 0, 0) ~= nil and entryAt(rM3, 0, 0).attackChance == 0.5,
        entryAt(rM3, 0, 0) and entryAt(rM3, 0, 0).attackChance)
end

-- ===========================================================================
-- M4：参数维度 —— safeMode 救援（★ 原版把伏击概率 ×0.1 ✓）
--     默认档 50% 超闸门；安全模式档 2% ✓ → 推荐必须带回 safeMode=true ✓
-- ===========================================================================
print("== M4: safeMode 救援（原版 attackChanceModification ✓）==")
resetSpec()
SPEC["0,0"] = {
    materials = { [1] = 1 },
    yields = { normal = { [1] = 1000 }, safe = { [1] = 500 } },
    chance = 0.5, safeChance = 0.02,
}
local okM4, rM4 = LinkIn.jobPlan(player, { ship = SHIP }, "Mine")
check("M4 ok=true", okM4 == true, rM4)
if okM4 == true then
    check("M4 推荐档 = safeMode", rM4.recommendation ~= nil and rM4.recommendation.tag == "safeMode",
        rM4.recommendation and rM4.recommendation.tag)
    check("M4 推荐风险 = 0.02（≤ 0.10 ✓）",
        rM4.recommendation ~= nil and rM4.recommendation.attackChance == 0.02,
        rM4.recommendation and rM4.recommendation.attackChance)
    check("M4 推荐价值 = 1000（安全模式产量减半：500 × 2 ✓）",
        rM4.recommendation ~= nil and rM4.recommendation.valueHigh == 1000,
        rM4.recommendation and rM4.recommendation.valueHigh)
    check("M4 orderHint 里真的带上了 safeMode=true ✓",
        rM4.orderHint ~= nil and rM4.orderHint.safeMode == true, rM4.orderHint and tostring(rM4.orderHint.safeMode))
    check("M4 默认档仍在候选里且标为超闸门 ✓",
        (function()
            local c = candOf(rM4, "default")
            return c ~= nil and c.acceptable == false and c.attackChance == 0.5
        end)())
    check("M4 救援档确实被补算过（parameterTags 里有 safeMode ✓）",
        (function()
            for _, t in ipairs(rM4.scan.parameterTags or {}) do if t == "safeMode" then return true end end
            return false
        end)())
end

-- ===========================================================================
-- M4b：参数维度 —— 护航救援（同星系护航：降风险，且护航自己出产量 ✓）
-- ===========================================================================
print("== M4b: 护航救援（降风险 + 护航产出 ✓）==")
resetSpec()
SPEC["0,0"] = {
    materials = { [1] = 1 },
    yields = { normal = { [1] = 1000 }, safe = { [1] = 500 } },
    chance = 0.5, safeChance = 0.02, escortsChance = 0.03,
}
local okM4b, rM4b = LinkIn.jobPlan(player, { ship = SHIP, escorts = { "Combat-00001" } }, "Mine")
check("M4b ok=true", okM4b == true, rM4b)
if okM4b == true then
    check("M4b 推荐档 = escorts（0.03 过闸门且价值更高 ✓）",
        rM4b.recommendation ~= nil and rM4b.recommendation.tag == "escorts",
        rM4b.recommendation and rM4b.recommendation.tag)
    check("M4b 推荐带上了护航名",
        rM4b.recommendation ~= nil and rM4b.recommendation.escorts[1] == "Combat-00001",
        rM4b.recommendation and tostring(rM4b.recommendation.escorts[1]))
    check("M4b orderHint.escorts 也是它",
        rM4b.orderHint ~= nil and rM4b.orderHint.escorts[1] == "Combat-00001",
        rM4b.orderHint and tostring(rM4b.orderHint.escorts[1]))
    check("M4b 仍然没有任何超闸门的推荐", gateOK(rM4b))
end

-- ===========================================================================
-- M5：非法尺寸 29 → 必须换回原版合法尺寸 15 ✓
-- ===========================================================================
print("== M5: 非法尺寸 29 → 换回合法 15 ==")
resetSpec()
SPEC["0,0"] = { materials = { [1] = 1 }, yields = { normal = { [1] = 1000 } }, chance = 0.02 }
local okM5, rM5 = LinkIn.jobPlan(player, { ship = SHIP, size = 29 }, "Mine")
check("M5 ok=true", okM5 == true, rM5)
if okM5 == true then
    check("M5 实际尺寸 = 15", rM5.scan.size == 15, rM5.scan.size)
    check("M5 note 说明了尺寸被换掉", type(rM5.note) == "string"
        and rM5.note:find("不是 Mine 的合法区域尺寸", 1, true) ~= nil, rM5.note)
    check("M5 换尺寸后每个区域仍含船", allInside(rM5))
end

-- ===========================================================================
-- M6：中心离船太远（0,0）→ 退回船的星区 ✓，且**每个区域都含船** ✓
-- ===========================================================================
print("== M6: 中心离船太远 → 退回船所在星区 ==")
resetSpec()
SPEC["0,0"] = { materials = { [1] = 1 }, yields = { normal = { [1] = 1000 } }, chance = 0.02 }
local okM6, rM6 = LinkIn.jobPlan(player, { ship = SHIP, x = 0, y = 0 }, "Mine")
check("M6 ok=true", okM6 == true, rM6)
if okM6 == true then
    check("M6 用了船的星区当中心", rM6.scan.usedShipCentre == true, rM6.scan.usedShipCentre)
    check("M6 跳过了若干含不住船的区域", (rM6.scan.droppedNoShip or 0) > 0, rM6.scan.droppedNoShip)
    check("M6 最终每个区域都含船", allInside(rM6))
    check("M6 note 说明了退回", type(rM6.note) == "string"
        and rM6.note:find("改以船所在星区", 1, true) ~= nil, rM6.note)
end

-- ===========================================================================
-- M7：参数维度 —— duration（产量随时长涨 ✓，风险也随时长涨 → 闸门说了算 ✓）
--     纸上数字：Iron 3000/小时，权重 2（矿价口径）→ 时长 1 = 6000；时长 2 = 12000 ✓
--     风险 2%/小时 → 时长 1 = 0.02；时长 2 = 0.04（都 ≤ 0.10 ✓）→ 取最长的 ✓
-- ===========================================================================
print("== M7: duration 维度（取产量最高的合法档 ✓）==")
resetSpec()
SPEC["0,0"] = {
    materials = { [1] = 1 },
    yields = { normal = { [1] = 3000 } },     -- 每小时 3000
    chance = 0.02, perHour = true, perHourChance = true,
}
local okM7, rM7 = LinkIn.jobPlan(player, { ship = SHIP }, "Mine")
check("M7 ok=true", okM7 == true, rM7)
if okM7 == true then
    check("M7 duration 区间来自原版 getConfigurableValues（0.5~2 ✓）",
        rM7.durationChoices ~= nil and rM7.durationChoices.from == 0.5 and rM7.durationChoices.to == 2,
        rM7.durationChoices and (tostring(rM7.durationChoices.from) .. "~" .. tostring(rM7.durationChoices.to)))
    check("M7 推荐档 = longest（时长 2 小时，产量翻倍 ✓）",
        rM7.recommendation ~= nil and rM7.recommendation.tag == "longest",
        rM7.recommendation and rM7.recommendation.tag)
    check("M7 推荐价值 = 12000（3000 × 2 小时 × 权重 2 ✓）",
        rM7.recommendation ~= nil and rM7.recommendation.valueHigh == 12000,
        rM7.recommendation and rM7.recommendation.valueHigh)
    check("M7 推荐风险 = 0.04（2%/小时 × 2 ✓，仍 ≤ 0.10 ✓）",
        rM7.recommendation ~= nil and math.abs(rM7.recommendation.attackChance - 0.04) < 1e-9,
        rM7.recommendation and rM7.recommendation.attackChance)
    check("M7 orderHint.duration = 2（可直接喂给 order ✓）",
        rM7.orderHint ~= nil and rM7.orderHint.duration == 2, rM7.orderHint and rM7.orderHint.duration)
end

-- ===========================================================================
-- S1：Salvage —— 装备件数 × E[稀有度层级]（1.23 ✓）
--     纸上数字：(0,0) items 100 件 × 1.23 = **123**；(4,4) items 64 件 × 1.23 = **78.72** ✓
--     ★ 注意 (4,4) 的残骸场层级更高（fieldTier 4 > 1），但件数少 → **仍然输** ✓✓
--       —— 说明 fieldTier 确实只是**次级键**，符合"战利品是主角" ✓
-- ===========================================================================
print("== S1: Salvage 装备件数驱动（fieldTier 只当次级键）==")
resetSpec()
SPEC["0,0"] = { materials = { [1] = 1 }, items = { normal = { from = 75, to = 100 } }, chance = 0.02 }
SPEC["4,4"] = { materials = { [4] = 1 }, items = { normal = { from = 48, to = 64 } }, chance = 0.02 }
local okS1, rS1 = LinkIn.jobPlan(player, { ship = SHIP }, "Salvage")
check("S1 ok=true", okS1 == true, rS1)
if okS1 == true then
    check("S1 rarity.expectedTier = 1.23（原版五档混合表 ✓）",
        rS1.rarity ~= nil and math.abs(rS1.rarity.expectedTier - 1.23) < 1e-9,
        rS1.rarity and rS1.rarity.expectedTier)
    check("S1 rarity.mix 五档、概率和 = 1",
        (function()
            if rS1.rarity == nil or #rS1.rarity.mix ~= 5 then return false end
            local s = 0
            for _, m in ipairs(rS1.rarity.mix) do s = s + m.chance end
            return math.abs(s - 1) < 1e-9
        end)())
    check("S1 rarity 说明了这张表**与区域无关**（常数 ✗）",
        rS1.rarity ~= nil and type(rS1.rarity.note) == "string"
        and rS1.rarity.note:find("与区域无关", 1, true) ~= nil, rS1.rarity and rS1.rarity.note)
    check("S1 scoreBasis 以'装备件数'开口径", type(rS1.scoreBasis) == "string"
        and rS1.scoreBasis:find("装备件数", 1, true) ~= nil, rS1.scoreBasis)
    check("S1 scoreBasis 明说废铁只作审计", type(rS1.scoreBasis) == "string"
        and rS1.scoreBasis:find("只作审计", 1, true) ~= nil, rS1.scoreBasis)
    local eA, eB = entryAt(rS1, 0, 0), entryAt(rS1, 4, 4)
    check("S1 (0,0) 价值 = 123（100 件 × 1.23 ✓）", eA ~= nil and math.abs(eA.valueHigh - 123) < 1e-6,
        eA and eA.valueHigh)
    check("S1 (4,4) 价值 = 78.72（64 件 × 1.23 ✓）", eB ~= nil and math.abs(eB.valueHigh - 78.72) < 1e-6,
        eB and eB.valueHigh)
    check("S1 (4,4) 的残骸场层级更高（fieldTier=4 > 1 ✓）",
        eA ~= nil and eB ~= nil and eA.fieldTier == 1 and eB.fieldTier == 4,
        tostring(eA and eA.fieldTier) .. " vs " .. tostring(eB and eB.fieldTier))
    check("S1 但件数多的 (0,0) 仍然赢（fieldTier 只是次级键 ✓）",
        rS1.recommendation ~= nil and rS1.recommendation.area.offset.x == 0
        and rS1.recommendation.area.offset.y == 0,
        rS1.recommendation and tostring(rS1.recommendation.area.offset.x))
    check("S1 推荐里装备件数 = 100 件 ✓",
        rS1.recommendation ~= nil and rS1.recommendation.items ~= nil
        and rS1.recommendation.items.to == 100,
        rS1.recommendation and tostring(rS1.recommendation.items and rS1.recommendation.items.to))
    check("S1 orderHint.action = Salvage", rS1.orderHint ~= nil and rS1.orderHint.action == "Salvage",
        rS1.orderHint and rS1.orderHint.action)
    check("S1 每个候选区域都含船", allInside(rS1))
    check("S1 没有任何超过 10% 的推荐", gateOK(rS1))
    local okEnc, txt = pcall(JSON.encode, rS1)
    check("S1 响应可 JSON 编解码", okEnc and type(JSON.decode(txt)) == "table", okEnc and #tostring(txt) or txt)
end

-- ===========================================================================
-- S1b：Salvage 次级键 —— **同件数**时，残骸场层级更高的区域胜出 ✓
-- ===========================================================================
print("== S1b: Salvage 同件数 → 残骸场层级高者胜（次级键 ✓）==")
resetSpec()
SPEC["0,0"] = { materials = { [1] = 1 }, items = { normal = { from = 60, to = 80 } }, chance = 0.02 }
SPEC["4,4"] = { materials = { [4] = 1 }, items = { normal = { from = 60, to = 80 } }, chance = 0.02 }
local okS1b, rS1b = LinkIn.jobPlan(player, { ship = SHIP }, "Salvage")
check("S1b ok=true", okS1b == true, rS1b)
if okS1b == true then
    check("S1b 推荐落在残骸场层级更高的 (4,4) ✓",
        rS1b.recommendation ~= nil and rS1b.recommendation.area.offset.x == 4
        and rS1b.recommendation.area.offset.y == 4,
        rS1b.recommendation and (tostring(rS1b.recommendation.area.offset.x) .. "," .. tostring(rS1b.recommendation.area.offset.y)))
    check("S1b 推荐的 fieldTier = 4",
        rS1b.recommendation ~= nil and rS1b.recommendation.fieldTier == 4,
        rS1b.recommendation and rS1b.recommendation.fieldTier)
end

-- ===========================================================================
-- 收尾：orderHint 必须能**原样喂给 order** ✓（onOrder 认的字段：ship/action/x/y/size/duration/safeMode/escorts ✓）
-- ===========================================================================
print("== X: orderHint 形状 ==")
resetSpec()
SPEC["0,0"] = { materials = { [1] = 1 }, yields = { normal = { [1] = 1000 } }, chance = 0.02 }
local okX, rX = LinkIn.jobPlan(player, { ship = SHIP }, "Mine")
if okX == true then
    local h = rX.orderHint
    check("X orderHint 字段齐全（ship/action/x/y/size/duration/safeMode/escorts ✓）",
        h ~= nil and h.ship == SHIP and h.action == "Mine"
        and type(h.x) == "number" and type(h.y) == "number" and h.size == 15
        and type(h.duration) == "number" and type(h.safeMode) == "boolean"
        and type(h.escorts) == "table",
        h and JSON.encode(h))
    check("X orderHint 的 x/y 落在推荐区域内 ✓",
        rX.recommendation ~= nil and areaHasShip(rX.recommendation.area),
        rX.recommendation and JSON.encode(rX.recommendation.area))
    check("X orderHint.x == 船星区 + 区域偏移 ✓",
        rX.recommendation ~= nil
        and h.x == SHIP_X + rX.recommendation.area.offset.x
        and h.y == SHIP_Y + rX.recommendation.area.offset.y,
        tostring(h.x) .. "," .. tostring(h.y))
end

print(string.format("== 共 %d 项断言，失败 %d 项 ==", checks, failures))
if failures == 0 then
    print("jobScanSelfTest: OK")
else
    print("jobScanSelfTest: FAIL")
end
