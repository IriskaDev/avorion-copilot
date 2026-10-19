-- _scout_scan_selftest.lua —— Scout（勘察）离线自检 ✓ 2026-10-17
--
-- 不开游戏就能验：把游戏 API 全换成替身（run / command:calculatePrediction ✓），
-- 然后**真的调** data/scripts/net/link_in.lua 里的 CopilotLinkIn.scoutPlan ✓✓
--
-- 覆盖（每条都是**具体数字**、可手算 ✓）：
--   (a) revealsOffgrid 多者胜 ✓
--   (b) reveals 平手 → 离地图中心 (0,0) 更近者胜 ✓（|x|+|y| 更小 ✓）
--   (c) 超风险闸门 → acceptable=false 且**绝不进 recommendation** ✓
--   (d) 所有候选区域**必须含船** ✓（原版 isShipRequiredInArea = true，scoutcommand.lua:428 ✓）
--   (e) revealsOffgrid 拿不到时走退路：scoreBasis **写明**用的是可达星区数代理 ✓，
--       且排序仍按（揭示数或代理 → 离中心 → 风险）✓
--   (f) orderHint 可直接下单：ship / action=Scout / 绝对 x,y / size=21 / addCaptainsNote ✓
--       （尺寸证据 scoutcommand.lua:416 = {21,21} ✓；配置证据 :446 只有 addCaptainsNote ✓）
--   (g) 响应形状不变量：关键键都在 ✓、可 JSON 往返 ✓、退化情形（没区域/全失败）不报错 ✓
--
-- 跑法（★ 必须在 mod 仓库根跑，脚本按相对路径读文件 ✓）：
--   build\harness\lua.exe native\harness\_scout_scan_selftest.lua

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

local SHIP, SHIP_X, SHIP_Y = "Scout-00001", -412, 73
local GATE = 0.10
local nRun, nPred = 0, 0
local SPEC = {}          -- 区域偏移 "ox,oy" → { reveals=…, chance=…, duration=…, noReveals=true }
local CARD_SECTOR = { x = SHIP_X, y = SHIP_Y }
local UNKNOWN = nil      -- ★ 未探索区布置（nil = 全部已知 ✓；"TOPSTRIPE" / "SHIPROW" ✓）
local LAST_SHIP_Y = SHIP_Y

local function resetAll()
    nRun, nPred, SPEC = 0, 0, {}
    CARD_SECTOR = { x = SHIP_X, y = SHIP_Y }
    UNKNOWN = nil
end

local function offsetOfArea(area)
    local size = area.upper.x - area.lower.x + 1
    local half = math.floor((size - 1) / 2)
    return (area.lower.x + half) - SHIP_X, (area.lower.y + half) - SHIP_Y
end

-- ---------------------------------------------------------------------------
-- 游戏 API 的替身 ✓
-- ---------------------------------------------------------------------------

CopilotRpc = { trace = function() end }

function run(factionIndex, shipName, ctype, area, callingPlayer)
    nRun = nRun + 1
    local ox, oy = offsetOfArea(area)
    local key = ox .. "," .. oy
    local s = SPEC[key]
    if s == "ERROR" then error("simulated area analysis failure") end
    if type(s) ~= "table" then
        s = { reveals = 1, chance = 0.05, duration = 900 }
    end
    SPEC[key] = s
    local results = {
        probe = key,
        sectors = 441, reachable = 400, unreachable = 41,
        biggestFactionInArea = 1, reachableCoordinates = {},
        offgridSectors = {},
    }
    return shipName, ctype, area, results, callingPlayer
end

local FAKE_COMMAND = {}

function FAKE_COMMAND:getAreaSize(ownerIndex, shipName)
    -- ★ 原版 ScoutCommand:getAreaSize → {21,21}（scoutcommand.lua:416 ✓）
    return { x = 21, y = 21 }
end

function FAKE_COMMAND:isAreaFixed(ownerIndex, shipName)
    -- ★ 原版 ScoutCommand:isAreaFixed → false（scoutcommand.lua:434 ✓）
    return false
end

function FAKE_COMMAND:isShipRequiredInArea(ownerIndex, shipName)
    -- ★ 原版 ScoutCommand:isShipRequiredInArea → true（scoutcommand.lua:428 ✓）
    return true
end

function FAKE_COMMAND:calculatePrediction(ownerIndex, shipName, area, config)
    nPred = nPred + 1
    local key = (type(area.analysis) == "table") and area.analysis.probe or "?"
    local s = SPEC[key]
    if type(s) ~= "table" then
        return { attackChance = { value = 0 }, duration = 600, error = "nothing to scout here" }
    end
    local pred = {
        attackChance = { value = tonumber(s.chance) or 0 },
        duration = tonumber(s.duration) or 900,
    }
    -- ★ (e) 退路：故意**不给** revealsOffgrid，看 scoutPlan 会不会写明用了代理 ✓
    if s.noReveals ~= true then
        pred.revealsOffgrid = tonumber(s.reveals) or 0
    end
    return pred
end

local FAKE_CARD = {
    shipCard = function(player, ship) return { sector = { x = CARD_SECTOR.x, y = CARD_SECTOR.y } } end,
}

function include(name)
    if name == "areaanalysis" then return nil end          -- 真的也返回 nil（只定义全局 run ✓）
    if name == "commandfactory" then
        return { makeCommand = function(ctype) return FAKE_COMMAND end }
    end
    if name == "copilot/card" then return FAKE_CARD end
    if name == "copilot/scout" then return dofile("data/scripts/lib/copilot/scout.lua") end
    if name == "goods" then return {} end
    error("unexpected include: " .. tostring(name))
end

function ShipDatabaseEntry(ownerIndex, name)
    return { getCoordinates = function() return SHIP_X, SHIP_Y end }
end

local player = { index = 1 }
_G.player = player            -- ★ 全局同名一份 ✓：include("copilot/scout") 里的 `player.index` 取的是**全局** ✗✓
player.getShipPosition = function(self, name)
    LAST_SHIP_Y = SHIP_Y
    return SHIP_X, SHIP_Y
end
-- ★ 「已探索」替身（原版判据：player:getKnownSector(x,y) ~= nil → 已知 ✓）
--
--   ★★ 2026-10-17 起，Scout 的**主口径**变成"框里还剩多少未探索星区" ✓✓，
--      而"unknownCount = 0 的框**不许被推荐**"（主人要求 ✓ —— 那正是"她总 scout 同一块地方"的根 ✓）。
--      → 所以替身的默认状态**不能**是"全部已知" ✗（那会让所有框都 = 0 → 一个候选都不达标 ✓）。
--      → 默认给一个**围绕船的小未探索块**（3x3 = 9 个 ✓），这样：
--          · 所有旧断言（reveals/风险/含船/orderHint）**照旧成立** ✓
--          · 而且每个候选框的 unknownCount 都 ≥ 1 ✓（旧用例的语义不变 ✓）
--      需要精确数字的用例（S8a/b/c）用 `UNKNOWN` 覆盖成确定形状 ✓。
local KNOWN_OVERRIDE = false      -- 置 true 时：**全部已知** ✓（S8 之外的默认不走这条 ✓）
player.getKnownSector = function(self, x, y)
    KNOWN_CALLS = (KNOWN_CALLS or 0) + 1
    local view = {}
    if UNKNOWN == "TOPBAND" then
        -- 未探索 = 船那一行**及以上**的 3 行（y ∈ [SHIP_Y-2, SHIP_Y] ✓）：
        --   · 框心 y = -9/-10 的框，y 上界只有 74 → 吃到 0 个 ✓（"揭不出新地图"的框 ✓✓）
        --   · 框心 y = 0 的框 → 吃到全部 3x21 = **63** 个 ✓
        if y >= SHIP_Y - 2 and y <= SHIP_Y then view = nil end
    elseif UNKNOWN == "SHIPROW" then
        -- 未探索 = y = SHIP_Y+6（只有框心 y >= -4 的框才够得到它 → 心 -9/-10 的框吃到 0 ✓）
        if y == SHIP_Y + 6 then view = nil end
    elseif UNKNOWN == "STRIPE_LOW" then
        -- 未探索 = y = SHIP_Y-9（**偏下**一行：心 +9/+10 的框够不到 → unknownCount = 0 ✓）
        if y == SHIP_Y - 9 then view = nil end
    elseif not KNOWN_OVERRIDE then
        -- 默认：船周围的 3x3 未探索块 ✓（保证每个候选框都有 ≥1 个未探索 ✓）
        if math.abs(x - SHIP_X) <= 1 and math.abs(y - SHIP_Y) <= 1 then view = nil end
    end
    return view
end
function Player() return player end
function ShipAvailability() return { Available = 0 } end

local LinkIn = dofile("data/scripts/net/link_in.lua")
local JSON = dofile("data/scripts/lib/copilot/json.lua")

-- ---------------------------------------------------------------------------
-- (a) reveals 多者胜 ✓
-- ---------------------------------------------------------------------------
print("== S1: revealsOffgrid 多者胜 ✓ ==")
resetAll()
-- 扫描是 size=21、step=4 → half=10 → 偏移含 (0,0) ✓；给两个可预期的偏移布置数据
SPEC = {
    ["0,0"]  = { reveals = 1, chance = 0.05, duration = 900 },   -- 少 ✓
    ["4,0"]  = { reveals = 3, chance = 0.05, duration = 900 },   -- 多 ✓ → 应当胜出
}
local _, r1 = LinkIn.scoutPlan(player, { ship = SHIP, maxAreas = 9 })
if r1 and r1.areaRanking and r1.areaRanking[1] then
    local e = r1.areaRanking[1]
    print("  [dbg S1] unknownCount=" .. tostring(e.unknownCount) .. " hasUnknown=" .. tostring(e.hasUnknown)
        .. " reveals=" .. tostring(e.revealsLow) .. " chance=" .. tostring(e.attackChance)
        .. " acceptable=" .. tostring(e.acceptable) .. " boxTotal=" .. tostring(e.totalSectors)
        .. " unknownTable=" .. tostring(e.unknown and e.unknown.unknownCount))
end
check("S1 有推荐 ✓", type(r1) == "table" and r1.recommendation ~= nil, r1 and r1.note)
check("S1 推荐的是 reveals=3 那个 ✓（偏移 4,0 → 绝对 x=" .. (SHIP_X + 4) .. "）",
    r1 and r1.recommendation and r1.recommendation.revealsLow == 3,
    r1 and r1.recommendation and r1.recommendation.revealsLow)
check("S1 scoreBasis 写明用的是 revealsOffgrid ✓",
    r1 and type(r1.scoreBasis) == "string" and r1.scoreBasis:find("revealsOffgrid", 1, true) ~= nil,
    r1 and r1.scoreBasis)
check("S1 扫了 9 个区域以内且 > 0 ✓", r1 and r1.areasScanned and r1.areasScanned > 0 and r1.areasScanned <= 9, r1 and r1.areasScanned)
check("S1 orderHint 的 x/y = 推荐区域中心（绝对坐标 ✓）",
    r1 and r1.orderHint and r1.orderHint.x == SHIP_X + 4 and r1.orderHint.y == SHIP_Y,
    r1 and r1.orderHint and (tostring(r1.orderHint.x) .. "," .. tostring(r1.orderHint.y)))

-- ---------------------------------------------------------------------------
-- (b) reveals 平手 → 离地图中心更近者胜 ✓（worked example: A 3/20 vs B 1/5 → A；A B 都 2 → B）
-- ---------------------------------------------------------------------------
print("== S2: 平手时离地图中心更近者胜 ✓（手算例子 ✓）==")
resetAll()
-- 把船放在离中心较远处，让不同偏移的 |x|+|y| 明显不同 ✓
SHIP_X, SHIP_Y = 30, 30
CARD_SECTOR = { x = SHIP_X, y = SHIP_Y }
SPEC = {
    ["0,0"]  = { reveals = 3, chance = 0.05, duration = 900 },   -- 距中心 60 ✓（30+30）
    ["-8,0"] = { reveals = 1, chance = 0.05, duration = 900 },   -- 距中心 52 ✓
}
local _, rA = LinkIn.scoutPlan(player, { ship = SHIP, maxAreas = 9 })
check("S2 手算例子①: A(揭示3/距60) 胜过 B(揭示1/距52) ✓ → 主键优先 ✓",
    rA and rA.recommendation and rA.recommendation.revealsLow == 3,
    rA and rA.recommendation and rA.recommendation.revealsLow)

resetAll()
-- ★ 平手规则的**不依赖偏移网格**的写法 ✓✓：
--   本鱼一开始硬编码了 "-8,0"，但 scanOffsets 的步长不保证含 -8 ✗ → 断言测量的是别的东西 ✗。
--   改为：**所有**扫到的区域都给相同 reveals ✓ → 然后直接检查返回的 areaRanking 里，
--   同等 reveals 的条目**必须按距离升序** ✓✓（这才是那条规则本身 ✓）。
local sameReveals = {}
for k in pairs({}) do sameReveals[k] = nil end
local _, rB = LinkIn.scoutPlan(player, { ship = SHIP, maxAreas = 9 })
local prevDist, asc = nil, true
for _, e in ipairs(rB and rB.areaRanking or {}) do
    if e.acceptable then
        if prevDist ~= nil and (e.distance or 0) < prevDist then asc = false end
        prevDist = e.distance
    end
end
check("S2 手算例子②: reveals 平手时 → areaRanking 按**离中心距离升序** ✓✓",
    asc and prevDist ~= nil, tostring(asc) .. "/prev=" .. tostring(prevDist))
check("S2 推荐者就是达标里离中心最近的 ✓",
    rB and rB.recommendation and rB.areaRanking and rB.areaRanking[1]
        and rB.recommendation.distance == rB.areaRanking[1].distance,
    rB and rB.recommendation and rB.recommendation.distance)
SHIP_X, SHIP_Y = -412, 73
CARD_SECTOR = { x = SHIP_X, y = SHIP_Y }

-- ---------------------------------------------------------------------------
-- (c) 超闸门 → acceptable=false 且绝不推荐 ✓
-- ---------------------------------------------------------------------------
print("== S3: 风险闸门 ✓ ==")
resetAll()
SPEC = {
    ["0,0"] = { reveals = 99, chance = 0.25, duration = 900 },    -- 揭示最多但风险超标 ✗
    ["4,0"] = { reveals = 2,  chance = 0.05, duration = 900 },    -- 达标 ✓
}
local _, r3 = LinkIn.scoutPlan(player, { ship = SHIP, maxAreas = 9 })
check("S3 推荐的是达标那个 ✓（不是揭示最多的 ✗）",
    r3 and r3.recommendation and r3.recommendation.revealsLow == 2,
    r3 and r3.recommendation and r3.recommendation.revealsLow)
local foundBad = false
for _, e in ipairs(r3 and r3.areaRanking or {}) do
    if e.revealsLow == 99 then foundBad = true; check("S3 超闸门者 acceptable=false ✓", e.acceptable == false, tostring(e.acceptable)) end
end
check("S3 超闸门者确实在榜上（只是不可选 ✓）", foundBad, "not found")

resetAll()
-- ★ maxAreas=1：只扫**第一个**偏移（就是 (0,0) ✓）→ 这样"全部超标"才真的成立 ✓✓
--   （本鱼一开始用了 maxAreas=9 ✗ → 没被 SPEC 布置的其它区域落到默认 chance=0.05 ✓ → 有推荐 ✗，
--    断言测错了东西 ✗✓）
SPEC = { ["0,0"] = { reveals = 5, chance = 0.30, duration = 900 } }
local _, r3b = LinkIn.scoutPlan(player, { ship = SHIP, maxAreas = 1 })
check("S3 全部超标 → recommendation=nil ✓", r3b and r3b.recommendation == nil, r3b and tostring(r3b.recommendation))
check("S3 全部超标 → 有 riskWarning 说明原因 ✓",
    r3b and type(r3b.riskWarning) == "string" and #r3b.riskWarning > 0, r3b and r3b.riskWarning)

-- ---------------------------------------------------------------------------
-- (d) 所有候选区域必须含船 ✓（原版 :428 isShipRequiredInArea = true ✓）
-- ---------------------------------------------------------------------------
print("== S4: 区域必须含船 ✓ ==")
resetAll()
local _, r4 = LinkIn.scoutPlan(player, { ship = SHIP, maxAreas = 9 })
local allInside, n = true, 0
for _, e in ipairs(r4 and r4.areaRanking or {}) do
    n = n + 1
    local a = e.area
    local ok = a and SHIP_X >= a.lower.x and SHIP_X <= a.upper.x and SHIP_Y >= a.lower.y and SHIP_Y <= a.upper.y
    if not ok then allInside = false end
end
check("S4 每个候选区域都含船 ✓（检查了 " .. n .. " 个 ✓）", allInside and n > 0, tostring(allInside) .. "/n=" .. n)
check("S4 区域边长 = 21 ✓（原版 getAreaSize ✓）", r4 and r4.size == 21, r4 and r4.size)

-- ---------------------------------------------------------------------------
-- (e) 退路：revealsOffgrid 拿不到 → 用可达星区数当代理，并**写明** ✓
-- ---------------------------------------------------------------------------
print("== S5: revealsOffgrid 缺失时的退路 ✓ ==")
resetAll()
SPEC = { ["0,0"] = { noReveals = true, reveals = nil, chance = 0.05, duration = 900 } }
local _, r5 = LinkIn.scoutPlan(player, { ship = SHIP, maxAreas = 3 })
check("S5 退路生效：recommendation 仍在 ✓（代理值=可达星区数 400 ✓）",
    r5 and r5.recommendation ~= nil, r5 and r5.note)
check("S5 scoreBasis **写明**用的是代理 ✓✓",
    r5 and type(r5.scoreBasis) == "string" and r5.scoreBasis:lower():find("proxy", 1, true) ~= nil,
    r5 and r5.scoreBasis)
check("S5 代理值 = reachable(400) ✓",
    r5 and r5.recommendation and r5.recommendation.revealsLow == 400,
    r5 and r5.recommendation and r5.recommendation.revealsLow)

-- ---------------------------------------------------------------------------
-- (f) orderHint 可直接下单 ✓
-- ---------------------------------------------------------------------------
print("== S6: orderHint 可直接喂 order ✓ ==")
resetAll()
SPEC = { ["4,0"] = { reveals = 2, chance = 0.04, duration = 900 } }
local _, r6 = LinkIn.scoutPlan(player, { ship = SHIP, maxAreas = 9 })
local oh = r6 and r6.orderHint
check("S6 orderHint 存在 ✓", type(oh) == "table", oh)
check("S6 ship 对 ✓", oh and oh.ship == SHIP, oh and oh.ship)
check("S6 action=Scout ✓", oh and oh.action == "Scout", oh and oh.action)
check("S6 size=21 ✓（scoutcommand.lua:416 ✓）", oh and oh.size == 21, oh and oh.size)
check("S6 addCaptainsNote=true ✓（scoutcommand.lua:446 ✓ 它唯一的配置项 ✓）", oh and oh.addCaptainsNote == true, oh and tostring(oh and oh.addCaptainsNote))
check("S6 x/y 是**绝对**星区坐标 ✓", oh and oh.x == SHIP_X + 4 and oh.y == SHIP_Y, oh and (tostring(oh.x) .. "," .. tostring(oh.y)))

-- ---------------------------------------------------------------------------
-- (g) 形状不变量 + 退化情形不报错 ✓
-- ---------------------------------------------------------------------------
print("== S7: 形状与退化 ✓ ==")
resetAll()
SPEC = { ["0,0"] = { reveals = 2, chance = 0.05, duration = 900 } }
local ok7, r7 = LinkIn.scoutPlan(player, { ship = SHIP, maxAreas = 1 })
check("S7 正常返回 ok=true ✓", ok7 == true, tostring(ok7))
for _, k in ipairs({ "ship", "action", "areaRanking", "areasScanned", "scanMs", "size", "maxAttackChance" }) do
    check("S7 关键键存在: " .. k .. " ✓", r7 and r7[k] ~= nil, k)
end
local enc = JSON.encode(r7)
local dec = JSON.decode(enc)
check("S7 响应可 JSON 往返 ✓", type(dec) == "table" and dec.action == "Scout", type(dec))
check("S7 往返后 areaRanking 仍在 ✓", dec and type(dec.areaRanking) == "table" and #dec.areaRanking >= 1, enc and #enc)

resetAll()
local ok8a, r8a = LinkIn.scoutPlan(player, { ship = SHIP, maxAreas = 1 })
check("S7 退化①：完全没有区域数据也不报错 ✓（仍返回 ok ✓）", ok8a == true, tostring(ok8a))
local ok8b, r8b = LinkIn.scoutPlan(player, { ship = SHIP })
check("S7 退化②：不带 maxAreas 也能跑 ✓", ok8b == true and r8b ~= nil, tostring(ok8b))
local ok8c, code8c = LinkIn.scoutPlan(player, {})
check("S7 退化③：缺 ship → BAD_REQUEST ✓", ok8c == false and code8c == "BAD_REQUEST", tostring(code8c))

-- 分析炸掉的区域不许中断整轮 ✓
resetAll()
SPEC = { ["0,0"] = "ERROR", ["4,0"] = { reveals = 3, chance = 0.05, duration = 900 } }
local ok9, r9 = LinkIn.scoutPlan(player, { ship = SHIP, maxAreas = 9 })
check("S7 退化④：某区域分析抛错 → 整轮不崩 ✓ 且仍能推荐好的那个 ✓",
    ok9 == true and r9 and r9.recommendation and r9.recommendation.revealsLow == 3,
    r9 and r9.recommendation and r9.recommendation.revealsLow)

-- 源码结构断言：Scout 的 UUID 与实读一致 ✓ + 尺寸 21 ✓
local fh = io.open("data/scripts/net/link_in.lua", "rb")
local src = fh and fh:read("*a") or ""
if fh then fh:close() end
check("S7 源码里的 Scout UUID 与实读 commandtype.lua 一致 ✓✓",
    src:find("7619ca9c-3f26-4b89-a4a4-10fd9aca5c60", 1, true) ~= nil)
check("S7 源码里 DEFAULT_SIZE.Scout = 21 ✓", src:find("Scout = 21", 1, true) ~= nil)
check("S7 调用次数：run=" .. nRun .. " / calculatePrediction=" .. nPred .. "（两阶段有界 ✓）",
    nRun <= 142 and nPred <= 142 * 2)

-- ---------------------------------------------------------------------------
-- ★★ S8：未知星区计数（主人 2026-10-17 要求 ✓✓）
--   "她总是 scout 同一块地方" —— 根因：原版只给 revealsOffgrid（**枚举 0/1/2** ✗，太粗），
--   于是"这块地方已经没得揭了"在数字上看不出来 ✗。
--   → 现在每个候选框都数 unknownCount（框内 player:getKnownSector(x,y)==nil 的个数 ✓），
--     并且**主键换成它** ✓（枚举仍是次键 ✓，旧字段不删 ✓✓）。
-- ---------------------------------------------------------------------------
print("== S8: 逐框未探索数（unknownCount）是主口径 ✓ ==")

-- (a) 其他都一样时：未探索多的框胜 ✓
resetAll()
UNKNOWN = "SHIPROW"             -- 未探索 = y = SHIP_Y+6 那一行 ✓（见下：谁能吃到它有讲究 ✓）
DBG_LINKIN = true
DBG_N = 0
SPEC = {
    ["0,0"]  = { reveals = 2, chance = 0.05, duration = 900 },   -- 吃到 3x21=63 个未探索 ✓
    ["0,-9"] = { reveals = 2, chance = 0.05, duration = 900 },   -- 吃到 1x21=21 个 ✓
    ["0,9"]  = { reveals = 2, chance = 0.05, duration = 900 },   -- 吃到 0 个 ✓
}
local _, r8a = LinkIn.scoutPlan(player, { ship = SHIP, maxAreas = 9 })
check("S8a ok ✓", r8a ~= nil)
if r8a ~= nil then
    -- ★★ 结构性不变量（2026-10-17 加 ✓✓ —— 它当场抓出了"偏移加了两次"的 bug ✗→✓）：
    --   每个候选框的**几何中心**必须等于 `centre`（= x/y 绝对坐标 ✓），
    --   而且 `centre − 船的星区` 必须等于 `offset` ✓✓。
    --   只靠"框含船"是**抓不到**偏移错位的 ✗（错位的框照样含船 ✓）。
    check("S8a ★ 不变量：框心 = centre = (x,y)，且 centre − 船位 = offset ✓✓",
        (function()
            for _, e in ipairs(r8a.areaRanking or {}) do
                local a = e.area
                local w = a.upper.x - a.lower.x + 1
                local h = a.upper.y - a.lower.y + 1
                local cxx = a.lower.x + math.floor((w - 1) / 2)
                local cyy = a.lower.y + math.floor((h - 1) / 2)
                if cxx ~= e.centre.x or cyy ~= e.centre.y then return false end
                if e.x ~= cxx or e.y ~= cyy then return false end
                if e.offset.x ~= cxx - SHIP_X or e.offset.y ~= cyy - SHIP_Y then return false end
            end
            return true
        end)())
    local rec = r8a.recommendation
    -- ★★ 主断言（不依赖任何"我以为"的手算 ✗）：推荐的那个框必须是**未探索最多**的 ✓✓
    local maxU, zeroU, mine = -1, 0, nil
    for _, e in ipairs(r8a.areaRanking or {}) do
        local u = tonumber(e.unknownCount) or 0
        if u > maxU then maxU, mine = u, e end
        if u == 0 then zeroU = zeroU + 1 end
    end
    check("S8a 推荐框的 unknownCount **等于全场最大** ✓（就是未探索最多那个 ✓✓）",
        rec ~= nil and rec.unknownCount == maxU, rec and (tostring(rec.unknownCount) .. " vs max " .. tostring(maxU)))
    check("S8a 最大未探索数 > 0 ✓（真的数出东西了 ✓）", maxU > 0, maxU)
    check("S8a 有框吃到 0 个未探索 ✓（说明这个测试真的在比数，不是在比常量 ✓✓）", zeroU > 0, zeroU)
    check("S8a 每个候选框都带 unknownCount / knownCount / totalSectors ✓",
        (function()
            for _, e in ipairs(r8a.areaRanking or {}) do
                if type(e.unknownCount) ~= "number" or type(e.knownCount) ~= "number"
                    or e.totalSectors ~= 441
                    or e.unknownCount + e.knownCount ~= 441 then return false end
            end
            return true
        end)())
    check("S8a unknownCount 与逐框 unknown 子表一致 ✓",
        (function()
            for _, e in ipairs(r8a.areaRanking or {}) do
                if type(e.unknown) ~= "table" or e.unknown.unknownCount ~= e.unknownCount then
                    return false
                end
            end
            return true
        end)())
    -- ★ 推荐框必须真的够得到那个未探索点（y ∈ [SHIP_Y-2, SHIP_Y+6] 之内 ✓）—— 用坐标判 ✓
    check("S8a 推荐框确实含那个未探索点 ✓（y 范围覆盖 SHIP_Y+6 ✓）",
        rec ~= nil and rec.area.lower.y <= SHIP_Y + 6 and rec.area.upper.y >= SHIP_Y + 6,
        rec and (tostring(rec.area.lower.y) .. ".." .. tostring(rec.area.upper.y)))
    check("S8a 推荐的 x/y 是**绝对星区坐标**（= 框心 ✓，模型不做算术 ✓）",
        rec ~= nil and rec.x ~= nil and rec.y ~= nil
        and rec.x == rec.centre.x and rec.y == rec.centre.y,
        rec and (tostring(rec.x) .. "," .. tostring(rec.y)))
end

-- (b) unknownCount = 0 的框**绝不**在还有 nonzero 框时被推荐 ✓
resetAll()
UNKNOWN = "STRIPE_LOW"          -- 未探索 = y = SHIP_Y-9 那一行 → 只有**偏下**的框够得到它 ✓
SPEC = {
    -- (0,-9)：y∈[54,74] 含 SHIP_Y-9=64 ✓ → 有未探索（1 个 ✓）
    ["0,-9"]  = { reveals = 2, chance = 0.05, duration = 900 },
    -- (0,9)：y∈[72,92] 不含 64 ✗ → unknownCount = 0，而且**风险一样低** ✓（正是要防的那种"看似最优" ✓）
    ["0,9"]   = { reveals = 2, chance = 0.05, duration = 900 },
}
local _, r8b = LinkIn.scoutPlan(player, { ship = SHIP, maxAreas = 9 })
check("S8b ok ✓", r8b ~= nil)
if r8b ~= nil then
    local rec = r8b.recommendation
    check("S8b 推荐框的 unknownCount > 0 ✓（零未探索的框即使风险更低也不推荐 ✓✓）",
        rec ~= nil and (rec.unknownCount or 0) > 0, rec and rec.unknownCount)
    check("S8b 零未探索的框标了 revealsNothingNew / hasUnknown=false ✓",
        (function()
            local n = 0
            for _, e in ipairs(r8b.areaRanking or {}) do
                if e.unknownCount == 0 then
                    n = n + 1
                    if e.revealsNothingNew ~= true or e.hasUnknown ~= false then return false end
                end
            end
            return n > 0
        end)())
    check("S8b 顶层给了 neighbourhood 事实（船邻域未探索数 + 候选框分布 ✓，**只是数字** ✓）",
        r8b.neighbourhood ~= nil and type(r8b.neighbourhood.unknown) == "number"
        and type(r8b.neighbourhood.candidateBoxesWithZeroUnknown) == "number",
        r8b.neighbourhood and JSON.encode({ u = r8b.neighbourhood.unknown,
            z = r8b.neighbourhood.candidateBoxesWithZeroUnknown }))
end

-- (c) 枚举不再是主键：**未探索多但枚举低**的框要赢过"未探索少但枚举高"的 ✓
resetAll()
UNKNOWN = "STRIPE_LOW"          -- 未探索 = y = SHIP_Y-9 那一行 → **偏上的框**够不到（unknownCount=0 ✓）
SPEC = {
    ["0,9"] = { reveals = 2, chance = 0.05, duration = 900 },     -- 枚举最高(2)，但 y∈[72,92] 吃不到 → 0 ✗
    ["0,0"] = { reveals = 1, chance = 0.05, duration = 900 },     -- 枚举低(1)，但 y∈[63,83] 吃到那一行 = 21 ✓
}
local _, r8c = LinkIn.scoutPlan(player, { ship = SHIP, maxAreas = 9 })
check("S8c ok ✓", r8c ~= nil)
if r8c ~= nil then
    local rec = r8c.recommendation
    check("S8c 旧的枚举口径**再也藏不住**更该去的框 ✓（未探索多者胜 ✓✓）",
        rec ~= nil and (rec.unknownCount or 0) > 0 and rec.revealsOffgridEnum == 1,
        rec and (tostring(rec.unknownCount) .. " / enum " .. tostring(rec.revealsOffgridEnum)))
    check("S8c 那个枚举最高但没得揭的框（revealsOffgridEnum=2）unknownCount = 0 ✓",
        (function()
            for _, e in ipairs(r8c.areaRanking or {}) do
                if e.revealsOffgridEnum == 2 and e.unknownCount ~= 0 then return false end
            end
            return true
        end)(), rec and rec.unknownCount)
    check("S8c 枚举字段仍然保留并写明含义 ✓（旧字段不删 ✓）",
        rec ~= nil and type(rec.revealsOffgridMeaning) == "string"
        and rec.revealsOffgridMeaning:find("枚举", 1, true) ~= nil,
        rec and rec.revealsOffgridMeaning)
end

-- (d) 时间预算 ✓（软预算：只在框之间检查 ✓）
resetAll()
UNKNOWN = "TOPSTRIPE"
SPEC = { ["0,0"] = { reveals = 2, chance = 0.05, duration = 900 } }
local _, r8d = LinkIn.scoutPlan(player, { ship = SHIP, maxScanMs = 1 })
check("S8d ok=true（预算极小时也不炸 ✓）", r8d ~= nil)
if r8d ~= nil then
    check("S8d 报了 scan.budgetMs ✓", r8d.scan and r8d.scan.budgetMs == 1,
        r8d.scan and r8d.scan.budgetMs)
    check("S8d 报了 scanMs ✓", type(r8d.scanMs) == "number", r8d.scanMs)
    check("S8d 至少还是粗扫了第一个框 ✓", r8d.areasScanned >= 1, r8d.areasScanned)
end

print("")
print(string.format("== 共 %d 项断言，失败 %d 项 ==", checks, failures))
if failures == 0 then
    print("scoutScanSelfTest: OK")
else
    print("scoutScanSelfTest: FAIL")
end
