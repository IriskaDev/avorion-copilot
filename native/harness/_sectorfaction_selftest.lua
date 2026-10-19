-- _sectorfaction_selftest.lua —— sectorFacts 的「星区归属/友好度」断言 ✓（2026-10-17 加）
--
-- 不开游戏就能验：把 Galaxy() / RelationStatus / player:getRelationStatus 换成替身 ✓，
-- 然后**真的调** data/scripts/net/link_in.lua 里的 onQuery {what="sectorFacts"} ✓✓。
--
-- 断言点（对应主人的规格 ✓）：
--   · `factionIndex` / `factionName` / `hasFaction` / `relation` / `isFriendly` / `hasStations`
--     都按**原版 relation 语义**落位 ✓（不自己造阈值 ✗）：
--       - Allies → isFriendly=true, relation="friendly"   （友好星区 ✓）
--       - Neutral → isFriendly=false, relation="neutral"   （中立 ✗ 不派）
--       - War → isFriendly=false, relation="hostile"       （敌对 ✗ 不派）
--       - 无阵营 → isFriendly=false, relation="unowned"     （无人区/海盗 ✗ 不派）
--   · `hasStations` 来自 Galaxy():getSectorView().numStations > 0 ✓
--   · caps 自声明带出 sectorFactsParams ✓
--
-- ★ 夹具坐标 = 本会话**实测**的两个星区 ✓：
--     (-381, 57) = 商船 Trader-00001 当前所在（live 实测 17x17 有 4 条贸易路线 → 有派系/有站 ✓）
--     (-373, 60) = 战斗舰 Combat-00001 所在 ✓
--   其余 (-0,0)/(5,5) 是「无人区 / 敌对」的对照夹具 ✓。
--   ⚠️ 替身里的 relation 是**离线模型** ✗ —— 真机 relation（Allies/Neutral 到底哪个）
--     要在**重启游戏后**用 fleet_query {what:"sectorFacts"} 实测核对 ✓（见回报 ✓）。
--
-- 跑法：  build\harness\lua.exe native\harness\_sectorfaction_selftest.lua

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

-- ---------------------------------------------------------------------------
-- 游戏 API 的替身
-- ---------------------------------------------------------------------------

CopilotRpc = { trace = function() end }

ShipAvailability = { Available = 0, InBackground = 1 }
function valid(v) return v ~= nil end
function Balancing_GetSectorRichnessFactor(x, y) return 1.0 end
function Balancing_GetMaterialProbability(x, y) return {} end
function Balancing_InsideRing(x, y) return false end
function NumMaterials() return 7 end

-- ★ RelationStatus（原版枚举 ✓ —— 与 relations.lua / 三处后台命令同一套 ✓）
RelationStatus = { War = -2, Ceasefire = -1, Neutral = 0, Allies = 1 }

-- ★ 夹具：哪个星区归谁、玩家与它的关系、站数（替身模型 ✓ —— 真机 relation 待重启核对 ✓）
local FACTIONS = {
    ["-381,57"] = { index = 2000042, name = "Friendly Trading Guild", isPlayer = false },
    ["-373,60"] = { index = 2000055, name = "Neutral Mining Syndicate", isPlayer = false },
    ["5,5"]     = { index = 2000077, name = "Hostile Raiders", isPlayer = false },
}
local RELATION = {
    [2000042] = RelationStatus.Allies,
    [2000055] = RelationStatus.Neutral,
    [2000077] = RelationStatus.War,
}
local STATIONS = { ["-381,57"] = 2, ["-373,60"] = 0, ["0,0"] = 0, ["5,5"] = 1 }

-- (0,0) 无人：getControllingFaction 与 getLocalFaction 都返回 nil ✓
local galaxy = {}
function galaxy:getControllingFaction(x, y)
    if x == 0 and y == 0 then return nil end
    return FACTIONS[x .. "," .. y]
end
function galaxy:getLocalFaction(x, y)
    if x == 0 and y == 0 then return nil end
    return FACTIONS[x .. "," .. y]
end
function galaxy:getSectorView(x, y)
    return { numStations = STATIONS[x .. "," .. y] or 0 }
end
function Galaxy() return galaxy end

local player = {
    index = 1,
    craft = nil,
    getRelationStatus = function(self, fi) return RELATION[fi] or RelationStatus.Neutral end,
    getShipPosition = function(self, name) return -381, 57 end,
    getKnownSector = function(self, x, y) return {} end,
    getValue = function(self, key) return "" end,
    getShipAvailability = function(self, name) return ShipAvailability.Available end,
    invokeFunction = function() return true end,
}
function Player() return player end

function include(name)
    if name == "areaanalysis" then return nil end
    if name == "commandfactory" then return { makeCommand = function() return {} end } end
    if name == "copilot/card" then return dofile("data/scripts/lib/copilot/card.lua") end
    if name == "captainutility" then return { ClassType = {} } end
    error("unexpected include: " .. tostring(name))
end
function ShipDatabaseEntry(ownerIndex, name)
    return {
        getFreeCargoSpace = function() return 0 end,
        getCaptain = function() return nil end,
        getCargo = function() return {}, 100 end,
        getTurrets = function() return {} end,
        getHyperspaceProperties = function() return 12, true end,
    }
end

local LinkIn = dofile("data/scripts/net/link_in.lua")

-- ---------------------------------------------------------------------------
-- ① 友好星区 (-381,57)：isFriendly=true / relation="friendly" / hasStations=true
-- ---------------------------------------------------------------------------
print("== ① 友好星区 (-381,57)：原版 relation = Allies ==")
local okF, rF = LinkIn.onQuery({ what = "sectorFacts", x = -381, y = 57 })
check("① sectorFacts ok=true", okF == true, rF)
if okF == true then
    local s = rF.sector
    check("① factionIndex = 2000042", s.factionIndex == 2000042, s.factionIndex)
    check("① hasFaction = true", s.hasFaction == true, tostring(s.hasFaction))
    check("① factionName 在", s.factionName == "Friendly Trading Guild", s.factionName)
    check("① relation = friendly", s.relation == "friendly", s.relation)
    check("① isFriendly = true（原版 Allies ✓）", s.isFriendly == true, tostring(s.isFriendly))
    check("① hasStations = true（numStations=2 ✓）", s.hasStations == true, tostring(s.hasStations))
    check("① stationCount = 2", s.stationCount == 2, s.stationCount)
    check("① 朝中心取样也带阵营字段（第 1 个取样点 ✓）", rF.towardCentre[1].relation ~= nil and rF.towardCentre[1].isFriendly ~= nil, "")
end

-- ---------------------------------------------------------------------------
-- ② 中立星区 (-373,60)：isFriendly=false / relation="neutral"
-- ---------------------------------------------------------------------------
print("== ② 中立星区 (-373,60)：原版 relation = Neutral ==")
local okN, rN = LinkIn.onQuery({ what = "sectorFacts", x = -373, y = 60 })
check("② sectorFacts ok=true", okN == true, rN)
if okN == true then
    check("② relation = neutral", rN.sector.relation == "neutral", rN.sector.relation)
    check("② isFriendly = false（中立 ✗ 不派）", rN.sector.isFriendly == false, tostring(rN.sector.isFriendly))
    check("② hasStations = false（numStations=0 ✓）", rN.sector.hasStations == false, tostring(rN.sector.hasStations))
end

-- ---------------------------------------------------------------------------
-- ③ 无人区 (0,0)：isFriendly=false / relation="unowned" / hasFaction=false
-- ---------------------------------------------------------------------------
print("== ③ 无人区 (0,0)：无 controlling/local faction ==")
local okU, rU = LinkIn.onQuery({ what = "sectorFacts", x = 0, y = 0 })
check("③ sectorFacts ok=true", okU == true, rU)
if okU == true then
    check("③ factionIndex = 0（无人区 ✓）", rU.sector.factionIndex == 0, rU.sector.factionIndex)
    check("③ hasFaction = false", rU.sector.hasFaction == false, tostring(rU.sector.hasFaction))
    check("③ relation = unowned", rU.sector.relation == "unowned", rU.sector.relation)
    check("③ isFriendly = false（无人/海盗 ✗ 不派）", rU.sector.isFriendly == false, tostring(rU.sector.isFriendly))
    check("③ hasStations = false", rU.sector.hasStations == false, tostring(rU.sector.hasStations))
end

-- ---------------------------------------------------------------------------
-- ④ 敌对星区 (5,5)：isFriendly=false / relation="hostile"
-- ---------------------------------------------------------------------------
print("== ④ 敌对星区 (5,5)：原版 relation = War ==")
local okH, rH = LinkIn.onQuery({ what = "sectorFacts", x = 5, y = 5 })
check("④ sectorFacts ok=true", okH == true, rH)
if okH == true then
    check("④ relation = hostile", rH.sector.relation == "hostile", rH.sector.relation)
    check("④ isFriendly = false（敌对 ✗ 不派）", rH.sector.isFriendly == false, tostring(rH.sector.isFriendly))
end

-- ---------------------------------------------------------------------------
-- ⑤ caps 自声明带出 sectorFactsParams ✓
-- ---------------------------------------------------------------------------
print("== ⑤ caps 自声明 ==")
local okC, rC = LinkIn.onQuery({ what = "caps" })
check("⑤ caps ok=true", okC == true, rC)
if okC == true then
    check("⑤ caps 带 sectorFactsParams", type(rC.sectorFactsParams) == "table", tostring(rC.sectorFactsParams))
    check("⑤ caps 仍带 predictParams/tradeRoutesParams（不退化 ✗）",
        type(rC.predictParams) == "table" and type(rC.tradeRoutesParams) == "table", "")
end

-- ---------------------------------------------------------------------------
-- ⑥ 体积量级（含 4 个星区事实 + 阵营字段 ✓）
-- ---------------------------------------------------------------------------
print("== ⑥ 体积量级（JSON 字节）==")
do
    local JSON = dofile("data/scripts/lib/copilot/json.lua")
    local function bytesOf(t)
        local ok, txt = pcall(JSON.encode, t)
        return (ok and #txt) or -1
    end
    local _, r = LinkIn.onQuery({ what = "sectorFacts", x = -381, y = 57 })
    print(string.format("  [体积] sectorFacts(含阵营) = %d B", bytesOf(r)))
    check("⑥ sectorFacts 体积 < 8 KB（毫秒级、不出 MB ✓）", bytesOf(r) < 8192, bytesOf(r))
end

-- ---------------------------------------------------------------------------
print(string.format("== 共 %d 项断言，失败 %d 项 ==", checks, failures))
if failures == 0 then
    print("sectorFactionSelfTest: OK")
else
    print("sectorFactionSelfTest: FAIL")
end
