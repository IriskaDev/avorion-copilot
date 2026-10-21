-- _weapons_card_selftest.lua —— 「能打不能打」这几个字段的**回归断言**（2026-10-17 加）
--
-- 主人抓到的事（逐字）：
--   「你的 Combat-00001 舰船没有炮塔或武装舰载机！」
--   而主人**明明给它装了炮塔** —— 所以要么装的是槽位、要么炮被摘了、
--   ★ 要么**卡片的 `turretCount` 口径骗人**。
--   → 真机取证结果：**第三种** ✓（Raven 4 门炮也报 1 ✗）。
--
-- 病根（本文件用第 ①/② 组断言钉死）：
--   `ShipDatabaseEntry:getTurrets()` 返回**一张表、一个值**（文档
--   ShipDatabaseEntry [Server].html:877-890："the turrets are the **keys**" ✓），
--   而旧代码写 `{ entry:getTurrets() }` → `#` 恒等于 **1** ✗。
--
-- 本文件断言的口径（全部来自 card.lua 的「装备 / 武器事实」一节 ✓）：
--   ① 已装炮塔数 = 表里的**键数**（不是 1 ✗）；类别计数正确 ✓
--   ② 类别读不出来 → `armedTurrets` **不写** + `armedTurretsKnown=false` ✗✓（绝不填 0 ✗）
--   ③ `getTurrets()` 整体调不动 → `turretCount` 不写 + known=false + probe 有原因 ✓
--   ④ 舰载机：`fighter.armed` 布尔退路也算得对 ✓
--   ⑤ `canFight` 照抄原版 checkArmed：鱼雷 / 已装武装炮塔 / 武装舰载机，任一 > 0 即 true ✓
--   ⑥ 完整卡与简报在**整组**装备字段上逐字一致 ✓（同源 ✓，简报不许自造字段 ✗）
--   ⑦ 实体口径（`liveArmedTurrets`）只在船**在本星区**时出现 ✓
--
-- 跑法（在仓库根执行）：
--   build\harness\lua.exe native\harness\_weapons_card_selftest.lua

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
-- 原版枚举替身（Documentation/Enums.html:1623-1630 WeaponCategory）
--   Armed=0 / Mining=1 / Salvaging=2 / Heal=3 / None=4
-- ---------------------------------------------------------------------------
WeaponCategory = { Armed = 0, Mining = 1, Salvaging = 2, Heal = 3, None = 4 }
EntityType = { None = 0, Ship = 1, Drone = 2, Station = 3 }

-- 类别值三种形态（真机上 category 是 userdata ✓，这里用三种替身覆盖三条取值路径 ✓）：
--   · 纯数字            → tonumber 那条路 ✓
--   · { value = n }     → .value 那条路 ✓
--   · {}                → 三条路全失败 → **读不出来** ✓（测"绝不填 0" ✓）
--
-- ★★ 2026-10-22：炮塔替身改成**严格表**（读不存在的键 = 抛错 + 记账）✗→✓
--
-- 为什么必须这样 ✗→✓（真机铁证，本机 serverlog）：
--   旧代码读了 `turret.weaponType` —— 而 `TurretTemplate` **没有**这个属性
--   （Documentation/TurretTemplate.html 的属性表里没有 weaponType ✓）。
--   真机上每读一次，引擎就抛异常 + 构造 30 行调用栈 + 写 serverlog
--   （"Property not found or not readable: TurretTemplate.weaponType"），
--   10 分钟写满 10 MB、一晚两个归档合计 **11911 次** ✗✓；pcall 挡不住这笔开销 ✗。
--   → 所以测试替身也要**像真机一样对未知属性抛错** ✓，并记下谁摸过 ✗✓。
--   否则这个坑永远测不出来（普通 Lua 表读不存在的键只会安静地给 nil ✗）。
local STRICT_HITS = {}
local function strictRecord(t, kind)
    return setmetatable(t, {
        __index = function(_, k)
            STRICT_HITS[#STRICT_HITS + 1] = kind .. "." .. tostring(k)
            error("Property not found or not readable: " .. kind .. "." .. tostring(k), 2)
        end,
    })
end

local function turret(categoryValue, weaponName)
    -- 字段取自文档真实属性：category（WeaponCategory ✓）+ weaponName（string ✓）
    return strictRecord({ category = categoryValue, weaponName = weaponName or "Laser" },
        "TurretTemplate")
end

-- ★ 真机的形状（别搞错，这是旧 bug 的同一个坑 ✗✓）：
--   `ShipDatabaseEntry:getTurrets()` 返回的表里 **炮塔本身是键**、说明表是值
--   （文档 ShipDatabaseEntry [Server].html:877-890："the turrets are the **keys**" ✓）
--   → 测试替身必须同形状，否则测不出真问题 ✓
local function turretMap(...)
    local list = { ... }
    local out = {}
    for i = 1, #list do out[list[i]] = { index = i } end
    return out
end

local function fighter(categoryValue, armed)
    local f = {}
    if categoryValue ~= nil then f.category = categoryValue end
    if armed ~= nil then f.armed = armed end
    return f
end

local function squad(...)
    local fighters = { ... }
    return {
        getFighters = function(self)
            return table.unpack(fighters)
        end,
    }
end

-- 鱼雷发射管替身：★ 真机纠正 —— TorpedoShaft **没有** numTorpedoes 字段 ✗
-- （Documentation/TorpedoShaft.html:84-120；有 `getTorpedoes()` 多返回值 :126-128 ✓）
local function shaft(n)
    local rounds = {}
    for i = 1, n do rounds[i] = { name = "torpedo" .. i } end
    return {
        getTorpedoes = function(self) return table.unpack(rounds) end,
        occupiedSpace = n * 2,
        space = 20,
    }
end

-- ---------------------------------------------------------------------------
-- 每艘船的替身
-- ---------------------------------------------------------------------------
local UNREADABLE = {}                           -- 类别读不出来 ✓

local SHIPS = {
    -- 参照真机：Raven 是 4 门武装炮（主人说的 ✓）。这里给 6 门混合，好证明计数不是 1 ✓
    ["Raven"] = {
        turrets = turretMap(
            turret(WeaponCategory.Armed, "Bolter"),
            turret(0, "Bolter"),                     -- 纯数字形态 ✓
            turret({ value = 0 }, "Laser"),          -- .value 形态 ✓
            turret(WeaponCategory.Armed, "RailGun"),
            turret(WeaponCategory.Mining, "Mining Laser"),
            turret({ value = 1 }, "Mining Laser")
        ),
        squads = { squad(fighter(WeaponCategory.Armed)) },
        dps = { 1234.5, 56.0 },
        torpedoes = nil,                             -- 没装发射器 → 引擎给 nil ✓
    },
    -- 采矿船：只有采矿炮、没舰载机、没鱼雷 → canFight 必须是 **false** ✓（真值，不是未知 ✗）
    ["MinerOnly-00001"] = {
        turrets = turretMap(turret(WeaponCategory.Mining), turret(WeaponCategory.Mining)),
        squads = {},
        dps = { 50.0, 0.0 },
        torpedoes = nil,
    },
    -- 有一门类别读不出来 → armedTurrets **不知道** ✗（不是 0 ✗）
    ["BlindTurret-00001"] = {
        turrets = turretMap(turret(WeaponCategory.Armed), turret(UNREADABLE)),
        squads = {},
        dps = { 10.0, 0.0 },
        torpedoes = nil,
    },
    -- getTurrets 整体调不动 → turretCount 不写 ✓
    ["NoTurretApi-00001"] = { turretsThrows = true, squads = {}, dps = { 0, 0 }, torpedoes = nil },
    -- 没炮没机、但有鱼雷 → checkArmed 判据⓪ 成立 → canFight = true ✓
    ["TorpBoat-00001"] = {
        turrets = turretMap(),
        squads = {},
        dps = { 0.0, 0.0 },
        torpedoes = { shaft(2), shaft(1) },
    },
    -- 舰载机类别用 `.armed` 布尔退路 ✓（FighterTemplate.html:306）
    ["Carrier-00001"] = {
        turrets = turretMap(),
        squads = { squad(fighter(nil, true), fighter(nil, true), fighter(nil, false)) },
        dps = { 0.0, 300.0 },
        torpedoes = nil,
    },
    -- 在本星区里的船 → 要读得到实体口径 ✓
    ["InSector-00001"] = {
        turrets = turretMap(turret(WeaponCategory.Armed)),
        squads = {},
        dps = { 99.0, 0.0 },
        torpedoes = nil,
    },
}

function include(name)
    if name == "copilot/card" then return dofile("data/scripts/lib/copilot/card.lua") end
    if name == "captainutility" then return { ClassType = { None = 0 } } end
    error("unexpected include: " .. tostring(name))
end

local function makeEntry(name)
    local spec = SHIPS[name]
    if spec == nil then return nil end
    local entry = {
        getFreeCargoSpace = function() return 1000 end,
        getCaptain = function() return nil end,
        getCargo = function() return {}, 1000 end,
        getHyperspaceProperties = function() return 4.1, false end,
        getEntityType = function() return EntityType.Ship end,
        getTitle = function() return { text = "", translated = function() return "" end } end,
        getDPSValues = function() return spec.dps[1], spec.dps[2] end,
        getTorpedoes = function() return spec.torpedoes end,
        getLightweightHangar = function() return spec.squads, { space = 0 } end,
    }
    if spec.turretsThrows then
        entry.getTurrets = function() error("getTurrets() exploded") end
    else
        entry.getTurrets = function() return spec.turrets end
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

-- ★ 实体口径用的星区替身：只有 InSector-00001 真的在这个星区里 ✓
local LIVE = {
    ["InSector-00001"] = {
        name = "InSector-00001",
        getNumArmedTurrets = function() return 1 end,
        getTurrets = function() return "t1", "t2", "t3" end,   -- 实体口径是多返回值 ✓
    },
}

local player = {
    index = 1,
    craft = nil,
    getShipPosition = function(self, name) return -373, 60 end,
    getValue = function(self, key) return "" end,
    getShipAvailability = function(self, name) return ShipAvailability.Available end,
    invokeFunction = function(self, path, fn, ...) return true end,
}
function Player() return player end

function Sector()
    return {
        getEntitiesByType = function(self, entityType)
            local out = {}
            for _, e in pairs(LIVE) do out[#out + 1] = e end
            return table.unpack(out)
        end,
    }
end

local Card = include("copilot/card")

local function cardOf(name)
    local ok, card = pcall(Card.shipCard, player, name)
    if not ok then error("shipCard(" .. name .. ") threw: " .. tostring(card)) end
    return card
end

local function briefOf(name)
    local card = cardOf(name)
    local ok, brief = pcall(Card.shipBrief, player, name, card)
    if not ok then error("shipBrief(" .. name .. ") threw: " .. tostring(brief)) end
    return card, brief
end

-- ---------------------------------------------------------------------------
-- ⓪ [纯函数] 类别名：三条取值路径 + 一条"读不出来"路径
-- ---------------------------------------------------------------------------
print("== ⓪ weaponCategoryName：数字 / .value / 全局枚举 / 读不出来 ==")
do
    check("⓪ 数字 0 → Armed", Card.weaponCategoryName(0) == "Armed", Card.weaponCategoryName(0))
    check("⓪ 数字 2 → Salvaging", Card.weaponCategoryName(2) == "Salvaging", Card.weaponCategoryName(2))
    check("⓪ {value=1} → Mining", Card.weaponCategoryName({ value = 1 }) == "Mining",
        Card.weaponCategoryName({ value = 1 }))
    check("⓪ 全局枚举 WeaponCategory.Heal(3) → Heal", Card.weaponCategoryName(WeaponCategory.Heal) == "Heal",
        Card.weaponCategoryName(WeaponCategory.Heal))
    check("⓪ 读不出来 → nil（绝不猜成 Armed/None ✗）", Card.weaponCategoryName(UNREADABLE) == nil,
        tostring(Card.weaponCategoryName(UNREADABLE)))
end

-- ---------------------------------------------------------------------------
-- ① 已装炮塔数 = 表里的键数（**不是 1** ✗）；类别计数正确
-- ---------------------------------------------------------------------------
print("== ① Raven：6 门炮（4 武装 + 2 采矿）—— 数出来的不能是 1 ==")
do
    local c = cardOf("Raven")
    check("① turretCount == 6（旧版这里是 1 ✗）", c.turretCount == 6, tostring(c.turretCount))
    check("① turretCountKnown == true", c.turretCountKnown == true, tostring(c.turretCountKnown))
    local cats = c.turretCategories or {}
    check("① turretCategories.Armed == 4", cats.Armed == 4, tostring(cats.Armed))
    check("① turretCategories.Mining == 2", cats.Mining == 2, tostring(cats.Mining))
    check("① armedTurrets == 4", c.armedTurrets == 4, tostring(c.armedTurrets))
    check("① armedTurretsKnown == true", c.armedTurretsKnown == true, tostring(c.armedTurretsKnown))
    check("① 没有 turretCategoryUnknown（6 门全读到 ✓）", c.turretCategoryUnknown == nil,
        tostring(c.turretCategoryUnknown))
    check("① turretTypes 仍然保留（旧消费方还在看 ✓）",
        type(c.turretTypes) == "table" and (c.turretTypes.Bolter or 0) == 2,
        c.turretTypes and c.turretTypes.Bolter)
    check("① dps 来自 entry:getDPSValues()（炮塔 1234.5 / 舰载机 56 ✓）",
        type(c.dps) == "table" and c.dps.turret == 1234.5 and c.dps.fighter == 56.0,
        c.dps and tostring(c.dps.turret) .. "/" .. tostring(c.dps.fighter))
end

-- ---------------------------------------------------------------------------
-- ② 类别读不出来 → 不写 armedTurrets、known=false（绝不填 0 ✗）
-- ---------------------------------------------------------------------------
print("== ② 一门炮的类别读不出来：armedTurrets 必须是**未知**，不是 0 ==")
do
    local c = cardOf("BlindTurret-00001")
    check("② turretCount 仍然如实给（2 ✓）", c.turretCount == 2, tostring(c.turretCount))
    check("② turretCountKnown == true", c.turretCountKnown == true, tostring(c.turretCountKnown))
    check("② armedTurrets **不写**（nil ✗ 不是 0 ✗）", c.armedTurrets == nil, tostring(c.armedTurrets))
    check("② armedTurretsKnown == false", c.armedTurretsKnown == false, tostring(c.armedTurretsKnown))
    check("② turretCategoryUnknown == 1", c.turretCategoryUnknown == 1, tostring(c.turretCategoryUnknown))
    check("② canFight **不写**（判据不全 → 不许下结论 ✗）", c.canFight == nil, tostring(c.canFight))
    check("② canFightKnown == false", c.canFightKnown == false, tostring(c.canFightKnown))
    check("② probe.armedTurrets 有原因", type(c.probe) == "table"
        and type(c.probe.armedTurrets) == "string", c.probe and tostring(c.probe.armedTurrets))
end

-- ---------------------------------------------------------------------------
-- ③ getTurrets() 整体调不动 → 不写 turretCount + probe 有原因
-- ---------------------------------------------------------------------------
print("== ③ entry:getTurrets() 抛错：turretCount 必须**不写** ==")
do
    local c = cardOf("NoTurretApi-00001")
    check("③ turretCount == nil（不是 0 ✗）", c.turretCount == nil, tostring(c.turretCount))
    check("③ turretCountKnown == false", c.turretCountKnown == false, tostring(c.turretCountKnown))
    check("③ armedTurrets == nil", c.armedTurrets == nil, tostring(c.armedTurrets))
    check("③ canFight == nil", c.canFight == nil, tostring(c.canFight))
    check("③ probe.turrets 记下了原因", type(c.probe) == "table"
        and tostring(c.probe.turrets):find("getTurrets", 1, true) ~= nil,
        c.probe and tostring(c.probe.turrets))
end

-- ---------------------------------------------------------------------------
-- ④ 舰载机：类别 + `.armed` 布尔退路；⑤ canFight 的三条判据
-- ---------------------------------------------------------------------------
print("== ④⑤ 舰载机计数 / canFight（照抄原版 checkArmed）==")
do
    local c = cardOf("Carrier-00001")
    check("④ fighters == 3", c.fighters == 3, tostring(c.fighters))
    check("④ fightersKnown == true", c.fightersKnown == true, tostring(c.fightersKnown))
    check("④ armedFighters == 2（armed=true 的两架 ✓）", c.armedFighters == 2, tostring(c.armedFighters))
    check("④ fighterSquads == 1", c.fighterSquads == 1, tostring(c.fighterSquads))
    check("④ canFight == true（武装舰载机 > 0 ✓）", c.canFight == true, tostring(c.canFight))

    local m = cardOf("MinerOnly-00001")
    check("④ 采矿船：fighters == 0（真值 ✓）", m.fighters == 0, tostring(m.fighters))
    check("④ 采矿船：armedFighters == 0（真值 ✓）", m.armedFighters == 0, tostring(m.armedFighters))
    check("④ 采矿船：armedTurrets == 0（真值 ✓）", m.armedTurrets == 0, tostring(m.armedTurrets))
    check("⑤ 采矿船 canFight == **false**（无炮无机的真值 ✓，不是未知 ✗）",
        m.canFight == false, tostring(m.canFight))
    check("⑤ 采矿船 canFightKnown == true", m.canFightKnown == true, tostring(m.canFightKnown))

    local t = cardOf("TorpBoat-00001")
    check("⑤ 鱼雷算武装：torpedoes == 3", t.torpedoes == 3, tostring(t.torpedoes))
    check("⑤ 鱼雷船 canFight == true（判据⓪ ✓）", t.canFight == true, tostring(t.canFight))

    local r = cardOf("Raven")
    check("⑤ Raven canFight == true（4 门武装炮 ✓）", r.canFight == true, tostring(r.canFight))
    check("⑤ Raven 没装鱼雷 → torpedoes == 0 且 known == true（nil 表 = 真值 ✓）",
        r.torpedoes == 0 and r.torpedoesKnown == true,
        tostring(r.torpedoes) .. "/" .. tostring(r.torpedoesKnown))
    check("⑤ equipmentNote 说清了「已装 ≠ 蓝图槽位」并把文案出处指出来",
        type(r.equipmentNote) == "string"
        and r.equipmentNote:find("currently equipped", 1, true) ~= nil
        and r.equipmentNote:find("entity.lua:81", 1, true) ~= nil,
        type(r.equipmentNote))
end

-- ---------------------------------------------------------------------------
-- ⑥ 完整卡 ⇄ 简报：整组装备字段同源（值逐字相等；card 没有的 brief 也不许有 ✗）
-- ---------------------------------------------------------------------------
print("== ⑥ 完整卡与简报：装备整组字段同源 ==")
local EQUIP_FIELDS = {
    "turretCount", "turretCountKnown", "turretCategories", "turretCategoryUnknown", "turretTypes",
    "armedTurrets", "armedTurretsKnown", "liveArmedTurrets", "liveTurretCount", "inThisSector",
    "fighterSquads", "fighters", "fightersKnown", "fighterCategories", "fighterCategoryUnknown",
    "armedFighters", "armedFightersKnown", "torpedoes", "torpedoesKnown", "torpedoShafts",
    "dps", "canFight", "canFightKnown", "equipmentNote",
}
do
    local function deepEqual(a, b)
        if type(a) ~= type(b) then return false end
        if type(a) ~= "table" then return a == b end
        for k, v in pairs(a) do
            if not deepEqual(v, b[k]) then return false end
        end
        for k in pairs(b) do
            if a[k] == nil then return false end
        end
        return true
    end

    for _, name in ipairs({ "Raven", "MinerOnly-00001", "BlindTurret-00001",
                            "NoTurretApi-00001", "TorpBoat-00001", "Carrier-00001" }) do
        local card, brief = briefOf(name)
        local bad = {}
        for _, f in ipairs(EQUIP_FIELDS) do
            local cv, bv = card[f], brief[f]
            if cv == nil and bv ~= nil then
                bad[#bad + 1] = f .. " 简报自造（card=nil brief=" .. tostring(bv) .. "）"
            elseif cv ~= nil and bv == nil then
                bad[#bad + 1] = f .. " 简报漏了（card=" .. tostring(cv) .. "）"
            elseif not deepEqual(cv, bv) then
                bad[#bad + 1] = f .. " 值不同"
            end
        end
        check("⑥ " .. name .. "：装备整组逐字一致（" .. #EQUIP_FIELDS .. " 个字段 ✓）",
            #bad == 0, table.concat(bad, "; "))
    end

    -- 取不到时 brief 也**不许**把 turretCount 写成 0 ✗
    local card2, brief2 = briefOf("NoTurretApi-00001")
    check("⑥ 取不到时：brief 里 turretCount 仍是 nil、known=false ✓",
        brief2.turretCount == nil and brief2.turretCountKnown == false,
        tostring(brief2.turretCount) .. "/" .. tostring(brief2.turretCountKnown))
    check("⑥ 取不到时：brief 里 canFight 仍是 nil ✓", brief2.canFight == nil, tostring(brief2.canFight))
end

-- ---------------------------------------------------------------------------
-- ⑦ 实体口径：只有船在本星区才写 liveArmedTurrets ✓
-- ---------------------------------------------------------------------------
print("== ⑦ 实体口径（liveArmedTurrets）只对**本星区**的船出现 ==")
do
    local c = cardOf("InSector-00001")
    check("⑦ 本星区的船：inThisSector == true", c.inThisSector == true, tostring(c.inThisSector))
    check("⑦ liveArmedTurrets == 1（Entity:getNumArmedTurrets ✓）",
        c.liveArmedTurrets == 1, tostring(c.liveArmedTurrets))
    check("⑦ liveTurretCount == 3（Entity:getTurrets() 是多返回值 ✓，select('#') ✓）",
        c.liveTurretCount == 3, tostring(c.liveTurretCount))

    local far = cardOf("Raven")
    check("⑦ 不在本星区的船：inThisSector 不写", far.inThisSector == nil, tostring(far.inThisSector))
    check("⑦ 不在本星区的船：liveArmedTurrets 不写（绝不猜 ✗）",
        far.liveArmedTurrets == nil, tostring(far.liveArmedTurrets))
end

-- ---------------------------------------------------------------------------
-- ⑧ ★★ 不读**不存在**的属性（2026-10-22 加 —— 服务端掉帧的同一条根 ✗→✓）
-- ---------------------------------------------------------------------------
--
-- 真机铁证：旧代码读 `turret.weaponType`，而 `TurretTemplate` 没这个属性
-- （Documentation/TurretTemplate.html）。每一次读取 = 引擎抛异常 + 30 行堆栈 +
-- 写一条 serverlog，一晚两个 10 MB 归档合计 11911 条 ✗✓（pcall 挡不住 ✗）。
-- → 替身表设了严格 `__index`（读未知键就抛错并记账），所以这里断言：
--   **整个测试过程里没有一次访问过不存在的炮塔属性** ✓✓
print("== ⑧ 炮塔替身是严格表：不许读文档里没有的属性 ==")
do
    check("⑧ 全程没有访问过不存在的 TurretTemplate 属性（曾读过：" ..
        (#STRICT_HITS > 0 and table.concat(STRICT_HITS, ", ") or "无") .. "）",
        #STRICT_HITS == 0, table.concat(STRICT_HITS, ", "))

    local c = cardOf("Raven")
    check("⑧ turretTypes 改从真实属性 `weaponName` 得名（Bolter × 2 ✓）",
        type(c.turretTypes) == "table" and (c.turretTypes.Bolter or 0) == 2,
        c.turretTypes and tostring(c.turretTypes.Bolter))
    check("⑧ Raven 的炮名分布 = Bolter 2 / Laser 1 / RailGun 1 / Mining Laser 2",
        type(c.turretTypes) == "table"
        and (c.turretTypes.Bolter or 0) == 2 and (c.turretTypes.Laser or 0) == 1
        and (c.turretTypes.RailGun or 0) == 1 and (c.turretTypes["Mining Laser"] or 0) == 2,
        c.turretTypes and (tostring(c.turretTypes.Bolter) .. "/" .. tostring(c.turretTypes.Laser)
            .. "/" .. tostring(c.turretTypes.RailGun) .. "/" .. tostring(c.turretTypes["Mining Laser"])))
    check("⑧ 严格表确实在拦：没人摸过 weaponType（旧病根）",
        (function()
            for _, hit in ipairs(STRICT_HITS) do
                if hit:find("weaponType", 1, true) ~= nil then return false end
            end
            return true
        end)(), table.concat(STRICT_HITS, ", "))
end

-- ---------------------------------------------------------------------------
-- 汇总
-- ---------------------------------------------------------------------------
print("")
print(string.format("%d checks, %d failures", checks, failures))
if failures > 0 then os.exit(1) end
