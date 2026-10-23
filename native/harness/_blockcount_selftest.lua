-- _blockcount_selftest.lua —— 「方块数」字段的**回归断言**（2026-10-24 加）
--
-- 主人原话：
--   「我说的多，是指方块多，你可以查下 scout 对比我的其它船，方块数量如何」
--
-- 主人否掉旧路子的地方（本文件就是把新路子钉死 ✓）：
--   · `shipQuote` / `blockQuote` 有 blockCount ✓，但**要求船在本星区** ✗
--     （cli.lua:355-376 mountsResolveShip 要实体才能 getBlock / setMovePlan ✓）
--     → 只为读一个数字就把船调回来，荒唐 ✗。
--   · `ShipDatabaseEntry` 的 **numBlocks / numBlocksWhileMalusActive** 是**船档案属性** ✓
--     （ShipDatabaseEntry [Server].html:271-281，两个都 [read-only] ✓；文档**没有** getter ✗）
--     → **远距离也能读** ✓✓，这才是横向比较该用的 ✓。
--
-- 本文件断言的口径：
--   ① 远距离（没有实体、也不在本星区）的船：card.numBlocks 读得到 ✓ 且 known=true ✓
--   ② full 与 brief **同源**：numBlocks / numBlocksKnown 逐字一致 ✓（两套逻辑 = 早晚各错一遍 ✗）
--   ③ 读不到 → 值是 **nil**、known=false、probe 里有原因 —— **绝不填 0** ✗✓
--   ④ 真值 0 → 照样 0 + known=true ✓（0 是合法值，不许被当成"缺数据"吞掉 ✗）
--   ⑤ 非数字（字符串）→ 也当读不到 ✓（不硬转、不猜 ✗）
--   ⑥ 只读**属性**、绝不调不存在的 `getNumBlocks()` ✓
--      （文档里没有这个方法 ✗ —— 读了就是"读文档里没有的属性"那类事故 ✓）
--   ⑦ numBlocksWhileMalusActive 同组同规矩 ✓（原样值；文档没写语义 → 不解释 ✓）
--
-- 跑法（在仓库根执行）：
--   build\harness\lua.exe native\harness\_blockcount_selftest.lua

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

local function makeFormat(text)
    local f = { text = text }
    f.translated = function(self) return text end
    return f
end

EntityType = { None = 0, Ship = 1, Drone = 2, Station = 3 }

-- ★ 船替身：全部**不在本星区**（player.craft = nil，且 ShipDatabaseEntry 不是实体 ✓）
local SHIPS = {
    -- ① 普通远距离船：1234 块
    ["Scout-00001"] = { numBlocks = 1234, malus = 900, title = "" },
    -- ② 大船：用来模拟"倍数"比较 ✓
    ["Miner-00001"] = { numBlocks = 4000, malus = 4000, title = "Mine" },
    -- ③ 读不到 numBlocks（引擎抛错）+ 连 malus 也没有 → 两个都必须是 nil，不能是 0
    ["Blind-00001"] = { blocksThrow = true, title = "" },
    -- ④ 真值 0（合法值）→ 必须原样是 0 + known=true
    ["Empty-00001"] = { numBlocks = 0, malus = 0, title = "" },
    -- ⑤ 返回非数字串（异常形状）→ 当读不到 ✓
    ["Weird-00001"] = { numBlocks = "abc", malus = false, title = "" },
}

function include(name)
    if name == "copilot/card" then return dofile("data/scripts/lib/copilot/card.lua") end
    if name == "captainutility" then return { ClassType = { None = 0, Merchant = 3 } } end
    if name == "areaanalysis" then return nil end
    if name == "commandfactory" then return { makeCommand = function() return {} end } end
    if name == "copilot/trade" then return dofile("data/scripts/lib/copilot/trade.lua") end
    if name == "copilot/job" then return dofile("data/scripts/lib/copilot/job.lua") end
    if name == "goods" then return {} end
    error("unexpected include: " .. tostring(name))
end

local getterCalls = 0

local function makeEntry(name)
    local spec = SHIPS[name]
    if spec == nil then return nil end
    local entry = {
        getFreeCargoSpace = function() return 3006 end,
        getCaptain = function() return nil end,
        getCargo = function() return {}, 3006 end,
        getTurrets = function() return {} end,
        getHyperspaceProperties = function() return 4.1, false end,
        getEntityType = function() return EntityType.Ship end,
        getTitle = function() return makeFormat(spec.title or "") end,
        -- ★ 文档里**没有** getNumBlocks() ✗ —— 真被调用就说明代码去读了不存在的方法 ✓
        getNumBlocks = function()
            getterCalls = getterCalls + 1
            error("ShipDatabaseEntry:getNumBlocks() does not exist in the docs")
        end,
    }
    if spec.blocksThrow then
        -- 属性读会抛错（模拟"读不到"）
        setmetatable(entry, {
            __index = function(_, k)
                if k == "numBlocks" then error("numBlocks is not readable") end
                return nil
            end,
        })
    elseif spec.numBlocks ~= nil then
        entry.numBlocks = spec.numBlocks
    end
    if spec.malus ~= nil then entry.numBlocksWhileMalusActive = spec.malus end
    return entry
end

function ShipDatabaseEntry(ownerIndex, name) return makeEntry(name) end

ShipAvailability = { Available = 0, InBackground = 1 }
function valid(v) return v ~= nil end
function Balancing_GetSectorRichnessFactor(x, y) return 1.0 end
function Balancing_GetMaterialProbability(x, y) return {} end
function Balancing_InsideRing(x, y) return false end
function NumMaterials() return 7 end

local player = {
    index = 1,
    craft = nil,
    getShipPosition = function(self, name) return -373, 60 end,
    getValue = function(self, key) return "" end,
    getShipAvailability = function(self, name) return ShipAvailability.Available end,
    invokeFunction = function(self, path, fn, ...) return true end,
}
function Player() return player end

local Card = include("copilot/card")

-- ---------------------------------------------------------------------------
-- 断言
-- ---------------------------------------------------------------------------

-- 这是一组「值 + 是否已知」的成对字段（两个读数各一对 ✓）
local BLOCK_FIELDS = {
    "numBlocks", "numBlocksKnown", "numBlocksSource", "numBlocksNote",
    "numBlocksWhileMalusActive", "numBlocksWhileMalusActiveKnown", "numBlocksWhileMalusActiveSource",
}

local function sameFields(card, brief, label)
    for _, f in ipairs(BLOCK_FIELDS) do
        if card[f] ~= brief[f] then
            return false, string.format("%s: %s  card=%s brief=%s", label, f,
                tostring(card[f]), tostring(brief[f]))
        end
    end
    return true, ""
end

local function run(name, card)
    check(name .. " ① shipCard 没炸", card ~= nil, "card is nil")
    if card == nil then return end
    local ok, brief = pcall(Card.shipBrief, player, name, card)
    check(name .. " ② shipBrief 没炸（复用同一张卡 ✓）", ok and brief ~= nil, brief)
    if not ok or brief == nil then return end

    local same, why = sameFields(card, brief, name)
    check(name .. " ③ full 与 brief 的方块数组**同源**（逐字一致）", same, why)

    -- brief 是视图：card 没有的方块字段它也不许有（否则就是自造 ✗）
    for _, f in ipairs(BLOCK_FIELDS) do
        if card[f] == nil and brief[f] ~= nil then
            check(name .. " ④ brief 不许自造字段 " .. f, false, "brief 有、card 没有")
        end
    end
end

-- ① 远距离船读得到（本文件全部船都不在本星区 ✓ —— player.craft = nil ✓）
local scout = Card.shipCard(player, "Scout-00001")
run("远距离", scout)
check("① 远距离船 numBlocks = 1234（船档案属性 ✓，不需要实体 ✓）",
    scout.numBlocks == 1234, tostring(scout.numBlocks))
check("① numBlocksKnown = true", scout.numBlocksKnown == true, tostring(scout.numBlocksKnown))
check("① numBlocksSource 写明了文档位置（不许瞎猜 ✗）",
    type(scout.numBlocksSource) == "string" and scout.numBlocksSource:find("271-275", 1, true) ~= nil,
    tostring(scout.numBlocksSource))
check("① 远距离船也读得到 numBlocksWhileMalusActive = 900",
    scout.numBlocksWhileMalusActive == 900, tostring(scout.numBlocksWhileMalusActive))
check("① 未调用文档里不存在的 getNumBlocks()",
    getterCalls == 0, "getterCalls=" .. tostring(getterCalls))

local miner = Card.shipCard(player, "Miner-00001")
check("② 大船 numBlocks = 4000（横向比较的分子 ✓）", miner.numBlocks == 4000,
    tostring(miner.numBlocks))

-- ③ 读不到 → nil + known=false + probe 原因（绝不填 0）
local blind = Card.shipCard(player, "Blind-00001")
run("读不到", blind)
check("③ 读不到时 numBlocks 是 **nil**（不是 0 ✗）", blind.numBlocks == nil,
    tostring(blind.numBlocks))
check("③ 读不到时 numBlocksKnown = false", blind.numBlocksKnown == false,
    tostring(blind.numBlocksKnown))
check("③ 读不到时 probe.numBlocks 有原因",
    type(blind.probe) == "table" and type(blind.probe.numBlocks) == "string",
    blind.probe and blind.probe.numBlocks)
check("③ 读不到时 numBlocksWhileMalusActive 也是 nil（同一规矩 ✓）",
    blind.numBlocksWhileMalusActive == nil, tostring(blind.numBlocksWhileMalusActive))

-- ④ 真值 0：合法值，不许被"读不到"吞掉
local empty = Card.shipCard(player, "Empty-00001")
run("真 0 块", empty)
check("④ 真值 0 块 → numBlocks = 0（合法真值 ✓，不是缺数据 ✗）",
    empty.numBlocks == 0, tostring(empty.numBlocks))
check("④ 真值 0 块 → numBlocksKnown = true", empty.numBlocksKnown == true,
    tostring(empty.numBlocksKnown))

-- ⑤ 非数字 → 当读不到（不硬转、不猜 ✗）
local weird = Card.shipCard(player, "Weird-00001")
run("异常形状", weird)
check("⑤ 非数字串 \"abc\" → numBlocks 是 nil（不猜 ✗）",
    weird.numBlocks == nil, tostring(weird.numBlocks))
check("⑤ 异常形状时 numBlocksKnown = false", weird.numBlocksKnown == false,
    tostring(weird.numBlocksKnown))
check("⑤ 异常形状时 probe 有两处原因（numBlocks + numBlocksWhileMalusActive）",
    type(weird.probe) == "table" and type(weird.probe.numBlocks) == "string"
        and type(weird.probe.numBlocksWhileMalusActive) == "string",
    weird.probe and (tostring(weird.probe.numBlocks) .. " / "
        .. tostring(weird.probe.numBlocksWhileMalusActive)))

-- ⑥ 说明性字段：读得到时才给 note ✓（读不到时 note 也不该出现 —— 别拿说明当数据 ✗）
check("⑥ 读得到 → numBlocksNote 在", type(scout.numBlocksNote) == "string",
    tostring(scout.numBlocksNote))
check("⑥ 读不到 → numBlocksNote 不写（说明跟着数据走 ✓）", blind.numBlocksNote == nil,
    tostring(blind.numBlocksNote))

print("")
if failures == 0 then
    print(string.format("OK: %d checks, 0 failure(s) -- ALL BLOCK-COUNT ASSERTIONS PASSED", checks))
else
    print(string.format("FAILED: %d checks, %d failure(s)", checks, failures))
    os.exit(1)
end
