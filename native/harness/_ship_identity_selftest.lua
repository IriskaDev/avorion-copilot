-- _ship_identity_selftest.lua —— 「船的称号/类别」字段的**回归断言**（2026-10-17 加）
--
-- 主人抓到的事（逐字）：
--   「上一轮说『原版没有船类型/角色字段』✗，而主人现在明确说：『有类别的』✓」
--   → 本鱼上一轮找错了地方 ✗：类别**不在** Entity 的属性表里，而是
--     **ShipDatabaseEntry:getTitle()**（服务端也有 ✓，跨星区、没实体照样读 ✓）。
--
-- 本文件断言的口径（全部来自 card.lua 的注释与真机输出 ✓）：
--   ① 有称号的船：shipCard 与 shipBrief 在
--      shipTitle / shipTitleRaw / shipTitleKnown / entityType / entityTypeId 上**逐字一致** ✓
--      （同源 ✓，不许两套逻辑 ✗）
--   ② 称号是**空串**：known 必须 true、shipTitle 必须是 ""、且**两个视图都带 shipTitleNote** ✓
--      （"真·没称号" ≠ "读不到" ✗✓）
--   ③ `getTitle()` 调用失败：known 必须 false、**不许写 shipTitle**、probe 里必须有原因 ✓
--   ④ `translated()` 失败但 `text` 在：退回原始串，并记 probe 说明 ✓（绝不丢成 nil ✗）
--   ⑤ 简报**不许自造字段**：card 里没有的身份字段，brief 里也不能有 ✗
--
-- 跑法（在仓库根执行）：
--   build\harness\lua.exe native\harness\_ship_identity_selftest.lua

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
-- 原版的 Format / NamedFormat 替身（Documentation/Format.html:52 translated、:84 text）
-- ---------------------------------------------------------------------------
local function makeFormat(text, translated, translatedThrows)
    local f = { text = text }
    f.translated = function(self)
        if translatedThrows then error("translated() exploded") end
        return translated
    end
    return f
end

-- EntityType（Documentation/Enums.html:1069-1086）
EntityType = { None = 0, Ship = 1, Drone = 2, Station = 3, Wreckage = 6 }

-- ---------------------------------------------------------------------------
-- 每艘船的替身：getTitle / getEntityType / 其余能力卡要用的最小集合
-- ---------------------------------------------------------------------------
local SHIPS = {
    -- ① 有称号（原版 NPC 生成器写的就是这种：shipgenerator.lua:194）
    ["Miner-00002"] = { title = makeFormat("Miner /* ship title */", "Miner"), entityType = EntityType.Ship },
    -- ② 称号是空串（玩家自建船，simulationutility.lua:512 的 `if title ~= ""` 分支）
    ["Blank-00001"] = { title = makeFormat("", ""), entityType = EntityType.Ship },
    -- ③ getTitle() 根本调不动
    ["Blind-00001"] = { titleThrows = true, entityType = EntityType.Ship },
    -- ④ translated() 炸了，但 text 在
    ["RawOnly-00001"] = { title = makeFormat("Trader /* ship title */", nil, true), entityType = EntityType.Ship },
    -- ⑤ 不是船（EntityType.Station）—— 证明 entityType 是真读出来的，不是硬编码 ✗
    ["Dock-00001"] = { title = makeFormat("", ""), entityType = EntityType.Station },
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

local function makeEntry(name)
    local spec = SHIPS[name]
    if spec == nil then return nil end
    local entry = {
        getFreeCargoSpace = function() return 3006 end,
        getCaptain = function() return nil end,
        getCargo = function() return {}, 3006 end,
        getTurrets = function() return {} end,
        getHyperspaceProperties = function() return 4.1, false end,
        getEntityType = function() return spec.entityType end,
    }
    if spec.titleThrows then
        entry.getTitle = function() error("getTitle() exploded") end
    else
        entry.getTitle = function() return spec.title end
    end
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
-- 断言工具
-- ---------------------------------------------------------------------------

-- 这五个字段是**一组身份事实**（值 + 原串 + 是否已知 + 种类 + 种类枚举数字 ✓）
local IDENTITY_FIELDS = { "shipTitle", "shipTitleRaw", "shipTitleKnown", "entityType", "entityTypeId", "shipTitleNote" }

local function sameIdentity(card, brief, label)
    for _, f in ipairs(IDENTITY_FIELDS) do
        if card[f] ~= brief[f] then
            return false, string.format("%s: %s  card=%s brief=%s", label, f,
                tostring(card[f]), tostring(brief[f]))
        end
    end
    return true, ""
end

local function briefHasNoExtraField(card, brief)
    -- ★ 简报是**视图**：card 没有的字段它也不许有（否则就是自造数据 ✗）
    for _, f in ipairs(IDENTITY_FIELDS) do
        if card[f] == nil and brief[f] ~= nil then
            return false, f .. " 在 brief 里有、card 里没有（简报自造字段 ✗）"
        end
    end
    return true, ""
end

local function identityOf(card)
    return string.format("shipTitle=%s shipTitleRaw=%s known=%s entityType=%s/%s",
        tostring(card.shipTitle), tostring(card.shipTitleRaw),
        tostring(card.shipTitleKnown), tostring(card.entityType), tostring(card.entityTypeId))
end

local function run(name)
    local card = Card.shipCard(player, name)
    local brief = Card.shipBrief(player, name, card)
    return card, brief
end

-- ---------------------------------------------------------------------------
-- ① 有称号：完整卡与简报**逐字一致**，且值就是原版会写的那种（"Miner"）
-- ---------------------------------------------------------------------------
print("== ① 有称号的船（Miner-00002）：值 + 两个视图一致 ==")
local card, brief = run("Miner-00002")
check("① shipTitle == 'Miner'（原版 shipgenerator.lua:194 写的就是这个）",
    card.shipTitle == "Miner", identityOf(card))
check("① shipTitleRaw 保留原始格式串（含原版注释 /* ship title */ ✓）",
    type(card.shipTitleRaw) == "string" and card.shipTitleRaw:find("Miner", 1, true) ~= nil,
    identityOf(card))
check("① shipTitleKnown == true（确实读到了 ✓）", card.shipTitleKnown == true, identityOf(card))
check("① 空称号时才该有 shipTitleNote —— 这里有称号，不许加 ✗",
    card.shipTitleNote == nil, tostring(card.shipTitleNote))
check("① entityType == 'Ship' / entityTypeId == 1",
    card.entityType == "Ship" and card.entityTypeId == 1, identityOf(card))
check("① 完整卡 与 简报 在身份字段上逐字一致 ✓✓",
    sameIdentity(card, brief, "Miner: card vs brief"), "")
check("① 简报没自造字段", briefHasNoExtraField(card, brief), "")

-- ---------------------------------------------------------------------------
-- ② 空称号：known=true、""、两个视图都带 note（真·没称号 ≠ 读不到 ✗）
-- ---------------------------------------------------------------------------
print("== ② 空称号（玩家自建船 Blank-00001）：known=true、空串、note 必须两个视图都有 ==")
local card2, brief2 = run("Blank-00001")
check("② shipTitleKnown == true（读到了，只是空 ✓）", card2.shipTitleKnown == true, identityOf(card2))
check("② shipTitle == ''（真·没称号 ✓，不许填 nil 装没有 ✗）", card2.shipTitle == "", identityOf(card2))
check("② shipTitleRaw == ''", card2.shipTitleRaw == "", identityOf(card2))
check("② shipTitleNote 在完整卡里（说明原版为什么不带类别 ✓）",
    type(card2.shipTitleNote) == "string" and card2.shipTitleNote:find("getTitle", 1, true) ~= nil,
    tostring(card2.shipTitleNote))
check("② shipTitleNote 也必须在简报里（两个视图同口径 ✓）",
    brief2.shipTitleNote == card2.shipTitleNote, tostring(brief2.shipTitleNote))
check("② 完整卡 与 简报 逐字一致", sameIdentity(card2, brief2, "Blank: card vs brief"), "")

-- ---------------------------------------------------------------------------
-- ③ getTitle() 调不动：known=false、**不写 shipTitle**、probe 有原因
-- ---------------------------------------------------------------------------
print("== ③ 读不到称号（Blind-00001）：known=false、不许写 shipTitle ✗ ==")
local card3, brief3 = run("Blind-00001")
check("③ shipTitleKnown == false", card3.shipTitleKnown == false, identityOf(card3))
check("③ 不许写 shipTitle（读不到 ≠ 没称号 ✗）", card3.shipTitle == nil, identityOf(card3))
check("③ 不许写 shipTitleRaw", card3.shipTitleRaw == nil, identityOf(card3))
check("③ probe.shipTitle 记了原因（可追 ✓）",
    type(card3.probe) == "table" and type(card3.probe.shipTitle) == "string"
        and card3.probe.shipTitle:find("getTitle", 1, true) ~= nil,
    type(card3.probe) == "table" and tostring(card3.probe.shipTitle) or "no probe")
check("③ 完整卡 与 简报 逐字一致", sameIdentity(card3, brief3, "Blind: card vs brief"), "")
check("③ 简报没自造字段", briefHasNoExtraField(card3, brief3), "")

-- ---------------------------------------------------------------------------
-- ④ translated() 失败但 text 在：退回原始串 + probe 说明
-- ---------------------------------------------------------------------------
print("== ④ translated() 失败（RawOnly-00001）：退回 text，且有 probe 说明 ==")
local card4, brief4 = run("RawOnly-00001")
check("④ shipTitle 退回原始串（不许丢成 nil ✗）",
    type(card4.shipTitle) == "string" and card4.shipTitle:find("Trader", 1, true) ~= nil,
    identityOf(card4))
check("④ shipTitleKnown == true（Format 拿到了 ✓）", card4.shipTitleKnown == true, identityOf(card4))
check("④ probe.shipTitle 记了 translated() 失败 ✓",
    type(card4.probe) == "table" and type(card4.probe.shipTitle) == "string"
        and card4.probe.shipTitle:find("translated", 1, true) ~= nil,
    type(card4.probe) == "table" and tostring(card4.probe.shipTitle) or "no probe")
check("④ 完整卡 与 简报 逐字一致", sameIdentity(card4, brief4, "RawOnly: card vs brief"), "")

-- ---------------------------------------------------------------------------
-- ⑤ entityType 是**真读出来的**：同一套代码对空间站必须报 Station ✗
-- ---------------------------------------------------------------------------
print("== ⑤ entityType 不是硬编码：站 Dock-00001 必须报 Station ==")
local card5 = Card.shipCard(player, "Dock-00001")
check("⑤ entityType == 'Station' / entityTypeId == 3（证明是读 entry 的 ✓）",
    card5.entityType == "Station" and card5.entityTypeId == 3, identityOf(card5))

-- ---------------------------------------------------------------------------
-- ⑥ ★ 真机踩过的坑：那个 VM 里 `EntityType` 全局取不到名字（真机输出 Unknown(1) ✗）
--    → 名字必须**靠文档顺序的硬表**兜底 ✓（Documentation/Enums.html:1069-1086）
-- ---------------------------------------------------------------------------
print("== ⑥ EntityType 全局缺失（真机就是这样 ✗）→ 仍必须报 Ship ==")
local savedEntityType = EntityType
EntityType = nil
local card6 = Card.shipCard(player, "Miner-00002")
check("⑥ 没有 EntityType 全局时，硬表兜底报 'Ship' / 1 ✓✓",
    card6.entityType == "Ship" and card6.entityTypeId == 1, identityOf(card6))
EntityType = savedEntityType

-- ⑦ 表里没有的 id：老实报 Unknown(n)，不许瞎编 ✗
print("== ⑦ 未知 id（99）→ Unknown(99) ==")
local savedEntry = ShipDatabaseEntry
ShipDatabaseEntry = function(ownerIndex, name)
    if name ~= "Weird-00001" then return savedEntry(ownerIndex, name) end
    return {
        getFreeCargoSpace = function() return 100 end,
        getCaptain = function() return nil end,
        getCargo = function() return {}, 100 end,
        getTurrets = function() return {} end,
        getHyperspaceProperties = function() return 1, false end,
        getEntityType = function() return 99 end,
        getTitle = function() return makeFormat("", "") end,
    }
end
local card7 = Card.shipCard(player, "Weird-00001")
check("⑦ entityType == 'Unknown(99)'（拿不到名字就说不知道 ✓，数字照给 ✓）",
    card7.entityType == "Unknown(99)" and card7.entityTypeId == 99, identityOf(card7))
ShipDatabaseEntry = savedEntry

-- ---------------------------------------------------------------------------
print(string.format("\n%d checks, %d failure(s)", checks, failures))
if failures > 0 then os.exit(1) end
print("ALL SHIP-IDENTITY ASSERTIONS PASSED ✓✓")
