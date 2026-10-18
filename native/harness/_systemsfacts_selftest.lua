-- _systemsfacts_selftest.lua —— `systemsFacts` 只读原子 + 跃迁补字段的离线自检（2026-10-18 加 ✓✓）
--
-- 不开游戏就能验：把游戏 API（ShipDatabaseEntry / ShipSystem / Player / Sector）换成**内存替身**，
-- 然后**真的调** `data/scripts/net/link_in.lua` 的 `onQuery` 分支与 `copilot/card.lua` 的
-- `M.systemsFacts` / `M.shipCard` / `M.shipBrief` ✓。
--
-- 断言点（主人这一轮的要求逐条对上 ✓）：
--   ① 本星区船：numSockets / maxSockets / numUpgrades / processingPower / equipped 全部读到 ✓；
--      ★ 2026-10-18 扩展：sockets{num,max,used,free} / 逐槽 slots / 20 个 ppThresholds /
--      missing（nextSocket=3、missingPP=7654.4）✓
--   ② 远程船（不在本星区）：socketsKnown/slotsKnown/ppThresholdsKnown/missingKnown 全 false
--      + 原因，**绝不填 0 / 空表** ✗✓；equipped 仍可读 ✓
--   ③ known=false 路径：plan 失败 / getSystems 失败 → 值**不写** + known=false + 原因 ✓
--   ④ 不存在的船 → NO_SUCH_SHIP（不崩、不编）✓
--   ⑤ **只读断言**：调用前后 资源/信用点/方块数/计划 一字不差，写接口调用计数全 0 ✓✓
--   ⑥ 跃迁补字段：getHyperspaceProperties 的 4 个值（cooldown / impaired）进卡 ✓；
--      只回 2 个值时 → cooldown/impaired **不写** + known=false ✓
--   ⑦ 完整卡 与 简报：hyperspace（含 cooldown/impaired）逐字一致 ✓
--   ⑧ onQuery 分支 + caps 自我声明（WHATS / systemsFactsParams）✓
--   ⑨ PP 极高：所有门槛都低于 currentPP → missingPP=0 是**合法 0** + probeExhausted ✓
--   ⑩a PP 门槛读炸 → ppThresholdsKnown=false + **不写值**（不是 0 个门槛 ✗）✓
--   ⑩b 逐槽读炸 → slotsKnown=false + **不写空表**（不是 3 个空槽 ✗）✓
--   ⑪ caps 声明新三样 + 新路径只读总闸 ✓
--
-- 跑法（在仓库根执行）：
--   native\harness\lua.exe native\harness\_systemsfacts_selftest.lua

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

CopilotRpc = { trace = function() end }

-- ---------------------------------------------------------------------------
-- 原版 Format 替身（只有 getTitle() 会用到；Documentation/Format.html:52/84）
-- ---------------------------------------------------------------------------
local function makeFormat(text)
    local f = { text = text }
    f.translated = function(self) return self.text end
    return f
end

-- ---------------------------------------------------------------------------
-- 写接口计数器：**本原子一次都不许碰**（只读证明 ✓✓）
-- ---------------------------------------------------------------------------
local WRITES = {
    pay = 0, setMovePlan = 0, setNumSockets = 0, addUpgrade = 0, removeUpgrade = 0,
    setUpgrade = 0, setNewName = 0, setTitle = 0, addBlock = 0,
}
local function writeBomb(which)
    return function() WRITES[which] = WRITES[which] + 1 end
end

-- 资源 / 信用点 / 方块数：调用前后必须**一字不差** ✓
local STATE = {
    money = 123456789,
    resources = { 1111, 2222, 3333, 4444, 5555, 6666, 7777 },
    planBlocks = 1584,
}
local function stateFingerprint()
    return string.format("money=%d;res=%s;blocks=%d",
        STATE.money, table.concat(STATE.resources, ","), STATE.planBlocks)
end

-- ---------------------------------------------------------------------------
-- 子系统 / 船档案替身
-- ---------------------------------------------------------------------------
local function makeSystem(name, script, rarityName, rarityValue)
    return {
        name = name,
        script = script,
        rarity = { name = rarityName, value = rarityValue },
    }
end

local SYS_TRADING = makeSystem("Trading System", "data/scripts/systems/tradingoverview.lua", "Rare", 3)
local SYS_MINING = makeSystem("Mining System", "data/scripts/systems/miningsystem.lua", "Exceptional", 4)

local SHIPS = {
    -- ① 在本星区的船：槽位 / 处理能力 / 已装模块全部有值 ✓
    ["Miner-00001"] = {
        inSector = true,
        sockets = { numSockets = 3, maxSockets = 4, numUpgrades = 2 },
        processingPower = 12345.6,
        systems = { SYS_MINING, SYS_TRADING },
        -- ★ 逐槽数据（索引 0 基；1 基窗口只有 1 个非 nil → 自动判定应选 0 基 ✓）
        slotOccupancy = { [0] = SYS_MINING, [2] = SYS_TRADING },
        permanent = { [2] = true },
        -- ★ 原样值：0/1/2 都低于 PP(12345.6)，第 3 槽 20000 > PP → missing 应指向 3 ✓
        ppThresholds = { [0] = 100, [1] = 1000, [2] = 8000, [3] = 20000, [4] = 30000 },
        hyper = { 4.1, false, 30, true },
        title = "Mine",
    },
    -- ② 远在本星区外的船：没有实体 → 槽位读不到；但船档案（plan / systems）可读 ✓
    ["Miner-00002"] = {
        inSector = false,
        sockets = { numSockets = 99, maxSockets = 99, numUpgrades = 99 },   -- 绝不该被用到 ✗
        processingPower = 500.25,
        systems = { SYS_TRADING },
        hyper = { 2.2, true },
        title = "Mine",
    },
    -- ③ 两条路都读不到：plan 失败 + player:getShipPlan 失败；getSystems 失败
    ["Blind-00001"] = {
        inSector = false,
        planThrows = true,
        systemsThrow = true,
        hyper = { 3.3, false },
        title = "",
    },
    -- ④ 只用来验跃迁「只回 2 个值」的路径
    ["Scout-00001"] = {
        inSector = false,
        processingPower = 7.5,
        systems = {},
        hyper = { 1.1, false },              -- 旧版本/异常：只有 2 个值
        title = "",
    },
    -- ⑨ PP 极高：所有门槛都低于它 → missingPP 必须是**合法 0**（不是缺数据 ✓）
    ["Rich-00001"] = {
        inSector = true,
        sockets = { numSockets = 5, maxSockets = 15, numUpgrades = 2 },
        processingPower = 1000000000,
        systems = { SYS_TRADING },
        slotOccupancy = { [0] = SYS_TRADING, [4] = SYS_MINING },
        hyper = { 2, false },
        title = "Mine",
    },
    -- ⑩a 第 4 个 PP 读数就炸 → ppThresholdsKnown=false / missingKnown=false，且绝不填 0 ✓
    ["BrokenPP-00001"] = {
        inSector = true,
        sockets = { numSockets = 2, maxSockets = 4, numUpgrades = 1 },
        processingPower = 5000,
        systems = {},
        slotOccupancy = { [0] = SYS_MINING },
        ppThrowsAt = 3,
        hyper = { 2, false },
        title = "",
    },
    -- ⑩b 逐槽读就炸 → slotsKnown=false / slots **不写**（不是「3 个空槽」✗）
    ["BrokenSlot-00001"] = {
        inSector = true,
        sockets = { numSockets = 3, maxSockets = 4, numUpgrades = 1 },
        processingPower = 999,
        systems = {},
        slotOccupancy = { [0] = SYS_MINING },
        slotsThrowAt = 1,
        hyper = { 2, false },
        title = "",
    },
}

local shipSystemCalls = {}   -- [name] = 次数（远程船必须是 0 ✓）

local function makeEntry(name)
    local spec = SHIPS[name]
    if spec == nil then return nil end

    -- 记录方法调用（只读断言用）
    local calls = { getPlan = 0, getSystems = 0, getHyperspaceProperties = 0 }

    local entry = {
        getFreeCargoSpace = function() return 3006 end,
        getCaptain = function() return nil end,
        getCargo = function() return {}, 3006 end,
        getTurrets = function() return {} end,
        getEntityType = function() return 1 end,
        getTitle = function() return makeFormat(spec.title or "") end,
        getHyperspaceProperties = function()
            calls.getHyperspaceProperties = calls.getHyperspaceProperties + 1
            return table.unpack(spec.hyper)
        end,
        -- 写接口（如果被调用，WRITES 会 >0 → 测试挂掉 ✓）
        setMovePlan = writeBomb("setMovePlan"),
        setTitle = writeBomb("setTitle"),
    }

    if spec.planThrows then
        entry.getPlan = function()
            calls.getPlan = calls.getPlan + 1
            error("getPlan() exploded")
        end
    else
        entry.getPlan = function()
            calls.getPlan = calls.getPlan + 1
            return { processingPower = spec.processingPower, numBlocks = STATE.planBlocks }
        end
    end

    if spec.systemsThrow then
        entry.getSystems = function()
            calls.getSystems = calls.getSystems + 1
            error("getSystems() exploded")
        end
    else
        entry.getSystems = function()
            calls.getSystems = calls.getSystems + 1
            local t = {}
            for _, tmpl in ipairs(spec.systems) do t[tmpl] = {} end
            return t
        end
    end

    entry.__calls = calls
    return entry
end

function ShipDatabaseEntry(ownerIndex, name) return makeEntry(name) end

-- 实体（只有 inSector 的船才有）——
local ENTITIES = {}
for name, spec in pairs(SHIPS) do
    if spec.inSector then
        ENTITIES[#ENTITIES + 1] = {
            name = name,
            factionIndex = 1,
            getNumArmedTurrets = function() return 0 end,
            getTurrets = function() end,
        }
    end
end
table.sort(ENTITIES, function(a, b) return a.name < b.name end)

function Sector()
    return {
        getEntitiesByType = function(self, t) return table.unpack(ENTITIES) end,
    }
end

EntityType = { None = 0, Ship = 1, Drone = 2, Station = 3 }

-- ShipSystem 替身：只接受**实体**（与真机一致：ShipSystem.html:86-93），
-- 而且**记录谁被查过** → 远程船必须 0 次 ✓
function ShipSystem(entity)
    local name = entity and entity.name
    shipSystemCalls[name] = (shipSystemCalls[name] or 0) + 1
    local spec = SHIPS[name]
    if spec == nil or spec.sockets == nil then error("ShipSystem: no such entity") end
    local ss = {
        numSockets = spec.sockets.numSockets,
        maxSockets = spec.sockets.maxSockets,
        numUpgrades = spec.sockets.numUpgrades,
        -- 写接口：如果被调用，WRITES 会 >0
        setNumSockets = writeBomb("setNumSockets"),
        addUpgrade = writeBomb("addUpgrade"),
        removeUpgrade = writeBomb("removeUpgrade"),
        setUpgrade = writeBomb("setUpgrade"),
    }
    -- ★ 逐槽 / 每槽 PP 门槛（真机签名：ShipSystem.html:162-201，本替身只回数据 ✓）
    ss.getUpgrade = function(_, i)
        if spec.slotsThrowAt == i then
            error("getUpgrade(" .. tostring(i) .. ") exploded")
        end
        return (spec.slotOccupancy or {})[i]
    end
    ss.isPermanent = function(_, i)
        return (spec.permanent or {})[i] == true
    end
    ss.getProcessingPowerForSocket = function(_, i)
        if spec.ppThrowsAt == i then
            error("getProcessingPowerForSocket(" .. tostring(i) .. ") exploded")
        end
        local t = spec.ppThresholds
        if t ~= nil and t[i] ~= nil then return t[i] end
        return (i + 1) * 10000          -- 缺省单调递增，便于「全部低于 PP」路径 ✓
    end
    return ss
end

ShipAvailability = { Available = 0, InBackground = 1 }
function valid(v) return v ~= nil end
function Balancing_GetSectorRichnessFactor(x, y) return 1.0 end
function Balancing_GetMaterialProbability(x, y) return {} end
function Balancing_InsideRing(x, y) return false end
function NumMaterials() return 7 end

local player = {
    index = 1,
    craft = nil,
    money = STATE.money,
    pay = writeBomb("pay"),
    getShipPosition = function(self, name) return -373, 60 end,
    getShipAvailability = function(self, name) return ShipAvailability.Available end,
    getValue = function(self, key) return "" end,
    setValue = function(self, key, value) end,
    getShipNames = function(self) return table.unpack({ "Miner-00001", "Miner-00002" }) end,
    invokeFunction = function() return true end,
    -- 处理能力的退路（Player [Server].html:1151-1154）
    getShipPlan = function(self, name)
        local spec = SHIPS[name]
        if spec == nil or spec.planThrows then error("no saved plan for " .. tostring(name)) end
        return { processingPower = spec.processingPower, numBlocks = STATE.planBlocks }
    end,
}
function Player() return player end

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

local LinkIn = dofile("data/scripts/net/link_in.lua")
local Card = include("copilot/card")

-- ---------------------------------------------------------------------------
-- 断言工具
-- ---------------------------------------------------------------------------
local function snapshotState()
    return string.format("money=%d;res=%s;blocks=%d", STATE.money,
        table.concat(STATE.resources, ","), STATE.planBlocks)
end
local function writesTotal()
    local n = 0
    for _, v in pairs(WRITES) do n = n + v end
    return n
end
local function findEquipped(res, script)
    for _, item in ipairs(res.equipped or {}) do
        if item.script == script then return item end
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- ① 本星区船：全部读到，值来自真字段
-- ---------------------------------------------------------------------------
print("== ① 本星区船 Miner-00001：槽位/处理能力/已装模块 ==")
local before = snapshotState()
local ok1, res1 = LinkIn.onQuery({ what = "systemsFacts", ship = "Miner-00001" })
check("① ok=true", ok1 == true, tostring(res1))
if ok1 == true then
    check("① what=systemsFacts / readOnly=true / inThisSector=true",
        res1.what == "systemsFacts" and res1.readOnly == true and res1.inThisSector == true,
        string.format("%s/%s/%s", tostring(res1.what), tostring(res1.readOnly), tostring(res1.inThisSector)))
    check("① socketsKnown=true", res1.socketsKnown == true, tostring(res1.socketsKnown))
    check("① numSockets=3 / maxSockets=4 / numUpgrades=2",
        res1.numSockets == 3 and res1.maxSockets == 4 and res1.numUpgrades == 2,
        string.format("%s/%s/%s", tostring(res1.numSockets), tostring(res1.maxSockets),
            tostring(res1.numUpgrades)))
    check("① socketsSource 指向 ShipSystem.html:123-125",
        type(res1.socketsSource) == "string" and res1.socketsSource:find("ShipSystem.html:123-125", 1, true) ~= nil,
        tostring(res1.socketsSource))
    check("① processingPower=12345.6 / processingPowerKnown=true",
        res1.processingPower == 12345.6 and res1.processingPowerKnown == true,
        string.format("%s/%s", tostring(res1.processingPower), tostring(res1.processingPowerKnown)))
    check("① processingPowerSource 指向 BlockPlan.html:232-234",
        type(res1.processingPowerSource) == "string"
            and res1.processingPowerSource:find("BlockPlan.html:232-234", 1, true) ~= nil,
        tostring(res1.processingPowerSource))
    check("① systemsKnown=true / equippedCount=2", res1.systemsKnown == true and res1.equippedCount == 2,
        string.format("%s/%s", tostring(res1.systemsKnown), tostring(res1.equippedCount)))
    local mining = findEquipped(res1, "data/scripts/systems/miningsystem.lua")
    check("① equipped 里有 Mining System（name/rarity/rarityValue ✓）",
        mining ~= nil and mining.name == "Mining System" and mining.rarity == "Exceptional"
            and mining.rarityValue == 4,
        mining and string.format("%s/%s/%s", tostring(mining.name), tostring(mining.rarity),
            tostring(mining.rarityValue)) or "missing")
    local trading = findEquipped(res1, "data/scripts/systems/tradingoverview.lua")
    check("① equipped 里也有 Trading System（排序后按 script 稳定 ✓）",
        trading ~= nil and trading.name == "Trading System", trading and tostring(trading.name) or "missing")
    check("① 排序稳定：miningsystem 在 tradingoverview 之前",
        res1.equipped[1].script:find("miningsystem", 1, true) ~= nil,
        tostring(res1.equipped[1] and res1.equipped[1].script))

    -- ★★ 新三样（2026-10-18 扩展）：「上限 / 每槽空不空 / 缺多少 PP」✓
    check("① sockets 四元组 num=3 / max=4 / used=2 / free=1（★ free = num - used ✓）",
        type(res1.sockets) == "table" and res1.sockets.num == 3 and res1.sockets.max == 4
            and res1.sockets.used == 2 and res1.sockets.free == 1,
        type(res1.sockets) == "table"
            and string.format("%s/%s/%s/%s", tostring(res1.sockets.num), tostring(res1.sockets.max),
                tostring(res1.sockets.used), tostring(res1.sockets.free)) or "missing")
    check("① sockets.freeDefinition 明写 num - used ✓",
        type(res1.sockets) == "table" and type(res1.sockets.freeDefinition) == "string"
            and res1.sockets.freeDefinition:find("num - used", 1, true) ~= nil,
        type(res1.sockets) == "table" and tostring(res1.sockets.freeDefinition) or "missing")
    check("① sockets.maxSocketsSemanticsKnown=false（文档没写语义 → 不解释 ✗）",
        type(res1.sockets) == "table" and res1.sockets.maxSocketsSemanticsKnown == false,
        type(res1.sockets) == "table" and tostring(res1.sockets.maxSocketsSemanticsKnown) or "missing")
    check("① slotsKnown=true / 逐槽 3 个（numSockets=3 ✓）",
        res1.slotsKnown == true and type(res1.slots) == "table" and #res1.slots == 3,
        string.format("%s/%s", tostring(res1.slotsKnown),
            type(res1.slots) == "table" and #res1.slots or tostring(res1.slots)))
    check("① slots[1] index=0 occupied=true subsystemName=Mining System",
        res1.slots[1] ~= nil and res1.slots[1].index == 0 and res1.slots[1].occupied == true
            and res1.slots[1].subsystemName == "Mining System",
        res1.slots[1] and string.format("%s/%s/%s", tostring(res1.slots[1].index),
            tostring(res1.slots[1].occupied), tostring(res1.slots[1].subsystemName)) or "missing")
    check("① slots[2] index=1 occupied=false（★ 空格 ✓）",
        res1.slots[2] ~= nil and res1.slots[2].index == 1 and res1.slots[2].occupied == false,
        res1.slots[2] and string.format("%s/%s", tostring(res1.slots[2].index),
            tostring(res1.slots[2].occupied)) or "missing")
    check("① slots[3] index=2 occupied=true permanent=true（isPermanent 逐槽 ✓）",
        res1.slots[3] ~= nil and res1.slots[3].index == 2 and res1.slots[3].occupied == true
            and res1.slots[3].permanent == true,
        res1.slots[3] and string.format("%s/%s/%s", tostring(res1.slots[3].index),
            tostring(res1.slots[3].occupied), tostring(res1.slots[3].permanent)) or "missing")
    check("① slotIndexBase=0 / slotIndexBaseKnown=true（被 numUpgrades 反向对齐 ✓）",
        res1.slotIndexBase == 0 and res1.slotIndexBaseKnown == true,
        string.format("%s/%s", tostring(res1.slotIndexBase), tostring(res1.slotIndexBaseKnown)))
    check("① slotsConsistentWithNumUpgrades=true（2 个占用 = numUpgrades ✓）",
        res1.slotsConsistentWithNumUpgrades == true and res1.slotsOccupiedCount == 2,
        string.format("%s/%s", tostring(res1.slotsConsistentWithNumUpgrades),
            tostring(res1.slotsOccupiedCount)))
    check("① ppThresholdsKnown=true / 20 个原样值 ✓",
        res1.ppThresholdsKnown == true and type(res1.ppThresholds) == "table"
            and #res1.ppThresholds == 20,
        string.format("%s/%s", tostring(res1.ppThresholdsKnown),
            type(res1.ppThresholds) == "table" and #res1.ppThresholds or tostring(res1.ppThresholds)))
    check("① ppThresholds[1] socket=0 requiredProcessingPower=100（原样）",
        res1.ppThresholds[1] ~= nil and res1.ppThresholds[1].socket == 0
            and res1.ppThresholds[1].requiredProcessingPower == 100,
        res1.ppThresholds[1] and string.format("%s/%s", tostring(res1.ppThresholds[1].socket),
            tostring(res1.ppThresholds[1].requiredProcessingPower)) or "missing")
    check("① ppThresholds[4] socket=3 requiredProcessingPower=20000",
        res1.ppThresholds[4] ~= nil and res1.ppThresholds[4].socket == 3
            and res1.ppThresholds[4].requiredProcessingPower == 20000,
        res1.ppThresholds[4] and string.format("%s/%s", tostring(res1.ppThresholds[4].socket),
            tostring(res1.ppThresholds[4].requiredProcessingPower)) or "missing")
    check("① thresholdSemanticsKnown=false（官方文档没写语义 → 不解释 ✓✓）",
        res1.thresholdSemanticsKnown == false, tostring(res1.thresholdSemanticsKnown))
    check("① ppThresholdsNonDecreasing=true（事实描述，不是语义解释 ✓）",
        res1.ppThresholdsNonDecreasing == true, tostring(res1.ppThresholdsNonDecreasing))
    check("① missingKnown=true / missing.known=true / inferred=true",
        res1.missingKnown == true and type(res1.missing) == "table"
            and res1.missing.known == true and res1.missing.inferred == true,
        string.format("%s/%s/%s", tostring(res1.missingKnown),
            type(res1.missing) == "table" and tostring(res1.missing.known) or "nil",
            type(res1.missing) == "table" and tostring(res1.missing.inferred) or "nil"))
    check("① missing.nextSocket=3 / requiredPP=20000 / currentPP=12345.6",
        res1.missing.nextSocket == 3 and res1.missing.requiredPP == 20000
            and res1.missing.currentPP == 12345.6,
        string.format("%s/%s/%s", tostring(res1.missing.nextSocket),
            tostring(res1.missing.requiredPP), tostring(res1.missing.currentPP)))
    check("① missing.missingPP = 20000 - 12345.6（推断差额 ✓）",
        type(res1.missing.missingPP) == "number"
            and math.abs(res1.missing.missingPP - 7654.4) < 1e-6,
        tostring(res1.missing.missingPP))
    check("① missing.nextSocketAtOrBeyondCurrentSockets=true（3 >= 0 + 3 ✓）",
        res1.missing.nextSocketAtOrBeyondCurrentSockets == true,
        tostring(res1.missing.nextSocketAtOrBeyondCurrentSockets))
    check("① missing.thresholdSemanticsKnown=false / socketIndexBase=0",
        res1.missing.thresholdSemanticsKnown == false and res1.missing.socketIndexBase == 0,
        string.format("%s/%s", tostring(res1.missing.thresholdSemanticsKnown),
            tostring(res1.missing.socketIndexBase)))
end
check("① 只读：调用后 资源/信用点/方块数 一字不差 ✓", snapshotState() == before,
    before .. " -> " .. snapshotState())
check("① 只读：写接口调用计数全 0 ✓", writesTotal() == 0, tostring(writesTotal()))

-- ---------------------------------------------------------------------------
-- ② 远程船：socketsKnown=false + 原因；绝不填 0；equipped 仍可读
-- ---------------------------------------------------------------------------
print("== ② 远程船 Miner-00002：槽位读不到 = 未知（不是 0 ✗）==")
local ok2, res2 = LinkIn.onQuery({ what = "systemsFacts", ship = "Miner-00002" })
check("② ok=true（读不到槽位不是错误，是事实 ✓）", ok2 == true, tostring(res2))
if ok2 == true then
    check("② inThisSector=false", res2.inThisSector == false, tostring(res2.inThisSector))
    check("② socketsKnown=false", res2.socketsKnown == false, tostring(res2.socketsKnown))
    check("② numSockets **不写**（既不是 0 也不是 99 ✗✓）", res2.numSockets == nil,
        tostring(res2.numSockets))
    check("② maxSockets / numUpgrades 也都不写", res2.maxSockets == nil and res2.numUpgrades == nil,
        string.format("%s/%s", tostring(res2.maxSockets), tostring(res2.numUpgrades)))
    check("② 给了 socketsUnknownReason（说清为什么读不到 ✓）",
        type(res2.socketsUnknownReason) == "string"
            and res2.socketsUnknownReason:find("not in this sector", 1, true) ~= nil,
        tostring(res2.socketsUnknownReason))
    check("② ShipSystem 对远程船**一次都没调** ✓", (shipSystemCalls["Miner-00002"] or 0) == 0,
        tostring(shipSystemCalls["Miner-00002"]))
    check("② processingPowerKnown=true（船档案可读，跨星区 ✓）",
        res2.processingPowerKnown == true and res2.processingPower == 500.25,
        string.format("%s/%s", tostring(res2.processingPower), tostring(res2.processingPowerKnown)))
    check("② equipped 照旧可读（getSystems 是船档案 ✓）",
        res2.systemsKnown == true and res2.equippedCount == 1
            and findEquipped(res2, "data/scripts/systems/tradingoverview.lua") ~= nil,
        string.format("%s/%s", tostring(res2.systemsKnown), tostring(res2.equippedCount)))
    -- ★ 新三样在远程船上必须「未知」，不是 0 / 空表 ✓✓
    check("② sockets / slots / ppThresholds / missing **一个都不写**（未知 ≠ 0 ✗✓）",
        res2.sockets == nil and res2.slots == nil and res2.ppThresholds == nil
            and res2.missing == nil,
        string.format("%s/%s/%s/%s", tostring(res2.sockets), tostring(res2.slots),
            tostring(res2.ppThresholds), tostring(res2.missing)))
    check("② slotsKnown / ppThresholdsKnown / missingKnown 全 false + 各有原因",
        res2.slotsKnown == false and res2.ppThresholdsKnown == false and res2.missingKnown == false
            and type(res2.slotsUnknownReason) == "string"
            and type(res2.ppThresholdsUnknownReason) == "string"
            and type(res2.missingUnknownReason) == "string",
        string.format("%s/%s/%s", tostring(res2.slotsKnown),
            tostring(res2.ppThresholdsKnown), tostring(res2.missingKnown)))
    check("② thresholdSemanticsKnown 仍=false（未知也照实说 ✓）",
        res2.thresholdSemanticsKnown == false, tostring(res2.thresholdSemanticsKnown))
end

-- ---------------------------------------------------------------------------
-- ③ known=false 路径：plan 两条路都失败 / getSystems 失败
-- ---------------------------------------------------------------------------
print("== ③ 读不到时：不写值 + known=false + 原因 ==")
local ok3, res3 = LinkIn.onQuery({ what = "systemsFacts", ship = "Blind-00001" })
check("③ ok=true（诚实说读不到 ✓）", ok3 == true, tostring(res3))
if ok3 == true then
    check("③ processingPowerKnown=false 且 processingPower **不写**",
        res3.processingPowerKnown == false and res3.processingPower == nil,
        string.format("%s/%s", tostring(res3.processingPower), tostring(res3.processingPowerKnown)))
    check("③ processingPowerUnknownReason 记了两条失败路径",
        type(res3.processingPowerUnknownReason) == "string"
            and res3.processingPowerUnknownReason:find("getPlan()", 1, true) ~= nil
            and res3.processingPowerUnknownReason:find("getShipPlan", 1, true) ~= nil,
        tostring(res3.processingPowerUnknownReason))
    check("③ systemsKnown=false 且 equipped **不写**",
        res3.systemsKnown == false and res3.equipped == nil,
        string.format("%s/%s", tostring(res3.systemsKnown), tostring(res3.equipped)))
    check("③ systemsUnknownReason 记了 getSystems() 失败",
        type(res3.systemsUnknownReason) == "string"
            and res3.systemsUnknownReason:find("getSystems()", 1, true) ~= nil,
        tostring(res3.systemsUnknownReason))
    check("③ socketsKnown=false + 原因（没有实体 ✓）",
        res3.socketsKnown == false and type(res3.socketsUnknownReason) == "string",
        tostring(res3.socketsUnknownReason))
end

-- ---------------------------------------------------------------------------
-- ④ 不存在的船 → NO_SUCH_SHIP（不崩、不编）
-- ---------------------------------------------------------------------------
print("== ④ 不存在的船 ==")
local ok4, code4 = LinkIn.onQuery({ what = "systemsFacts", ship = "No-Such-Ship" })
check("④ ok=false / NO_SUCH_SHIP", ok4 == false and code4 == "NO_SUCH_SHIP", tostring(code4))
local ok4b, code4b = LinkIn.onQuery({ what = "systemsFacts" })
check("④ 缺 data.ship → BAD_REQUEST", ok4b == false and code4b == "BAD_REQUEST", tostring(code4b))

-- ---------------------------------------------------------------------------
-- ⑤ 只读总断言（连调两次，写计数/状态都必须纹丝不动）
-- ---------------------------------------------------------------------------
print("== ⑤ 只读总断言 ==")
local before5 = snapshotState()
local w0 = writesTotal()
for _ = 1, 2 do
    LinkIn.onQuery({ what = "systemsFacts", ship = "Miner-00001" })
    LinkIn.onQuery({ what = "systemsFacts", ship = "Miner-00002" })
    LinkIn.onQuery({ what = "systemsFacts", ship = "Blind-00001" })
end
check("⑤ 6 次调用后 资源/信用点/方块数 完全不变 ✓", snapshotState() == before5,
    before5 .. " -> " .. snapshotState())
check("⑤ 6 次调用后 写接口计数仍为 0 ✓", writesTotal() == w0, tostring(writesTotal()))

-- ---------------------------------------------------------------------------
-- ⑥ 跃迁补字段：4 个值都进卡；只回 2 个值 → 不写 + known=false
-- ---------------------------------------------------------------------------
print("== ⑥ 跃迁 cooldown / impaired ==")
local cardA = Card.shipCard(player, "Miner-00001")
check("⑥ reach=4.1 / canPassRifts=false", cardA.hyperspace.reach == 4.1
    and cardA.hyperspace.canPassRifts == false,
    string.format("%s/%s", tostring(cardA.hyperspace.reach), tostring(cardA.hyperspace.canPassRifts)))
check("⑥ cooldown=30 / cooldownKnown=true", cardA.hyperspace.cooldown == 30
    and cardA.hyperspace.cooldownKnown == true,
    string.format("%s/%s", tostring(cardA.hyperspace.cooldown), tostring(cardA.hyperspace.cooldownKnown)))
check("⑥ impaired=true / impairedKnown=true", cardA.hyperspace.impaired == true
    and cardA.hyperspace.impairedKnown == true,
    string.format("%s/%s", tostring(cardA.hyperspace.impaired), tostring(cardA.hyperspace.impairedKnown)))

local cardB = Card.shipCard(player, "Scout-00001")
check("⑥ 只回 2 个值：cooldown **不写** + cooldownKnown=false ✓",
    cardB.hyperspace.cooldown == nil and cardB.hyperspace.cooldownKnown == false,
    string.format("%s/%s", tostring(cardB.hyperspace.cooldown), tostring(cardB.hyperspace.cooldownKnown)))
check("⑥ 只回 2 个值：impaired **不写** + impairedKnown=false ✓",
    cardB.hyperspace.impaired == nil and cardB.hyperspace.impairedKnown == false,
    string.format("%s/%s", tostring(cardB.hyperspace.impaired), tostring(cardB.hyperspace.impairedKnown)))
check("⑥ 未取到的原因进了 probe（可追 ✓）",
    type(cardB.probe) == "table" and type(cardB.probe.hyperspaceCooldown) == "string"
        and type(cardB.probe.hyperspaceImpaired) == "string",
    type(cardB.probe) == "table" and tostring(cardB.probe.hyperspaceCooldown) or "no probe")
check("⑥ impaired=false 是**真值**不是缺失（4 值路径里 canPassRifts=false 照写 ✓）",
    cardA.hyperspace.canPassRifts == false, tostring(cardA.hyperspace.canPassRifts))

-- ---------------------------------------------------------------------------
-- ⑦ 完整卡 与 简报一致（hyperspace 整组，含新字段）
-- ---------------------------------------------------------------------------
print("== ⑦ 完整卡 vs 简报 ==")
local briefA = Card.shipBrief(player, "Miner-00001", cardA)
for _, f in ipairs({ "reach", "canPassRifts", "cooldown", "cooldownKnown", "impaired", "impairedKnown" }) do
    check("⑦ hyperspace." .. f .. " 两个视图逐字一致",
        cardA.hyperspace[f] == briefA.hyperspace[f],
        string.format("card=%s brief=%s", tostring(cardA.hyperspace[f]), tostring(briefA.hyperspace[f])))
end
local briefB = Card.shipBrief(player, "Scout-00001", cardB)
for _, f in ipairs({ "cooldown", "cooldownKnown", "impaired", "impairedKnown" }) do
    check("⑦ 读不到时两个视图也一致（都不写/known=false）：" .. f,
        cardB.hyperspace[f] == briefB.hyperspace[f],
        string.format("card=%s brief=%s", tostring(cardB.hyperspace[f]), tostring(briefB.hyperspace[f])))
end

-- ---------------------------------------------------------------------------
-- ⑧ onQuery 分支 + caps 自我声明
-- ---------------------------------------------------------------------------
print("== ⑧ onQuery 分支 / caps 声明 ==")
local hasCardWhat = false
for _, w in ipairs(Card.WHATS or {}) do
    if w == "systemsFacts" then hasCardWhat = true end
end
check("⑧ card.WHATS 里有 systemsFacts ✓（与 onQuery 分支一一对应 ✓）", hasCardWhat, "")

local okC, caps = LinkIn.onQuery({ what = "caps" })
check("⑧ caps ok=true", okC == true, tostring(caps))
if okC == true then
    local hasWhat = false
    for _, w in ipairs(caps.what or {}) do
        if w == "systemsFacts" then hasWhat = true end
    end
    check("⑧ caps.what 声明了 systemsFacts ✓", hasWhat, "")
    check("⑧ caps.systemsFactsParams 声明了 ship ✓",
        type(caps.systemsFactsParams) == "table" and caps.systemsFactsParams.ship ~= nil,
        type(caps.systemsFactsParams))
    check("⑧ 参数表明说「没有 confirm / 纯事实」✓",
        type(caps.systemsFactsParams) == "table"
            and type(caps.systemsFactsParams.note) == "string"
            and caps.systemsFactsParams.note:find("纯事实", 1, true) ~= nil,
        type(caps.systemsFactsParams))
end

-- ---------------------------------------------------------------------------
-- ⑨ PP 极高：missingPP 是**合法 0**（probeExhausted），不是缺数据
-- ---------------------------------------------------------------------------
print("== ⑨ 所有门槛都低于 currentPP → missingPP = 0 ==")
local ok9, res9 = LinkIn.onQuery({ what = "systemsFacts", ship = "Rich-00001" })
check("⑨ ok=true", ok9 == true, tostring(res9))
if ok9 == true then
    check("⑨ sockets.free = 5 - 2 = 3（有 3 个空槽 ✓）",
        type(res9.sockets) == "table" and res9.sockets.num == 5 and res9.sockets.used == 2
            and res9.sockets.free == 3,
        type(res9.sockets) == "table" and tostring(res9.sockets.free) or "missing")
    check("⑨ slots 5 个 / 0 与 4 占用、中间 3 个空",
        res9.slotsKnown == true and #res9.slots == 5
            and res9.slots[1].occupied == true and res9.slots[2].occupied == false
            and res9.slots[3].occupied == false and res9.slots[4].occupied == false
            and res9.slots[5].occupied == true,
        string.format("known=%s count=%s", tostring(res9.slotsKnown),
            type(res9.slots) == "table" and #res9.slots or tostring(res9.slots)))
    check("⑨ missingKnown=true / missingPP=0 / probeExhausted=true（合法 0 ✓）",
        res9.missingKnown == true and res9.missing.missingPP == 0
            and res9.missing.probeExhausted == true,
        type(res9.missing) == "table" and string.format("%s/%s", tostring(res9.missing.missingPP),
            tostring(res9.missing.probeExhausted)) or "missing")
    check("⑨ 没有更高门槛 → nextSocket **不写**（不填 0 ✗✓）",
        res9.missing.nextSocket == nil, tostring(res9.missing.nextSocket))
end

-- ---------------------------------------------------------------------------
-- ⑩ 读不到 → known=false + 值**不写**（绝不 0 / 绝不空表 ✗✓）
-- ---------------------------------------------------------------------------
print("== ⑩ 读不到：known=false + 值不写 ==")
local okA, resA = LinkIn.onQuery({ what = "systemsFacts", ship = "BrokenPP-00001" })
check("⑩a ok=true（诚实说读不到 ✓）", okA == true, tostring(resA))
if okA == true then
    check("⑩a ppThresholdsKnown=false 且 ppThresholds **不写**（不是 0 个门槛 ✗）",
        resA.ppThresholdsKnown == false and resA.ppThresholds == nil,
        string.format("%s/%s", tostring(resA.ppThresholdsKnown), tostring(resA.ppThresholds)))
    check("⑩a ppThresholdsUnknownReason 记了具体槽",
        type(resA.ppThresholdsUnknownReason) == "string"
            and resA.ppThresholdsUnknownReason:find("socket 3", 1, true) ~= nil,
        tostring(resA.ppThresholdsUnknownReason))
    check("⑩a missingKnown=false 且 missing **不写**（missingPP 不是 0 ✗✓）",
        resA.missingKnown == false and resA.missing == nil,
        string.format("%s/%s", tostring(resA.missingKnown), tostring(resA.missing)))
end
local okB, resB = LinkIn.onQuery({ what = "systemsFacts", ship = "BrokenSlot-00001" })
check("⑩b ok=true", okB == true, tostring(resB))
if okB == true then
    check("⑩b slotsKnown=false 且 slots **不写**（不是 3 个空槽 ✗）",
        resB.slotsKnown == false and resB.slots == nil,
        string.format("%s/%s", tostring(resB.slotsKnown), tostring(resB.slots)))
    check("⑩b slotsUnknownReason 记了 getUpgrade 失败",
        type(resB.slotsUnknownReason) == "string"
            and resB.slotsUnknownReason:find("getUpgrade", 1, true) ~= nil,
        tostring(resB.slotsUnknownReason))
end

-- ---------------------------------------------------------------------------
-- ⑪ caps 自我声明新三样 + 新路径也只读
-- ---------------------------------------------------------------------------
print("== ⑪ caps 声明 + 只读总闸 ==")
if okC == true and type(caps.systemsFactsParams) == "table" then
    local pnote = tostring(caps.systemsFactsParams.note or "")
    check("⑪ note 提到 sockets{num,max,used,free}",
        pnote:find("sockets{num,max,used,free}", 1, true) ~= nil, pnote)
    check("⑪ note 提到 slots 逐槽", pnote:find("slots[", 1, true) ~= nil, pnote)
    check("⑪ note 提到 ppThresholds 与 missing",
        pnote:find("ppThresholds", 1, true) ~= nil and pnote:find("missing", 1, true) ~= nil, pnote)
    check("⑪ note 明说 thresholdSemanticsKnown=false",
        pnote:find("thresholdSemanticsKnown=false", 1, true) ~= nil, pnote)
end
check("⑪ 新路径也只读：写接口计数仍为 0 ✓", writesTotal() == 0, tostring(writesTotal()))
check("⑪ 新路径也不改 资源/信用点/方块数 ✓", snapshotState() == before5,
    before5 .. " -> " .. snapshotState())

-- ---------------------------------------------------------------------------
print(string.format("\n%d checks, %d failure(s)", checks, failures))
if failures > 0 then os.exit(1) end
print("ALL SYSTEMSFACTS ASSERTIONS PASSED ✓✓")
