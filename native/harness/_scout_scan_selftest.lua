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
--   native\harness\lua.exe native\harness\_scout_scan_selftest.lua

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

local function resetAll()
    nRun, nPred, SPEC = 0, 0, {}
    CARD_SECTOR = { x = SHIP_X, y = SHIP_Y }
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
    if name == "copilotcard" then return FAKE_CARD end
    if name == "goods" then return {} end
    error("unexpected include: " .. tostring(name))
end

function ShipDatabaseEntry(ownerIndex, name)
    return { getCoordinates = function() return SHIP_X, SHIP_Y end }
end

local player = { index = 1 }
function Player() return player end
function ShipAvailability() return { Available = 0 } end

local LinkIn = dofile("data/scripts/net/link_in.lua")
local JSON = dofile("data/scripts/lib/copilotjson.lua")

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
check("S7 调用次数：run=" .. nRun .. " / calculatePrediction=" .. nPred .. "（有界 ✓）", nRun <= 9 and nPred <= 9 * 2)

print("")
print(string.format("== 共 %d 项断言，失败 %d 项 ==", checks, failures))
if failures == 0 then
    print("scoutScanSelfTest: OK")
else
    print("scoutScanSelfTest: FAIL")
end
