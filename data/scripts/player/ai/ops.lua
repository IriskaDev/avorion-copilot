package.path = package.path .. ";data/scripts/lib/?.lua"
package.path = package.path .. ";data/scripts/?.lua"

-- CopilotOps —— **战略指挥层**（玩家级脚本，挂在玩家身上）。
--
-- 职责边界（非常重要）：
--   * 只作用于**面板名单里的船**（player value `copilot_auto_ships` / `copilot_auto_cfg`）
--   * **绝不碰 `player.craft`** —— 替玩家开船是实体层（player/ai/autopilot.lua）的事
--   * 它负责：空闲检测 → 能力卡 → 补硬门槛 → 两段式下单 → 收割
--
-- ## API 全部经过实测或原版源码核对（第一版猜错两个，都被 pcall 接住了）
--
--   * 空闲判定：`player:getShipAvailability(name)` 与 `ShipAvailability.InBackground` 比
--     ★ 原版正统写法：`entitydbg.lua:3651`、`transfercrewgoods.lua:1944`
--     ✗ 不可用：`entry:getAvailability()` 返回的是**数字**（实测 avail=2），
--       拿数字去 find("InBackground") 必然判错
--   * 船长：`ShipDatabaseEntry:getCaptain()` —— ★ 实测在 **entry** 上可用（captain=yes）
--     ✗ 不可用：`entry:getNumMiningTurrets()`（这个名字不存在，实测 mine=nil）
--   * 炮塔：`{entity:getTurrets()}` —— ★ 原版 `entity.lua:100`，要拿**实体**而不是 entry
--   * 采矿能力：原版靠命令的 `getMiningProperties()` 的 `rawMining/refinedMining` 判
--     （`minecommand.lua:466`）→ 本层不重复实现，交给游戏自己的 isShipUsable 校验
--
-- 命名空间脚本：表不能清空，否则 /copilot reload 会失忆
-- namespace CopilotOps
CopilotOps = CopilotOps or {}

local self = CopilotOps

-- 每艘船/每个原因只报告一次，避免刷屏（今晚血的教训：每 tick 重试 = 刷屏风暴）
self.reported = self.reported or {}

-- ---------------------------------------------------------------------------
-- 工具箱
-- ---------------------------------------------------------------------------

-- 安全调用：成功 (true, 值...)，失败 (false, 错误)
local function probe(env, method, ...)
    if env == nil then return false, "nil object" end
    if env[method] == nil then return false, method .. " is nil" end
    local r = { pcall(env[method], env, ...) }
    if not r[1] then return false, tostring(r[2]) end
    return true, table.unpack(r, 2, #r)
end

-- 报告到聊天/客户端日志（本鱼的验证通道，不用敲聊天栏）
local function note(player, text)
    if player == nil then return end
    pcall(function()
        player:sendChatMessage("Server", ChatMessageType.Information, "[ops] " .. text)
    end)
end

-- ---------------------------------------------------------------------------
-- 名单
-- ---------------------------------------------------------------------------

function CopilotOps.designated(player)
    local names = {}
    for n in tostring(player:getValue("copilot_auto_ships") or ""):gmatch("[^\n]+") do
        if n ~= "" then table.insert(names, n) end
    end
    table.sort(names)
    return names
end

function CopilotOps.shipConfig(player, name)
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
-- 空闲判定（★ 用原版正统写法，不猜）
-- ---------------------------------------------------------------------------

-- 返回 (是否在忙, 原始值或错误信息)
function CopilotOps.isBusy(player, name)
    local ok, a = pcall(function() return player:getShipAvailability(name) end)
    if not ok then return nil, tostring(a) end
    if a == nil then return nil, "nil availability" end
    return (a == ShipAvailability.InBackground), tostring(a)
end

-- ---------------------------------------------------------------------------
-- 能力卡
-- ---------------------------------------------------------------------------

function CopilotOps.capabilityCard(player, name)
    local entry = ShipDatabaseEntry(player.index, name)
    if entry == nil then return nil, "no ShipDatabaseEntry" end

    local card = { name = name }

    local busy, avail = CopilotOps.isBusy(player, name)
    card.isBusy = busy
    card.availability = avail

    -- 船长：★ 实测在 entry 上可用
    local okC, captain = probe(entry, "getCaptain")
    card.hasCaptain = (okC and captain ~= nil)
    card.captainProbe = okC and "ok" or tostring(captain)

    -- 炮塔：原版在**实体**上取（entity.lua:100）。entry 上没有就只报探测结果，
    -- 不当硬判据用。
    local okT, turrets = probe(entry, "getTurrets")
    card.turretProbe = okT and "ok" or tostring(turrets)
    card.turretCount = okT and select("#", turrets) or nil

    return card
end

function CopilotOps.cardSummary(card)
    local t = {}
    t[#t + 1] = card.name
    t[#t + 1] = "busy=" .. tostring(card.isBusy) .. "(avail=" .. tostring(card.availability) .. ")"
    t[#t + 1] = "captain=" .. (card.hasCaptain and "yes" or ("no:" .. tostring(card.captainProbe)))
    t[#t + 1] = "turrets=" .. tostring(card.turretCount)
        .. ((card.turretProbe ~= "ok") and ("(" .. card.turretProbe .. ")") or "")
    return table.concat(t, "  ")
end

-- ---------------------------------------------------------------------------
-- 补硬门槛：船长（LLM-OPS.md：所有后台命令都要求船长）
-- ---------------------------------------------------------------------------

function CopilotOps.ensureCaptain(player, name, card)
    if card.hasCaptain then return true end

    local entry = ShipDatabaseEntry(player.index, name)
    if entry == nil then return false, "no entry" end

    local okGen, generator = pcall(function() return CaptainGenerator() end)
    if not okGen or generator == nil then
        return false, "CaptainGenerator unavailable: " .. tostring(generator)
    end

    local okNew, captain = pcall(function() return generator:generate() end)
    if not okNew or captain == nil then
        return false, "generate failed: " .. tostring(captain)
    end

    local okSet, err = pcall(function() return entry:setCaptain(captain) end)
    if not okSet then
        return false, "setCaptain failed: " .. tostring(err)
    end

    return true
end

-- ---------------------------------------------------------------------------
-- 主循环
-- ---------------------------------------------------------------------------

function CopilotOps.getUpdateInterval()
    return 5      -- 战略决策是秒级场景
end

function CopilotOps.updateServer()
    if not onServer() then return end

    local player = Player()
    if player == nil then return end

    local names = CopilotOps.designated(player)
    if #names == 0 then
        if not self.reported.empty then
            self.reported.empty = true
            note(player, "no ship designated - tick ships in the Copilot panel")
        end
        return
    end

    -- 玩家自己开的那条船永远不碰
    local piloted = player.craft
    local pilotedName = (piloted ~= nil and valid(piloted)) and piloted.name or nil

    for _, name in ipairs(names) do
        if name ~= pilotedName then
            local card, err = CopilotOps.capabilityCard(player, name)

            if card == nil then
                if not self.reported[name] then
                    self.reported[name] = true
                    note(player, name .. "  -> " .. tostring(err))
                end
            else
                -- 每艘船只报一次完整能力卡（本鱼的验证通道）
                if not self.reported[name] then
                    self.reported[name] = true
                    note(player, CopilotOps.cardSummary(card))
                end

                -- 空闲 + 没船长 → 补一个（硬门槛）
                if card.isBusy == false and not card.hasCaptain then
                    local ok, why = CopilotOps.ensureCaptain(player, name, card)
                    if ok then
                        note(player, name .. "  -> captain hired")
                    elseif not self.reported["cap:" .. name] then
                        self.reported["cap:" .. name] = true
                        note(player, name .. "  -> hiring failed: " .. tostring(why))
                    end
                end
            end
        end
    end
end

return CopilotOps
