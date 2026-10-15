package.path = package.path .. ";data/scripts/lib/?.lua"
package.path = package.path .. ";data/scripts/?.lua"
-- copilotcard —— **舰队快照与能力卡的共享构造器**。
--
-- 为什么要有这个文件 ✗→✓：
--   `net/net.lua`（对外链路）和 `player/ai/ops.lua`（战略层）是**两个独立挂载的玩家脚本**
--   → **各自独立 VM** ✗ → 无法互相调用函数 ✗。
--   所以把两边都要用的「读游戏事实」的逻辑提到 lib/ ✓，各自 `include` 同一份 ✓✓。
--
-- 本文件是 **lib**：只能 `return` 命名空间表，**不许定义全局生命周期回调**
-- （否则会污染 include 它的脚本 ✓）。
--
-- ★ 只用**实测验证过**的 API（见 LLM-OPS.md 的实测纠正表）：
--   * 空闲：`player:getShipAvailability(name) == ShipAvailability.InBackground`
--   * 船长：`ShipDatabaseEntry:getCaptain()`  ← 在 entry 上可用（实测 ✓）
--   * ✗ 不要用 `entry:getAvailability()`（返回数字）
--   * ✗ 不要用 `entry:getNumMiningTurrets()`（不存在）
--   * 进度：`Simulation.getDescription(shipName)`（与游戏舰船页一致 ✓）
-- 一切不确定的调用都包 pcall ✓ —— 写错只记一条 probe 说明，绝不崩游戏 ✓。

local M = {}

-- ---------------------------------------------------------------------------
-- 小工具
-- ---------------------------------------------------------------------------

-- 安全调用：成功返回 (true, 值...)，失败返回 (false, 错误)
local function probe(obj, method, ...)
    if obj == nil then return false, "nil object" end

    -- ★★ 关键修复（真崩过一次 ✗→✓）
    --
    -- 之前写成：
    --     if obj[method] == nil then ... end      ← 这一步是**索引 userdata**
    --     local r = { pcall(obj[method], obj, ...) }
    -- pcall 只包住了"调用"，**没包住"查找"** ✗ —— 而按 AGENTS.md 的实测结论：
    -- userdata 上**拼错成员名会直接 AV**（不是返回 nil ✗），pcall 拦不住 ✓✓。
    --
    -- 2026-10-13 23:21:49 的 `Stacktrace Sender` 就是它 —— 服务端当场崩溃 ✓。
    --
    -- 正确写法：**查找与调用都放进 pcall 里** ✓。
    local args = { ... }
    local r = { pcall(function()
        local fn = obj[method]        -- 查找在 pcall 内 ✓
        if fn == nil then return nil, "member missing" end
        return fn(obj, table.unpack(args, 1, #args))
    end) }

    if not r[1] then return false, tostring(r[2]) end
    if r[2] == nil and r[3] == "member missing" then return false, method .. " is nil" end
    return true, table.unpack(r, 2, #r)
end

M.probe = probe

-- ---------------------------------------------------------------------------
-- 名单（两份 player value）
-- ---------------------------------------------------------------------------

-- `copilot_auto_ships`：换行分隔的船名（面板勾选的那些 ✓）
function M.designated(player)
    local names = {}
    for n in tostring(player:getValue("copilot_auto_ships") or ""):gmatch("[^\n]+") do
        if n ~= "" then table.insert(names, n) end
    end
    table.sort(names)
    return names
end

-- `copilot_auto_cfg`：每行 "船名|auto|target"
function M.shipConfig(player, name)
    local cfg = { auto = false, target = "" }
    for line in tostring(player:getValue("copilot_auto_cfg") or ""):gmatch("[^\n]+") do
        local n, a, t = line:match("^([^|]+)|([^|]*)|([^|]*)$")
        if n == name then
            cfg.auto = (a == "1")
            cfg.target = t or ""
            break
        end
    end
    return cfg
end

-- ---------------------------------------------------------------------------
-- 空闲判定（★ 原版正统写法，见 entitydbg.lua:3651）
-- ---------------------------------------------------------------------------

function M.isBusy(player, name)
    local ok, a = pcall(function() return player:getShipAvailability(name) end)
    if not ok then return nil, tostring(a) end
    if a == nil then return nil, "nil availability" end
    return (a == ShipAvailability.InBackground), a
end

-- ---------------------------------------------------------------------------
-- 单船快照（= 能力卡）
-- ---------------------------------------------------------------------------

function M.shipCard(player, name)
    local card = { name = name }
    local probeNotes = {}

    -- 空闲 / 是否被后台模拟接管
    local busy, avail = M.isBusy(player, name)
    if busy == nil then
        card.busy = nil
        probeNotes.availability = tostring(avail)
    else
        card.busy = busy
        card.availability = avail
    end

    local entry = ShipDatabaseEntry(player.index, name)
    if entry == nil then
        card.probe = probeNotes
        return card
    end

    -- 船长（★ 实测在 entry 上可用）
    local okC, captain = probe(entry, "getCaptain")
    if okC then
        card.hasCaptain = (captain ~= nil)
        if captain ~= nil then
            local okCls, cls = probe(captain, "getClass")
            if okCls and cls ~= nil then card.captainClass = tostring(cls) end
        end
    else
        probeNotes.captain = tostring(captain)
    end

    -- 进度描述（`Simulation.getDescription(shipName)` —— 与游戏舰船页显示同一句话）
    --
    -- ⚠️ 暂时不接 ✗：`include` 会**执行**目标文件，而 simulation 是游戏的后台模拟脚本 ✓。
    -- 即使包在 pcall 里，**副作用**也不是错误 ✗，拦不住 —— 有可能把游戏的模拟系统搅乱 ✓。
    -- 正确做法是先写一个**只读探针**确认"怎么拿到 Simulation 对象、getDescription 是否可调" ✓，
    -- 再决定接入方式 ✓。在那之前，诚实标记未接入 ✓，绝不硬猜 ✗。
    probeNotes.status = "not wired (needs a verified read-only probe for Simulation.getDescription)"

    -- ★★ 2026-10-15：补厚能力卡 —— 模型明确说缺这三样（原话见 rpc_dsh.log ✓）：
    --   「缺少当前星区、可贸易路线及船长职业信息，无法安全指派贸易任务。」
    -- 它是对的 ✗ —— 之前的卡片只有 busy/captain/status，模型没法决策 ✓。

    -- ① 船当前所在星区 ✓（决策的第一步：先知道它在哪 ✓）
    local okPos, px, py = pcall(function() return player:getShipPosition(name) end)
    if okPos and px ~= nil and py ~= nil then
        card.sector = { x = px, y = py }
    else
        probeNotes.position = tostring(px)
    end

    -- ② 船长职业 ✓（Trade 要求 Merchant ✓ —— 这个必须让模型看到 ✓）
    --    上面已经试过 captain:getClass()；这里再补一个显式的、便于模型读取的字段 ✓
    if card.captainClass ~= nil then
        card.captainClassKnown = true
    elseif card.hasCaptain == true then
        card.captainClassKnown = false
        probeNotes.captainClass = "has a captain but getClass() did not answer"
    end

    -- ③ 合法动作与它们的约束 ✓
    --    来源：LLM-OPS.md 的调研（四条后台命令的区域规则、船长要求、距离要求 ✓）
    --    ★ 形状故意做成**自解释**的，模型不用再猜 ✓
    card.actions = {
        Mine = {
            areaSize = { 15, 15 },
            shipMustBeInside = true,
            needsCaptain = true,
            note = "mining in a 15x15 sector area; the ship must already be inside it",
        },
        Salvage = {
            areaSize = { 15, 15 },
            shipMustBeInside = true,
            needsCaptain = true,
            note = "salvaging wrecks in a 15x15 sector area; ship must already be inside it",
        },
        Trade = {
            areaSize = { 29, 29 },
            shipMustBeInside = true,
            needsCaptain = true,
            captainClass = "Merchant",
            note = "trade route within a 29x29 area; ship must be inside it and the captain must be a Merchant",
        },
        Travel = {
            areaSize = { 1, 1 },
            shipMustBeInside = false,
            needsCaptain = true,
            minDistance = 2,
            note = "jump to one target sector; destination must be at least 2 jumps away",
        },
    }
    card.actionNames = { "Mine", "Salvage", "Trade", "Travel" }

    if next(probeNotes) ~= nil then card.probe = probeNotes end
    return card
end

-- ---------------------------------------------------------------------------
-- 舰队快照：只包含**名单里的船**，且**永不包含玩家自己开的那条** ✓
-- ---------------------------------------------------------------------------

function M.fleetSnapshot(player)
    local ships = {}
    local names = M.designated(player)

    -- 玩家自己开的船永远不碰（主人明确要求过 ✓）
    local piloted = player.craft
    local pilotedName = (piloted ~= nil and valid(piloted)) and piloted.name or nil

    for _, name in ipairs(names) do
        if name ~= pilotedName then
            ships[#ships + 1] = M.shipCard(player, name)
        end
    end

    return {
        ships = ships,
        designated = #names,
        piloted = pilotedName,
    }
end

-- ---------------------------------------------------------------------------
-- 我提供哪些 query 功能（给 rpc.caps / hello 用 ✓）
-- ---------------------------------------------------------------------------

M.WHATS = { "fleet", "ship", "caps" }

return M
