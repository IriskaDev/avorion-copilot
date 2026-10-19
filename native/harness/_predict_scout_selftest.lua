-- _predict_scout_selftest.lua —— 侦察覆盖原子（predict + action="Scout"）的离线自检 ✓ 2026-10-17
--
-- 不开游戏就能验：把游戏 API 全换成替身（run / command:calculatePrediction / getKnownSector ✓），
-- 然后**真的调** data/scripts/net/link_in.lua 里的 CopilotLinkIn.predict(player, {action="Scout", …}) ✓。
--
-- 覆盖（对应主人的规格 ✓）：
--   (a) 单框只算一框：run / calculatePrediction 恰好各 1 次 ✓
--   (b) 批量 N 只算 N 框：boxCount=N 且 run 恰好 N 次 ✓
--   (c) unknownCount==0 的框 → revealsNothingNew=true / hasUnknown=false（"揭不出新地图" ✓）
--   (d) unknownCount>0 的框 → revealsNothingNew=false / hasUnknown=true，且 unknown+known=total ✓
--   (e) getKnownSector 调用失败 → unreliable=true 且**绝不**误判成"揭不出新地图" ✓
--   (f) 框不含船 → 明确报错 SHIP_NOT_IN_AREA（单框 ok=false；批量标注该框、不中断整批 ✓）
--   (g) ★ 口径对拍：predict(Scout) 给某框的 unknownCount == legacy scoutPlan 里同一框的数 ✓
--        （两者共用 scanScoutArea / scoutSurveyArea —— 这条是防"将来有人重写其中一条"的回归锁 ✓）
--
-- 跑法（★ 必须在 mod 仓库根跑，脚本按相对路径读文件 ✓）：
--   build\harness\lua.exe native\harness\_predict_scout_selftest.lua

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
local nRun, nPred = 0, 0
-- ★ 「已探索」口径的可控替身（原版判据 player:getKnownSector(x,y) ~= nil → 已知 ✓）：
--   "ALL"      = 全部已知（unknownCount=0 ✓）
--   "STRIPE_Y" = 只有 y = SHIP_Y+6 那一行未探索（21x21 框吃到 21 个 ✓）
--   "NONE"     = 全部未探索（unknownCount=441 ✓）
--   "ERROR"    = getKnownSector 每次都抛错（→ 计数不可信 ✓）
local KNOWN = "ALL"
local function reset()
    nRun, nPred = 0, 0
    KNOWN = "ALL"
end

-- ---------------------------------------------------------------------------
-- 游戏 API 的替身 ✓
-- ---------------------------------------------------------------------------

CopilotRpc = { trace = function() end }

function run(factionIndex, shipName, ctype, area, callingPlayer)
    nRun = nRun + 1
    return shipName, ctype, area, {
        sectors = 441, reachable = 400, unreachable = 41,
        biggestFactionInArea = 1, reachableCoordinates = {}, offgridSectors = {},
    }, callingPlayer
end

local FAKE_COMMAND = {}

function FAKE_COMMAND:getAreaSize(ownerIndex, shipName)
    -- ★ 原版 ScoutCommand:getAreaSize → {21,21}（scoutcommand.lua:416 ✓）
    return { x = 21, y = 21 }
end

function FAKE_COMMAND:calculatePrediction(ownerIndex, shipName, area, config)
    nPred = nPred + 1
    return { attackChance = { value = 0.05 }, duration = 900, revealsOffgrid = 1 }
end

local FAKE_CARD = {
    shipCard = function(player, ship) return { sector = { x = SHIP_X, y = SHIP_Y } } end,
}

function include(name)
    if name == "areaanalysis" then return nil end          -- 真的也返回 nil（只定义全局 run ✓）
    if name == "commandfactory" then
        return { makeCommand = function(ctype) return FAKE_COMMAND end }
    end
    if name == "copilot/card" then return FAKE_CARD end
    if name == "copilot/scout" then return dofile("data/scripts/lib/copilot/scout.lua") end
    if name == "goods" then return {} end
    if name == "copilot/job" then return nil end
    error("unexpected include: " .. tostring(name))
end

function ShipDatabaseEntry(ownerIndex, name)
    return { getCoordinates = function() return SHIP_X, SHIP_Y end }
end

local player = { index = 1 }
_G.player = player            -- ★ include("copilot/scout") 里取的是全局 player ✓
player.getShipPosition = function(self, name) return SHIP_X, SHIP_Y end
player.getKnownSector = function(self, x, y)
    if KNOWN == "ALL" then
        return {}
    elseif KNOWN == "NONE" then
        return nil
    elseif KNOWN == "STRIPE_Y" then
        if y == SHIP_Y + 6 then return nil end
        return {}
    elseif KNOWN == "ERROR" then
        error("simulated getKnownSector failure")
    end
    return {}
end
function Player() return player end
function ShipAvailability() return { Available = 0 } end

local LinkIn = dofile("data/scripts/net/link_in.lua")

-- ---------------------------------------------------------------------------
-- (a) 单框只算一框 ✓
-- ---------------------------------------------------------------------------
print("== P1: 单框只算一框 ✓ ==")
reset()
local ok1, r1 = LinkIn.predict(player, {
    what = "predict", ship = SHIP, action = "Scout",
    x = SHIP_X, y = SHIP_Y, sizeX = 21, sizeY = 21,
})
check("P1 单框 ok=true", ok1 == true, r1)
if ok1 == true then
    check("P1 box.containsShip=true", r1.box.containsShip == true, r1.box.containsShip)
    check("P1 单框只算一框（run 恰好 1 次 ✓）", nRun == 1, nRun)
    check("P1 预测恰好 1 次 ✓", nPred == 1, nPred)
    check("P1 风险在（attackChance=0.05 ✓）", r1.risk and r1.risk.attackChance == 0.05, r1.risk and r1.risk.attackChance)
    check("P1 riskKind=scoutAmbushChance", r1.risk and r1.risk.riskKind == "scoutAmbushChance(whole task, this box)", r1.risk and r1.risk.riskKind)
end

-- ---------------------------------------------------------------------------
-- (b) 批量 N=2 只算 N 框 ✓
-- ---------------------------------------------------------------------------
print("== P2: 批量 N=2 只算 N 框 ✓ ==")
reset()
local ok2, r2 = LinkIn.predict(player, {
    what = "predict", ship = SHIP, action = "Scout",
    boxes = {
        { x = SHIP_X, y = SHIP_Y, sizeX = 21, sizeY = 21 },
        { x = SHIP_X + 4, y = SHIP_Y, sizeX = 21, sizeY = 21 },
    },
})
check("P2 批量 ok=true", ok2 == true, r2)
if ok2 == true then
    check("P2 boxCount=2", r2.boxCount == 2, r2.boxCount)
    check("P2 批量 N=2 只算 2 框（run 恰好 2 次 ✓）", nRun == 2, nRun)
    check("P2 每框独立（第 1 框含船 ✓）", r2.boxes[1] and r2.boxes[1].box.containsShip == true, "")
end

-- ---------------------------------------------------------------------------
-- (c) unknownCount==0 → 明确标记"揭不出新地图" ✓
-- ---------------------------------------------------------------------------
print("== P3: unknownCount==0 的框 → 揭不出新地图 ✓ ==")
reset()
KNOWN = "ALL"
local ok3, r3 = LinkIn.predict(player, {
    what = "predict", ship = SHIP, action = "Scout",
    x = SHIP_X, y = SHIP_Y, sizeX = 21, sizeY = 21,
})
check("P3 ok=true", ok3 == true, r3)
if ok3 == true then
    check("P3 unknownCount=0", r3.value and r3.value.unknownCount == 0, r3.value and r3.value.unknownCount)
    check("P3 knownCount=441 / totalSectors=441", r3.value and r3.value.knownCount == 441 and r3.value.totalSectors == 441,
        r3.value and (tostring(r3.value.knownCount) .. "/" .. tostring(r3.value.totalSectors)))
    check("P3 share=0", r3.value and r3.value.share == 0, r3.value and r3.value.share)
    check("P3 ★ revealsNothingNew=true（unknownCount==0 → 揭不出新地图 ✓）",
        r3.value and r3.value.revealsNothingNew == true, r3.value and r3.value.revealsNothingNew)
    check("P3 hasUnknown=false", r3.value and r3.value.hasUnknown == false, r3.value and r3.value.hasUnknown)
    check("P3 unreliable=false（计数可信 ✓）", r3.value and r3.value.unreliable == false, r3.value and r3.value.unreliable)
end

-- ---------------------------------------------------------------------------
-- (d) unknownCount>0 → 不是"揭不出新地图" ✓
-- ---------------------------------------------------------------------------
print("== P4: unknownCount>0 的框 ✓ ==")
reset()
KNOWN = "STRIPE_Y"
local ok4, r4 = LinkIn.predict(player, {
    what = "predict", ship = SHIP, action = "Scout",
    x = SHIP_X, y = SHIP_Y, sizeX = 21, sizeY = 21,
})
check("P4 ok=true", ok4 == true, r4)
if ok4 == true then
    check("P4 unknownCount=21（框内只有 SHIP_Y+6 那一行未探索 ✓）", r4.value and r4.value.unknownCount == 21, r4.value and r4.value.unknownCount)
    check("P4 unknownCount + knownCount == totalSectors ✓",
        r4.value and (r4.value.unknownCount + r4.value.knownCount == r4.value.totalSectors),
        r4.value and (tostring(r4.value.unknownCount) .. "+" .. tostring(r4.value.knownCount) .. "=" .. tostring(r4.value.totalSectors)))
    check("P4 revealsNothingNew=false", r4.value and r4.value.revealsNothingNew == false, r4.value and r4.value.revealsNothingNew)
    check("P4 hasUnknown=true", r4.value and r4.value.hasUnknown == true, r4.value and r4.value.hasUnknown)
end

-- ---------------------------------------------------------------------------
-- (e) getKnownSector 调用失败 → 计数不可信，绝不误判成"揭不出新地图" ✓
-- ---------------------------------------------------------------------------
print("== P5: 计数不可信（getKnownSector 抛错）✓ ==")
reset()
KNOWN = "ERROR"
local ok5, r5 = LinkIn.predict(player, {
    what = "predict", ship = SHIP, action = "Scout",
    x = SHIP_X, y = SHIP_Y, sizeX = 21, sizeY = 21,
})
check("P5 ok=true（预测照常 ✓）", ok5 == true, r5)
if ok5 == true then
    check("P5 unreliable=true（计数不可信 ✓）", r5.value and r5.value.unreliable == true, r5.value and r5.value.unreliable)
    check("P5 ★ 即使 unknownCount 看起来是 0，也**不**标 revealsNothingNew ✓",
        r5.value and r5.value.revealsNothingNew == false, r5.value and r5.value.revealsNothingNew)
    check("P5 hasUnknown=true（取不到数据 ≠ 没得揭 ✓）", r5.value and r5.value.hasUnknown == true, r5.value and r5.value.hasUnknown)
end

-- ---------------------------------------------------------------------------
-- (f) 框不含船 → 明确报错 SHIP_NOT_IN_AREA ✓（单框 ok=false；批量标注该框不中断 ✓）
-- ---------------------------------------------------------------------------
print("== P6: 框不含船 → SHIP_NOT_IN_AREA ✓ ==")
reset()
local ok6, code6 = LinkIn.predict(player, {
    what = "predict", ship = SHIP, action = "Scout",
    x = 0, y = 0, sizeX = 21, sizeY = 21,
})
check("P6 单框不含船 → ok=false + SHIP_NOT_IN_AREA", ok6 == false and code6 == "SHIP_NOT_IN_AREA", tostring(code6))
check("P6 不含船时不跑分析（run 0 次 ✓）", nRun == 0, nRun)

reset()
local ok6b, r6b = LinkIn.predict(player, {
    what = "predict", ship = SHIP, action = "Scout",
    boxes = {
        { x = 0, y = 0, sizeX = 21, sizeY = 21 },
        { x = SHIP_X, y = SHIP_Y, sizeX = 21, sizeY = 21 },
    },
})
check("P6 批量：不含船的框被标注 SHIP_NOT_IN_AREA（不中断整批 ✓）",
    ok6b == true and r6b.boxes[1].error == "SHIP_NOT_IN_AREA" and r6b.boxes[2].box.containsShip == true,
    r6b and tostring(r6b.boxes and r6b.boxes[1] and r6b.boxes[1].error))
check("P6 批量：只算含船的那一框（run 恰好 1 次 ✓）", nRun == 1, nRun)

-- ---------------------------------------------------------------------------
-- (g) ★ 口径对拍：predict(Scout) 某框 unknownCount == legacy scoutPlan 里同一框的数 ✓
-- ---------------------------------------------------------------------------
print("== P7: 与 legacy scoutPlan 对拍 ✓ ==")
reset()
KNOWN = "STRIPE_Y"
local okSP, rSP = LinkIn.scoutPlan(player, { ship = SHIP, maxAreas = 9 })
check("P7 scoutPlan ok=true（有 areaRanking ✓）", okSP == true and rSP ~= nil and type(rSP.areaRanking) == "table" and #rSP.areaRanking > 0,
    rSP and tostring(rSP.areasScanned))
local paired = 0
if okSP and type(rSP.areaRanking) == "table" then
    for _, e in ipairs(rSP.areaRanking) do
        local ex, ey = e.x, e.y
        if ex == nil or ey == nil then break end
        local okP, rP = LinkIn.predict(player, {
            what = "predict", ship = SHIP, action = "Scout",
            x = ex, y = ey, sizeX = 21, sizeY = 21,
        })
        if okP ~= true then
            check("P7 predict 对拍 ok=true @(" .. tostring(ex) .. "," .. tostring(ey) .. ")", false, rP)
            break
        end
        check("P7 对拍 @(" .. tostring(ex) .. "," .. tostring(ey) .. ") unknownCount 一致（" .. tostring(e.unknownCount) .. " ✓）",
            rP.value.unknownCount == e.unknownCount,
            tostring(rP.value.unknownCount) .. " vs " .. tostring(e.unknownCount))
        paired = paired + 1
        if paired >= 3 then break end   -- 对拍 3 个框就够证明共用同一段计算 ✓
    end
end
check("P7 至少对拍了 1 个框 ✓", paired >= 1, paired)

print("")
print(string.format("== 共 %d 项断言，失败 %d 项 ==", checks, failures))
if failures == 0 then
    print("predictScoutSelfTest: OK")
else
    print("predictScoutSelfTest: FAIL")
end
