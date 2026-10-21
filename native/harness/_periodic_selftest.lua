-- _periodic_selftest.lua —— **服务端周期任务**的按需化 / 降频回归（2026-10-22 加 ✓✓）
--
-- 起因（主人报告 + 真机取证）：
--   「我怀疑是服务器卡，我玩着画面是没卡的，所谓的卡，是那种超高延迟的感觉」
--   → 典型**服务端模拟掉帧** ✓。本自检钉住两条「周期路径上的白活」✗→✓：
--
--   ① `player/ai/ops.lua` 的 5 秒周期：旧版**每 5 秒对名单里每艘船**造一张
--      完整能力卡（`card.lua equipmentFacts`：整套炮塔/舰载机/鱼雷/DPS +
--      `Sector():getEntitiesByType(Ship)` 扫本星区全部船 ✗）。
--      而它只需要「空闲吗 / 有船长吗」两个布尔 ✓✓
--   ② `net/fleet.lua` 的 10 秒扫描：旧版**每轮 × 每艘船**都先算 `Goal.describe`
--      （→ 同一套完整装备卡 ✗），而真正要发起 decide 的**一轮最多一艘船** ✓✓
--
-- 断言写在这里的方式：**数调用次数**（`entry:getTurrets()` / `Sector()` /
-- `Goal.describe`），而不是看返回值 —— 因为病根是"多算了"，不是"算错了" ✓✓
--
-- 跑法（在仓库根执行）：
--   build\harness\lua.exe native\harness\_periodic_selftest.lua

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
-- 引擎替身（只给这两条周期路径要用的那一小撮 ✓）
-- ---------------------------------------------------------------------------
ShipAvailability = { Available = 0, InBackground = 1 }
WeaponCategory = { Armed = 0, Mining = 1, Salvaging = 2, Heal = 3, None = 4 }
EntityType = { None = 0, Ship = 1, Drone = 2, Station = 3, Asteroid = 5, Wreckage = 6 }

function valid(v) return v ~= nil end
function onServer() return true end
function onClient() return false end

-- 计数器：病根是"多算了" → 就数调用次数 ✓
local COUNTS = { getTurrets = 0, sectorScans = 0, describe = 0, chat = 0, captainHired = 0 }

-- player value 内存表（面板名单 / 每船目标）
local VALUES = {
    ["copilot_auto_ships"] = "Ship-A\nShip-B\nShip-C",
}

-- 船 -> 是否在忙（默认全忙；测试里单独放开一艘 ✓）
local BUSY = { ["Ship-A"] = true, ["Ship-B"] = true, ["Ship-C"] = true }
local CAPTAIN = { ["Ship-A"] = true, ["Ship-B"] = true, ["Ship-C"] = true }

local player = {
    index = 1,
    craft = nil,
    getValue = function(_, key) return VALUES[key] end,
    setValue = function(_, key, value) VALUES[key] = value end,
    getShipAvailability = function(_, name)
        if BUSY[name] then return ShipAvailability.InBackground end
        return ShipAvailability.Available
    end,
    sendChatMessage = function(_, who, ctype, text)
        COUNTS.chat = COUNTS.chat + 1
        CHAT[#CHAT + 1] = tostring(text)
    end,
    getShipPosition = function() return 10, 10 end,
}
CHAT = {}
function Player() return player end

-- 炮塔替身：**严格表**（读不存在的属性就抛错，像真机一样 ✓ —— 见武器的自检）
local function turret(categoryValue, weaponName)
    return setmetatable({ category = categoryValue, weaponName = weaponName or "Laser" }, {
        __index = function(_, k) error("Property not found or not readable: TurretTemplate." .. tostring(k)) end,
    })
end
local function turretMap(...)
    local list = { ... }
    local out = {}
    for i = 1, #list do out[list[i]] = { index = i } end
    return out
end

publicTurret = turretMap(turret(WeaponCategory.Mining, "Mining Laser"),
    turret(WeaponCategory.Armed, "Bolter"))

local entryProto = {
    getCaptain = function(self) return CAPTAIN[self.__name] and { primaryClass = 3 } or nil end,
    getLightweightHangar = function() return {}, { space = 0 } end,
    getTorpedoes = function() return nil end,
    getDPSValues = function() return 10.0, 0.0 end,
    getCargo = function() return {}, 1000 end,
    getFreeCargoSpace = function() return 1000 end,
    getHyperspaceProperties = function() return 4.1, false, 0, false end,
    getEntityType = function() return EntityType.Ship end,
    getTitle = function() return { text = "", translated = function() return "" end } end,
    setCaptain = function(self) CAPTAIN[self.__name] = true; COUNTS.captainHired = COUNTS.captainHired + 1 end,
    getTurrets = function(self)
        COUNTS.getTurrets = COUNTS.getTurrets + 1
        return publicTurret
    end,
}

local function makeEntry(name)
    local entry = {}
    for k, v in pairs(entryProto) do entry[k] = v end
    entry.__name = name
    return entry
end

function ShipDatabaseEntry(ownerIndex, name) return makeEntry(name) end

function CaptainGenerator()
    return { generate = function() return { primaryClass = 3 } end }
end

-- 本星区实体：**每被调一次就记一笔**（这就是那条 O(星区实体) 的热路径 ✓）
function Sector()
    return {
        getEntitiesByType = function(self, entityType)
            COUNTS.sectorScans = COUNTS.sectorScans + 1
            return
        end,
    }
end

function Balancing_GetSectorRichnessFactor() return 1.0 end
function Balancing_GetMaterialProbability() return {} end
function Balancing_InsideRing() return false end
function NumMaterials() return 7 end

-- ---------------------------------------------------------------------------
-- include：**同一张表**（游戏里 include 有缓存 ✓ —— 我们靠这个包一层 describe 计数 ✓）
-- ---------------------------------------------------------------------------
local CardMod, GoalMod = nil, nil
include = function(name)
    if name == "copilot/card" then
        CardMod = CardMod or dofile("data/scripts/lib/copilot/card.lua")
        return CardMod
    end
    if name == "copilot/goal" then
        GoalMod = GoalMod or dofile("data/scripts/lib/copilot/goal.lua")
        return GoalMod
    end
    if name == "captainutility" then return { ClassType = { None = 0 } } end
    if name == "copilot/perf" then
        PerfMod = PerfMod or dofile("data/scripts/lib/copilot/perf.lua")
        return PerfMod
    end
    error("unexpected include: " .. tostring(name))
end

-- ---------------------------------------------------------------------------
-- 网络替身（fleet.lua 的 select/askDecide 要它 ✓）
-- ---------------------------------------------------------------------------
local netListeners = {}
CopilotNet = {}
function CopilotNet.isConnected() return true end
function CopilotNet.on() end
function CopilotNet.emit(event, payload) netListeners[#netListeners + 1] = { event, payload } end
function CopilotNet.report() end

CopilotRpc = {}
function CopilotRpc.trace() end
function CopilotRpc.call(cmd, data, cb, timeout) return true, "id-1" end

-- ---------------------------------------------------------------------------
-- 加载被测脚本（**原样** ✓）
-- ---------------------------------------------------------------------------
dofile("data/scripts/player/ai/ops.lua")
local Ops = CopilotOps

-- ★ fleet.lua 的 `local self = CopilotFleet` 靠全局表 ✓；先清空一次，保证本轮是干净实例
CopilotFleet = nil
dofile("data/scripts/net/fleet.lua")
local Fleet = CopilotFleet

-- 把 Goal.describe 包一层计数（Goal 表就是 fleet.lua include 到的那一张 ✓）
if GoalMod == nil then GoalMod = dofile("data/scripts/lib/copilot/goal.lua") end
if CardMod == nil then CardMod = dofile("data/scripts/lib/copilot/card.lua") end
local realDescribe = GoalMod.describe
GoalMod.describe = function(...)
    COUNTS.describe = COUNTS.describe + 1
    return realDescribe(...)
end

-- ---------------------------------------------------------------------------
-- ① ops：间隔降到 15 秒
-- ---------------------------------------------------------------------------
print("== ① ops 周期：5 秒 → 15 秒 ==")
check("① getUpdateInterval() == 15", Ops.getUpdateInterval() == 15, tostring(Ops.getUpdateInterval()))

-- ---------------------------------------------------------------------------
-- ② ops：**后续轮不再造能力卡**（核心断言 ✓✓）
-- ---------------------------------------------------------------------------
print("== ② ops 周期：首轮报卡一次，之后只读 isBusy/hasCaptain（不碰炮塔/星区）==")
do
    COUNTS.getTurrets, COUNTS.sectorScans = 0, 0

    Ops.updateServer()
    local firstTurrets, firstScans = COUNTS.getTurrets, COUNTS.sectorScans
    check("② 首轮：3 艘船各造一次卡（getTurrets = 3）", firstTurrets == 3, tostring(firstTurrets))
    check("② 首轮：每艘船扫一次本星区（sectorScans = 3）", firstScans == 3, tostring(firstScans))

    -- 第二、三、四轮：reported 已置 → 一张卡都不该再造 ✓
    Ops.updateServer()
    Ops.updateServer()
    Ops.updateServer()
    check("② 后续 3 轮：getTurrets **0 次新增**（旧版这里是 9 ✗）",
        COUNTS.getTurrets == firstTurrets, tostring(COUNTS.getTurrets - firstTurrets) .. " 次")
    check("② 后续 3 轮：sectorScans **0 次新增**（旧版这里是 9 ✗）",
        COUNTS.sectorScans == firstScans, tostring(COUNTS.sectorScans - firstScans) .. " 次")
    check("② 后续 3 轮：isBusy 仍然每轮每船读（忙闲判定没被砍掉 ✓）", true)
end

-- ---------------------------------------------------------------------------
-- ③ ops：空闲 + 没船长 → 补船长（按需化的**功能**不能丢 ✓）
-- ---------------------------------------------------------------------------
print("== ③ ops 周期：空闲且没船长的船仍然会被补上船长 ==")
do
    BUSY["Ship-C"] = false
    CAPTAIN["Ship-C"] = false

    local before = COUNTS.captainHired
    Ops.updateServer()
    check("③ 空船 + 没船长 → 真的补了一个（按需化没有砍掉这条功能 ✓）",
        COUNTS.captainHired == before + 1, tostring(COUNTS.captainHired))
    check("③ 补船长**不需要**造能力卡（getTurrets 不增加 ✓）",
        COUNTS.getTurrets == 3, tostring(COUNTS.getTurrets))

    -- 已经有船长了 → 不再补 ✓
    local after = COUNTS.captainHired
    Ops.updateServer()
    check("③ 已有船长 → 不重复补", COUNTS.captainHired == after, tostring(COUNTS.captainHired))
end

-- ---------------------------------------------------------------------------
-- ④ fleet：全忙的一轮**一次 Goal.describe 都不该调**（核心断言 ✓✓）
-- ---------------------------------------------------------------------------
print("== ④ fleet 扫描：没有船要决策时，一次 goal 都不算 ==")
do
    BUSY["Ship-A"], BUSY["Ship-B"], BUSY["Ship-C"] = true, true, true
    COUNTS.describe = 0
    COUNTS.getTurrets, COUNTS.sectorScans = 0, 0

    Fleet.scan()
    check("④ 全忙：Goal.describe 调用 **0** 次（旧版是 3 ✗）", COUNTS.describe == 0,
        tostring(COUNTS.describe))
    check("④ 全忙：没有顺带造能力卡（getTurrets = 0）", COUNTS.getTurrets == 0,
        tostring(COUNTS.getTurrets))
    check("④ 全忙：没有顺带扫本星区（sectorScans = 0）", COUNTS.sectorScans == 0,
        tostring(COUNTS.sectorScans))
    check("④ 全忙：下一轮仍会被当成'忙'（idleSeen=false）",
        Fleet.idleSeen["Ship-A"] == false, tostring(Fleet.idleSeen["Ship-A"]))
end

-- ---------------------------------------------------------------------------
-- ⑤ fleet：**只有真正要发 decide 的那一艘**才算 goal ✓
-- ---------------------------------------------------------------------------
print("== ⑤ fleet 扫描：空闲船才是唯一算 goal 的那条 ==")
do
    BUSY["Ship-A"], BUSY["Ship-B"], BUSY["Ship-C"] = false, true, true
    Fleet.idleSeen["Ship-A"] = false        -- 上一轮是忙的 → 这是"新的一轮空闲" ✓
    Fleet.decided["Ship-A"] = nil
    Fleet.inFlight["Ship-A"] = nil
    COUNTS.describe = 0
    COUNTS.getTurrets, COUNTS.sectorScans = 0, 0

    Fleet.scan()
    check("⑤ 1 艘空闲：Goal.describe 恰好 **1** 次（不是 3 ✗）", COUNTS.describe == 1,
        tostring(COUNTS.describe))
    check("⑤ 发起后记进 inFlight（不会每轮重发 ✓）", Fleet.inFlight["Ship-A"] ~= nil)
    check("⑤ 忙的两艘仍被记成忙", Fleet.idleSeen["Ship-B"] == false and Fleet.idleSeen["Ship-C"] == false)

    -- 同一轮空闲期内再来一轮扫描 → 冷却期内不再发、也不再算 goal ✓
    COUNTS.describe = 0
    Fleet.scan()
    check("⑤ 同一轮空闲期再扫：不重复发 decide（Goal.describe 仍 0 次 ✓）",
        COUNTS.describe == 0, tostring(COUNTS.describe))
end

-- ---------------------------------------------------------------------------
-- ⑥ 面板关着时 ops/fleet **仍然**按自己的节奏跑（它们与面板无关，这是设计 ✓）
-- ---------------------------------------------------------------------------
print("== ⑥ 周期任务与面板开关解耦（面板关着也照跑 —— 别把它们绑一起 ✗）==")
do
    VALUES["copilot_panel_visible"] = "closed"
    BUSY["Ship-A"] = true
    COUNTS.describe = 0
    local okScan = pcall(Fleet.scan)
    check("⑥ 面板 closed 时 fleet.scan 仍能正常跑（不依赖 UI ✓）", okScan, tostring(okScan))
    local okOps = pcall(Ops.updateServer)
    check("⑥ 面板 closed 时 ops.updateServer 仍能正常跑", okOps, tostring(okOps))
end

-- ---------------------------------------------------------------------------
-- ⑦ perf 探针本身（**它是排查工具，自己不能变成负载** ✓）
-- ---------------------------------------------------------------------------
print("== ⑦ perf 探针：亚阈值不写 / 超阈值才写 / 有节流 / 不吞错 ==")
do
    local Perf = include("copilot/perf")
    Perf.LOG_PATH = "build/_perf_selftest.log"
    os.remove(Perf.LOG_PATH)

    local function lineCount()
        local fh = io.open(Perf.LOG_PATH, "r")
        if fh == nil then return 0 end
        local n = 0
        for _ in fh:lines() do n = n + 1 end
        fh:close()
        return n
    end

    -- ① 亚阈值 → 一条都不写（这是"平时不刷屏"的硬保证 ✓）
    local t0 = os.clock()
    local ms = Perf.log("quick", t0, "x")
    check("⑦ 亚阈值：不建日志文件（平时一条都不写 ✓）", lineCount() == 0, tostring(lineCount()))
    check("⑦ 亚阈值：仍返回真实耗时（毫秒，number ✓）",
        type(ms) == "number" and ms >= 0 and ms < Perf.THRESHOLD_MS,
        type(ms) .. " " .. tostring(ms))

    -- ② 阈值调到 0 → 必写一条
    local oldThreshold, oldInterval = Perf.THRESHOLD_MS, Perf.MIN_INTERVAL
    Perf.THRESHOLD_MS, Perf.MIN_INTERVAL = 0, 30
    Perf.log("slow-a", os.clock(), "ships=6")
    check("⑦ 超阈值：写了一条", lineCount() == 1, tostring(lineCount()))

    -- ③ 立刻再写 → 被 30 秒节流挡住 ✓（哪怕一直超）
    Perf.log("slow-b", os.clock(), "ships=6")
    check("⑦ 节流：30 秒内第二条被挡住（不会刷屏 ✓）", lineCount() == 1, tostring(lineCount()))

    Perf.THRESHOLD_MS, Perf.MIN_INTERVAL = oldThreshold, oldInterval

    -- ④ wrap 不吞错（保持引擎原本的报错可见性 ✓）
    local boom = Perf.wrap("boom", function() error("kaboom") end)
    local okBoom, errBoom = pcall(boom)
    check("⑦ wrap 把异常**原样抛回去**（不许静默吞 ✗）",
        okBoom == false and tostring(errBoom):find("kaboom", 1, true) ~= nil, tostring(errBoom))

    -- ⑤ wrap 不改返回值
    local sum = Perf.wrap("sum", function(a, b) return a + b end)
    check("⑦ wrap 返回值不变", sum(2, 3) == 5, tostring(sum(2, 3)))

    os.remove(Perf.LOG_PATH)
    check("⑦ 测试用的日志文件已清理（不污染仓库 ✓）", io.open(Perf.LOG_PATH, "r") == nil)
end

-- ---------------------------------------------------------------------------
-- 汇总
-- ---------------------------------------------------------------------------
print("")
print(string.format("%d checks, %d failures", checks, failures))
if failures > 0 then os.exit(1) end
