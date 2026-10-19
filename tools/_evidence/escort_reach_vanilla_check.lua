-- escort_reach_vanilla_check.lua —— 2026-10-18
-- 目的：**直接执行原版函数**，验证「护航可用的距离条件 = 护航自己的 hyperspace reach」，
--       以及「不能穿裂隙者必须与行动船同环侧」。
--
-- 做法：dofile 原版 data/scripts/player/background/simulation/simulationutility.lua，
--       只把引擎全局（ShipDatabaseEntry / Galaxy / Balancing_InsideRing / %_t）换成替身，
--       然后调用真的 SimulationUtility.isShipUsableAsEscort。
--
-- 跑法：build/harness/lua.exe tools/_evidence/escort_reach_vanilla_check.lua
--
-- 实测输出（2026-10-18，Lua 5.2.3）：
--   distance 0 / 2.236 / 4.0（reach=4.1） -> nil（接受）
--   4.5 / 10                              -> TooFarAway
--   canPassRifts=false + 环侧不同          -> Unreachable
--   canPassRifts=true  + 环侧不同          -> nil（环侧被忽略）
--   10 远 + canPassRifts=true              -> TooFarAway（距离仍独立生效）

local VANILLA = "D:/SteamLibrary/steamapps/common/Avorion/data/scripts/player/background/simulation/simulationutility.lua"

-- ---- 引擎全局替身 ----
ShipAvailability = { Available = 0, InBackground = 2 }
EntityType = { Ship = 1 }
_t = {}
_T = {}
getmetatable("").__mod = function(a, b) return a end   -- 引擎的 %_t / %_T 翻译
function vec2(x, y) return { x = x, y = y } end
function distance2(a, b) local dx, dy = a.x - b.x, a.y - b.y; return dx * dx + dy * dy end
function valid(v) return v ~= nil end
function eprint(...) end
function include(name) return {} end
Galaxy = function() return { sectorInRift = function() return false end } end

local RING            -- Balancing_InsideRing(x,y) 的返回值（由各用例设置）
function Balancing_InsideRing(x, y) return RING end

-- ---- ShipDatabaseEntry 替身（只给护航船一条） ----
local DB = {}
function ShipDatabaseEntry(ownerIndex, name) return DB[name] end

local CANPASS = false
local EX, EY = -323, 4
local ESCORTER = {
    getHyperspaceProperties = function(self) return 4.1, CANPASS, 0, false end, -- reach, canPassRifts, cooldown, impaired
    getCoordinates          = function(self) return EX, EY end,
    getAvailability         = function(self) return ShipAvailability.Available end,
    getEntityType           = function(self) return EntityType.Ship end,
    getCaptain              = function(self) return {} end,
    getCrewRequirementsFulfilled = function(self) return true end,
    getEnergyProperties     = function(self) return 1, 2 end,                   -- required, produced（required < produced ✓）
    getDurabilityProperties = function(self) return 100, 1, 0, "", false end,
    getScripts              = function(self) return {} end,
}
DB["Combat-00001"] = ESCORTER

-- ---- owner 替身：被护航船固定在 (-324,6) ----
local owner = {
    index = 1,
    getShipPosition      = function(self, name) return -324, 6 end,
    getShipAvailability  = function(self, name) return ShipAvailability.Available end,
}

-- ---- 加载原版模块并执行真函数 ----
local SU = assert(dofile(VANILLA))
local E = SU.EscortError
assert(type(SU.isShipUsableAsEscort) == "function")

local fails = 0
local function expect(label, want)
    local e, secondary = SU.isShipUsableAsEscort(owner, "Combat-00001", "Salvager-00001")
    local got = "nil (ACCEPTED)"
    if e == E.TooFarAway then got = "TooFarAway"
    elseif e == E.Unreachable then got = "Unreachable"
    elseif e == E.Unusable then got = "Unusable (" .. tostring(secondary) .. ")"
    elseif e == E.Unavailable then got = "Unavailable" end
    local ok = got == want
    if not ok then fails = fails + 1 end
    print(string.format("  %s  %-56s -> %s (want %s)", ok and "PASS" or "FAIL", label, got, want))
end

-- 距离：reach = 4.1
EX, EY = -324, 6;     RING = false; expect("same sector (distance 0)", "nil (ACCEPTED)")
EX, EY = -323, 4;     RING = false; expect("2.236 sectors away (<= reach 4.1)", "nil (ACCEPTED)")
EX, EY = -320, 6;     RING = false; expect("4.0 sectors away (<= reach 4.1)", "nil (ACCEPTED)")
EX, EY = -319.5, 6;   RING = false; expect("4.5 sectors away (> reach 4.1)", "TooFarAway")
EX, EY = -314, 6;     RING = false; expect("10 sectors away", "TooFarAway")

-- 环侧：只看坐标的替身 —— 护航所在星区视作"环内"，行动船 (-324,6) 视作"环外"
Balancing_InsideRing = function(x, y) return (x == EX and y == EY) end
EX, EY = -323, 4;  CANPASS = false; expect("2.236 away, canPassRifts=false, OTHER ring side", "Unreachable")
CANPASS = true;                     expect("same + canPassRifts=true (ring ignored)", "nil (ACCEPTED)")
EX, EY = -314, 6;                   expect("10 away even with canPassRifts=true", "TooFarAway")

print(string.format("\n%d failure(s)", fails))
if fails > 0 then os.exit(1) end
