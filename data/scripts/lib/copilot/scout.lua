package.path = package.path .. ";data/scripts/lib/?.lua"
-- copilot/scout —— 侦察的**纯事实**计算（不碰游戏 API ✓，可离线测 ✓✓）。
--
-- ★★ 设计原则（主人 2026-10-16 定的，最高优先 ✓✓）：
--   「把机制写清楚让决策 LLM 去判断该怎么做，而不是做成一个固定的脚本流程。」
--   → 本文件**只算事实** ✓：邻域里还有多少未探索、离中心多远、侦察一次多久 ✓
--   → ★ **绝不**产出"该不该挪位 / 挪到哪 / 下一步做什么" ✗✓（那是 LLM 的判断 ✓）
--   —— 所以这里没有 pickRelocation / decide / phase ✗，只有 survey 与几个数 ✓✓。
--
-- 背景机制（主人原话 ✓）：
--   侦察 = 开地图 ✓，需要**框区域**且**船必须在该区域内** ✓（scoutcommand.lua:428 ✓）；
--   一个位置周边开完之后，**用旅行挪到新位置再侦察** ✓ —— 但"开完了没、要不要挪"，
--   由 LLM 看事实自己判断 ✓✓。

local M = {}

-- ===========================================================================
-- ① 邻域覆盖度（事实 ✓）
-- ===========================================================================

-- isKnown(x, y) -> boolean ：★ 由调用方注入 ✓
--   游戏里就是 `player:getKnownSector(x, y) ~= nil` ✓
--   原版用法（证据）：orderchain.lua:887、factionmapsegment.lua:235、
--                     gatemapupdate.lua:141（getKnownSectors）、entitydbg.lua:3955 ✓
--
-- 返回 { unknown, known, total, half } —— ★ 只是**数** ✓，没有任何"所以该…" ✓✓
function M.survey(isKnown, cx, cy, half)
    half = math.floor(tonumber(half) or 10)
    cx, cy = math.floor(tonumber(cx) or 0), math.floor(tonumber(cy) or 0)

    local total, known, unknown = 0, 0, 0
    for y = cy - half, cy + half do
        for x = cx - half, cx + half do
            total = total + 1
            local ok, isK = pcall(isKnown, x, y)
            -- ★ 读不出来就**当成未知** ✓（保守 ✓、绝不崩 ✗）
            if ok and isK == true then known = known + 1 else unknown = unknown + 1 end
        end
    end

    return { unknown = unknown, known = known, total = total, half = half }
end

-- ===========================================================================
-- ② 两个简单事实 ✓
-- ===========================================================================

-- |x|+|y|：越小越靠地图中心 ✓（主人说明：越靠中心矿越高级、装备越好、也越危险 ✓）
function M.centreDistance(x, y)
    return math.abs(math.floor(tonumber(x) or 0)) + math.abs(math.floor(tonumber(y) or 0))
end

-- 侦察一次的时长（**原版自己算的** ✓ —— scoutcommand.lua:472 `duration = reachable / 25` ✓）
--   拿不到可达数就返回 nil ✓（**不猜** ✗）
function M.scoutDuration(reachable, reckleonBonus)
    local r = tonumber(reachable)
    if r == nil then return nil end
    local d = r / 25
    if tonumber(reckleonBonus) ~= nil then d = d + tonumber(reckleonBonus) end
    return d
end

-- ===========================================================================
-- 自检（harness 的 lua.exe 直接跑 ✓ 不需要游戏 ✓）
-- ===========================================================================

function M.selfTest()
    local allKnown = function() return true end
    local noneKnown = function() return false end
    local someKnown = function(x) return x <= 100 end
    local boom = function() error("boom") end

    local a = M.survey(noneKnown, 100, 100, 2)
    if a.total ~= 25 or a.unknown ~= 25 or a.known ~= 0 then
        return nil, "全未知: total=" .. tostring(a.total) .. " unknown=" .. tostring(a.unknown)
    end
    local b = M.survey(allKnown, 100, 100, 2)
    if b.total ~= 25 or b.unknown ~= 0 then
        return nil, "全已知: unknown 应为 0，实际 " .. tostring(b.unknown)
    end
    local c = M.survey(someKnown, 100, 100, 1)
    if c.total ~= 9 or c.unknown == 0 or c.unknown == 9 then
        return nil, "半开: 期望 0<unknown<9，实际 " .. tostring(c.unknown)
    end
    local d = M.survey(boom, 0, 0, 1)          -- ★ 注入的判据抛错 → 当未知 ✓，不崩 ✓
    if d.unknown ~= 9 then return nil, "isKnown 抛错时应全部记为未知，实际 " .. tostring(d.unknown) end

    if M.centreDistance(-3, 4) ~= 7 then return nil, "centreDistance 错" end
    if M.centreDistance(0, 0) ~= 0 then return nil, "中心应为 0" end
    if M.scoutDuration(400) ~= 16 then return nil, "duration 应为 400/25=16，实际 " .. tostring(M.scoutDuration(400)) end
    if M.scoutDuration(nil) ~= nil then return nil, "拿不到可达数应返回 nil（不猜 ✓）" end

    -- ★ 反向断言：本文件**不得**带有决策性 API ✗（主人的原则 ✓）
    for _, bad in ipairs({ "decide", "pickRelocation", "relocation" }) do
        if M[bad] ~= nil then return nil, "★ 出现决策性 API：" .. bad .. "（违反：只给事实）" end
    end

    return true
end

return M
