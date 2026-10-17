-- _captain_class_selftest.lua —— 船长职业三字段的**回归断言** ✓✓（2026-10-17 加）
--
-- 主人抓到的错（逐字）：
--   「同一艘船 `Trader-00001`：完整卡 `captainClass: "Merchant"`，简报 `captainClass: "None"`
--     且 `captainClassKnown: true`」✗ —— 同一艘船、同一个字段、两个值 ✓。
--
-- 根因（已修，见 data/scripts/lib/copilot/card.lua 的 readCaptainClass 注释 ✓）：
--   旧代码用 `captain:hasClass(ClassType.X)` 逐个试 ✗ —— 而 `hasClass` 连**副职业 None** 也匹配
--   （原版 captainutility.lua:800 才显示副职业，默认就是 None ✓），
--   于是谁先命中由 `pairs()` 的**未定义顺序**决定 ✗ → 有时 "Merchant"、有时 "None" ✓。
--
-- 本文件断言的规格（全部是主人的原话 ✓）：
--   ① 同一艘船的 `shipCard` 与 `shipBrief` 在 captainClass / captainClassId / captainClassKnown
--      三个字段上**必须一致** ✓✓（同源 ✓ 不许两套逻辑 ✗）
--   ② "取不到职业" 时 `captainClassKnown` **必须为 false** ✓，且不许填 "None" ✗
--   ③ "确实没船长" 也一样：known=false、不给 captainClass ✓（"没有" ≠ "知道是 None" ✓）
--   ④ 真·Merchant 的船长必须报 "Merchant" / "3" ✓ —— 即使它的 `hasClass(None)` 也为 true ✓
--      （即：**根本不该调用 hasClass** —— 本测试顺手数调用次数 ✓）
--
-- 跑法（在仓库根执行）：  native\harness\lua.exe native\harness\_captain_class_selftest.lua

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
-- 原版的职业表：**逐字照抄** data/scripts/lib/captainclass.lua:3-15 ✓
-- （顺序很要紧 —— 旧 bug 就是被这张表的遍历顺序坑的 ✓）
-- ---------------------------------------------------------------------------
local CLASS_TYPE = {
    None = 0, Commodore = 1, Smuggler = 2, Merchant = 3, Miner = 4,
    Scavenger = 5, Explorer = 6, Daredevil = 7, Scientist = 8, Hunter = 9,
}

-- ---------------------------------------------------------------------------
-- 船长的替身
--   · Trader-00001：真·Merchant（主 3）+ 副职业 None（0）—— 就是主人那艘船的真人设定 ✓
--   · Blind-00001 ：船长在，但 `primaryClass` 读不到（模拟"没取到"✓）
--   · Empty-00001 ：**没有船长** ✓
-- ---------------------------------------------------------------------------
local CAPTAINS = {
    ["Trader-00001"] = { primaryClass = 3, secondaryClass = 0 },
    ["Blind-00001"] = {},                       -- 字段缺失 = 读不到 ✓
    ["Empty-00001"] = nil,                      -- 没船长 ✓
}

local nHasClass = 0                             -- ★ 只要有人调 hasClass，这里就会 +1 ✓
local function makeCaptain(name)
    local src = CAPTAINS[name]
    if src == nil then return nil end
    local c = {}
    for k, v in pairs(src) do c[k] = v end
    -- 原版语义（captainutility.lua:452-453 读两个字段）：hasClass 命中**主或副**任一 ✓
    --   → 副职业是 None 时，hasClass(None) 也是 true ✓ —— 旧 bug 的温床 ✓
    c.hasClass = function(self, classType)
        nHasClass = nHasClass + 1
        return self.primaryClass == classType or self.secondaryClass == classType
    end
    return c
end

-- ---------------------------------------------------------------------------
-- 游戏 API 的替身
-- ---------------------------------------------------------------------------

CopilotRpc = { trace = function() end }

function include(name)
    if name == "copilot/card" then return dofile("data/scripts/lib/copilot/card.lua") end
    if name == "captainutility" then return { ClassType = CLASS_TYPE } end
    if name == "areaanalysis" then return nil end
    if name == "commandfactory" then return { makeCommand = function() return {} end } end
    if name == "copilot/trade" then return dofile("data/scripts/lib/copilot/trade.lua") end
    if name == "copilot/job" then return dofile("data/scripts/lib/copilot/job.lua") end
    if name == "goods" then return {} end
    error("unexpected include: " .. tostring(name))
end

function ShipDatabaseEntry(ownerIndex, name)
    if CAPTAINS[name] == nil and name ~= "Empty-00001" then return nil end   -- 真·null 的情况再单测
    return {
        getFreeCargoSpace = function() return 10000 end,
        getCaptain = function() return makeCaptain(name) end,
        getCargo = function() return {}, 5000 end,
        getTurrets = function() return {} end,
        getHyperspaceProperties = function() return 12, false end,
    }
end

ShipAvailability = { Available = 0, InBackground = 1 }
function valid(v) return v ~= nil end
function Balancing_GetSectorRichnessFactor(x, y) return 1.0 end
function Balancing_GetMaterialProbability(x, y) return {} end
function Balancing_InsideRing(x, y) return false end
function NumMaterials() return 7 end

local SHIP_X, SHIP_Y = -385, 65
local player = {
    index = 1,
    craft = nil,
    getShipPosition = function(self, name) return SHIP_X, SHIP_Y end,
    getValue = function(self, key)
        if key == "copilot_auto_ships" then
            return "Trader-00001\nBlind-00001\nEmpty-00001\n"
        end
        return ""
    end,
    getShipAvailability = function(self, name) return ShipAvailability.Available end,
    invokeFunction = function(self, path, fn, ...) return true end,
}

function Player() return player end

local LinkIn = dofile("data/scripts/net/link_in.lua")
local Card = include("copilot/card")

-- ---------------------------------------------------------------------------
-- 断言工具
-- ---------------------------------------------------------------------------

local CAPTAIN_FIELDS = { "captainClass", "captainClassId", "captainClassKnown" }

-- ① 两个视图在 captain 三字段上**逐字一致** ✓
local function sameThree(card, brief, label)
    for _, f in ipairs(CAPTAIN_FIELDS) do
        if card[f] ~= brief[f] then
            return false, string.format("%s: %s  card=%s brief=%s", label, f,
                tostring(card[f]), tostring(brief[f]))
        end
    end
    return true, ""
end

local function fieldsOf(card)
    return string.format("captainClass=%s captainClassId=%s captainClassKnown=%s",
        tostring(card.captainClass), tostring(card.captainClassId),
        tostring(card.captainClassKnown))
end

-- ---------------------------------------------------------------------------
-- ① 真·Merchant：完整卡 / 简报 / 两条 RPC 入口，四处必须都是 Merchant ✓
-- ---------------------------------------------------------------------------
print("== ① 真·Merchant 的船长：四处同值，且不许被副职业 None 带跑 ==")
local okC, card = pcall(Card.shipCard, player, "Trader-00001")
check("① shipCard 没炸（pcall ✓）", okC, card)
card = okC and card or {}

local okB, brief = pcall(Card.shipBrief, player, "Trader-00001", card)
check("① shipBrief 没炸（pcall ✓）", okB, brief)
brief = okB and brief or {}

check("① 完整卡 captainClass == 'Merchant'（★ 旧代码在这里会报 'None' ✗）",
    card.captainClass == "Merchant", fieldsOf(card))
check("① 完整卡 captainClassId == '3'", card.captainClassId == "3", fieldsOf(card))
check("① 完整卡 captainClassKnown == true（确实拿到了 ✓）",
    card.captainClassKnown == true, fieldsOf(card))
check("① 简报 captainClass == 'Merchant'", brief.captainClass == "Merchant", fieldsOf(brief))

local okSame, why = sameThree(card, brief, "shipCard vs shipBrief")
check("① 完整卡 与 简报 在 captain 三字段上一致 ✓✓", okSame, why)
check("① 简报也带上了 captainClassId（同源，不许少字段 ✗）",
    brief.captainClassId ~= nil, fieldsOf(brief))
check("① 谁都没调用 captain:hasClass（唯一取值路径 ✓）", nHasClass == 0,
    "hasClass 被调用了 " .. nHasClass .. " 次")

-- RPC 入口（真的走 net/link_in.lua 的 onQuery ✓ —— 简报就是从这里出去的 ✓）
local okQ1, full = LinkIn.onQuery({ what = "ship", ship = "Trader-00001" })
local okQ2, brie = LinkIn.onQuery({ what = "ship", ship = "Trader-00001", brief = true })
check("① onQuery(ship) ok", okQ1 == true, full)
check("① onQuery(ship, brief=true) ok", okQ2 == true, brie)
if okQ1 and okQ2 then
    local okSame2, why2 = sameThree(full, brie, "RPC 完整卡 vs RPC 简报")
    check("① RPC 完整卡 与 RPC 简报 三字段一致 ✓✓（主人要的那条断言 ✓）", okSame2, why2)
    check("① RPC 两份都报 Merchant", full.captainClass == "Merchant" and brie.captainClass == "Merchant",
        fieldsOf(full) .. " | " .. fieldsOf(brie))
end

-- ---------------------------------------------------------------------------
-- ② 取不到职业：known 必须 false，且**不许**填 "None" ✗
-- ---------------------------------------------------------------------------
print("== ② 取不到职业：known=false，不许填 'None' ==")
local okC2, card2 = pcall(Card.shipCard, player, "Blind-00001")
check("② shipCard(Blind) 没炸", okC2, card2)
card2 = okC2 and card2 or {}
local okB2, brief2 = pcall(Card.shipBrief, player, "Blind-00001", card2)
check("② shipBrief(Blind) 没炸", okB2, brief2)
brief2 = okB2 and brief2 or {}

check("② captainClassKnown == false（老实说不知道 ✓）", card2.captainClassKnown == false, fieldsOf(card2))
check("② captainClass == nil（不填 'None' ✗）", card2.captainClass == nil, fieldsOf(card2))
check("② captainClassId == nil（不瞎给数字 ✗）", card2.captainClassId == nil, fieldsOf(card2))
check("② hasCaptain == true（船长确实在 ✓ —— 与'没取到职业'要分开 ✓）",
    card2.hasCaptain == true, fieldsOf(card2))
local okSame3, why3 = sameThree(card2, brief2, "Blind: shipCard vs shipBrief")
check("② 取不到时，完整卡与简报仍然一致 ✓", okSame3, why3)

-- ---------------------------------------------------------------------------
-- ③ 确实没有船长：known=false、不给 captainClass ✓
-- ---------------------------------------------------------------------------
print("== ③ 确实没船长：known=false，且不给 captainClass ==")
local okC3, card3 = pcall(Card.shipCard, player, "Empty-00001")
check("③ shipCard(Empty) 没炸", okC3, card3)
card3 = okC3 and card3 or {}
local okB3, brief3 = pcall(Card.shipBrief, player, "Empty-00001", card3)
brief3 = okB3 and brief3 or {}
check("③ hasCaptain == false", card3.hasCaptain == false, fieldsOf(card3))
check("③ captainClassKnown == false", card3.captainClassKnown == false, fieldsOf(card3))
check("③ captainClass == nil", card3.captainClass == nil, fieldsOf(card3))
local okSame4, why4 = sameThree(card3, brief3, "Empty: shipCard vs shipBrief")
check("③ 无船长时，完整卡与简报仍然一致 ✓", okSame4, why4)

-- ---------------------------------------------------------------------------
-- ④ 连数据库条目都没有（entry == nil）：也是"没取到" → known=false ✓
-- ---------------------------------------------------------------------------
print("== ④ 没有 ShipDatabaseEntry：known=false ==")
local okC4e, card4e = pcall(Card.shipCard, player, "Ghost-00001")
check("④ shipCard(Ghost) 没炸", okC4e, card4e)
card4e = okC4e and card4e or {}
check("④ captainClassKnown == false（没取到 ✓）", card4e.captainClassKnown == false, fieldsOf(card4e))
check("④ captainClass == nil", card4e.captainClass == nil, fieldsOf(card4e))
check("④ probe 里写清了原因（可排错 ✓）",
    type(card4e.probe) == "table" and card4e.probe.entry ~= nil, "probe=" .. tostring(card4e.probe))

-- ---------------------------------------------------------------------------
-- ⑤ 遍历顺序不该影响答案：把职业表**换个构造顺序**，答案必须不变 ✓
--    （旧代码的答案会随这个顺序变 ✗ —— 这正是主人看到的 "Merchant"/"None" 两个值 ✓）
-- ---------------------------------------------------------------------------
print("== ⑤ 顺序无关：换构造顺序，Merchant 仍必须是 Merchant ==")
local shuffled = {}
-- 故意按 0,2,1,3,... 的顺序插键（旧代码对这种表会先命中 None ✗）
for _, name in ipairs({ "None", "Smuggler", "Commodore", "Merchant", "Miner",
                        "Scavenger", "Explorer", "Daredevil", "Scientist", "Hunter" }) do
    shuffled[name] = CLASS_TYPE[name]
end
local saved = CLASS_TYPE
include = (function(orig)
    return function(name)
        if name == "captainutility" then return { ClassType = shuffled } end
        return orig(name)
    end
end)(include)
local okC4, card4 = pcall(Card.shipCard, player, "Trader-00001")
check("⑤ 换顺序后 shipCard 没炸", okC4, card4)
card4 = okC4 and card4 or {}
check("⑤ 换顺序后仍是 'Merchant' / '3'（与顺序无关 ✓✓）",
    card4.captainClass == "Merchant" and card4.captainClassId == "3", fieldsOf(card4))
include = (function(orig)
    return function(name)
        if name == "captainutility" then return { ClassType = saved } end
        return orig(name)
    end
end)(include)

-- ---------------------------------------------------------------------------
print(string.format("\n%d checks, %d failure(s)", checks, failures))
if failures > 0 then os.exit(1) end
print("ALL CAPTAIN-CLASS ASSERTIONS PASSED ✓✓")
