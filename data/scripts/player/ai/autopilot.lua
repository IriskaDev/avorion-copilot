
package.path = package.path .. ";data/scripts/lib/?.lua"

-- Copilot: an autonomous "brain" attached to the player's current ship.
-- It orchestrates the game's own AI systems instead of reimplementing flight:
--   * combat  -> ShipAI():setAttack(nearest enemy)
--   * mining  -> the vanilla ai/mine.lua entity script
--   * salvage -> the vanilla ai/salvage.lua entity script
--   * travel  -> ShipAI():setJump(x, y)

-- Don't remove or alter the following comment, it tells the game the namespace this script lives in. If you remove it, the script will break.
-- namespace Copilot
Copilot = Copilot or {}   -- 热重载友好：不要清空表，否则运行状态与守卫会一起丢

local MINE_ADD = "ai/mine.lua"
local MINE_FULL = "data/scripts/entity/ai/mine.lua"
local SALVAGE_ADD = "ai/salvage.lua"
local SALVAGE_FULL = "data/scripts/entity/ai/salvage.lua"

Copilot.state = "idle"
Copilot.combatTargetId = nil

-- 是否已经从玩家手里接管过飞船。
-- 用一个标志位而不是每 tick 都设 autoPilotEnabled，是为了能区分
-- 「我们还没接管」和「接管后又被关掉了（= 玩家要自己开）」。
Copilot.tookControl = false

local function distSq(a, b)
    local dx = a.x - b.x
    local dy = a.y - b.y
    local dz = a.z - b.z
    return dx * dx + dy * dy + dz * dz
end

function Copilot.getUpdateInterval()
    return 2
end

function Copilot.initialize()
end

function Copilot.updateServer()
    if not onServer() then return end

    local player = Player()
    if not player then return end

    local craft = player.craft
    if not player:getValue("copilot_enabled") or not craft or not valid(craft) then
        Copilot.release(craft)
        Copilot.tookControl = false
        if Copilot.state ~= "idle" then
            Copilot.state = "idle"
            player:setValue("copilot_state", "idle")
        end
        Copilot.combatTargetId = nil
        return
    end

    -- 接管玩家正在开的船。
    --
    -- 这是**玩家显式打开**的行为：copilot_enabled 只由「Copilot 面板的开关」或
    -- /copilot on 写入，所以这里每 tick 设一次 autoPilotEnabled = true 并不会"和玩家抢"，
    -- 而是"按玩家的意愿持续保持接管"。要收回控制权，玩家关掉那个开关即可
    -- （/copilot off 或点面板上的按钮）。
    --
    -- 之前那种"玩家一按键就自动交还"的设计不做：需求是完全接管。
    -- 但**必须让玩家知道怎么收回**，否则会出现"飞船怎么点都不动"的困惑 —— 所以
    -- /copilot on 会发一条明确提示，HUD 上也有状态显示。
    -- Engage ONCE, not every tick.
--
-- The game's own HUD advertises "[Backspace] stop" for the autopilot. If we set
-- autoPilotEnabled = true on every tick, that stop is undone within 2 seconds and the
-- ship becomes uncontrollable ("nothing I press moves the ship").
-- Setting it once still means the AI fully takes over while the copilot is enabled -
-- the player simply keeps the game's own stop key as the way back.
local control = ControlUnit(craft)
    if control and not Copilot.tookControl then
        control.autoPilotEnabled = true
        Copilot.tookControl = true
    end

    local ai = ShipAI(craft)
    if not ai then return end

    Copilot.decide(player, craft, ai)
end

function Copilot.release(craft)
    if not craft or not valid(craft) then return end

    local control = ControlUnit(craft)
    if control then
        control.autoPilotEnabled = false
    end

    if craft:hasScript(MINE_FULL) then craft:removeScript(MINE_FULL) end
    if craft:hasScript(SALVAGE_FULL) then craft:removeScript(SALVAGE_FULL) end
end

function Copilot.decide(player, craft, ai)
    local sector = Sector()

    -- Combat is the top priority and is re-evaluated continuously so the ship
    -- keeps switching to the closest hostile as targets die.
    local faction = getParentFaction()
    local enemies = {}
    if faction then
        enemies = {sector:getEnemies(faction.index)}
    end

    if #enemies > 0 then
        Copilot.setState(player, "combat")
        Copilot.stopHarvest(craft)

        local target = Copilot.nearest(enemies, craft)
        if target then
            local targetId = target.id.string
            if Copilot.combatTargetId ~= targetId then
                Copilot.combatTargetId = targetId
                ai:setAttack(target)
            end
        else
            Copilot.combatTargetId = nil
            ai:setPassive()
        end
        return
    end

    Copilot.combatTargetId = nil
    Copilot.decideNonCombat(player, craft, ai, sector)
end

function Copilot.decideNonCombat(player, craft, ai, sector)
    -- If the hold is full, park and let the player handle the goods.
    local free = craft.freeCargoSpace
    if free ~= nil and free <= 0 then
        Copilot.setState(player, "full")
        Copilot.stopHarvest(craft)
        ai:setPassive()
        return
    end

    local mining = craft:getNumMiningTurrets() or 0
    local salvaging = craft:getNumSalvagingTurrets() or 0
    local armed = craft:getNumArmedTurrets() or 0

    -- 没有船长时**不要**去挂采矿/打捞 AI：挂了也会被游戏立刻踢掉，
    -- 然后我们每 tick 重试 -> 刷屏「需要一名船长」，玩家看到的就是
    -- 「飞船一直在启动自动采矿模式」。这里提前挡下。
    if mining > 0 and not Copilot.hasCaptain(craft) then
        Copilot.setState(player, "nocaptain")
        Copilot.stopHarvest(craft)
        ai:setPassive()
        return
    end

    if mining > 0 and Copilot.hasMineables(sector) then
        Copilot.setState(player, "mine")
        Copilot.ensureHarvest(craft, MINE_ADD, MINE_FULL, SALVAGE_FULL)
        return
    end

    if (salvaging > 0 or armed > 0) and Copilot.hasWreckage(sector) then
        Copilot.setState(player, "salvage")
        Copilot.ensureHarvest(craft, SALVAGE_ADD, SALVAGE_FULL, MINE_FULL)
        return
    end

    if player:getValue("copilot_explore") then
        Copilot.setState(player, "explore")
        Copilot.stopHarvest(craft)
        Copilot.tryJump(craft, ai)
    else
        Copilot.setState(player, "empty")
        Copilot.stopHarvest(craft)
        ai:setPassive()
    end
end

function Copilot.setState(player, newState)
    if Copilot.state == newState then return end
    Copilot.state = newState

    -- publish for the UI (data/scripts/player/ui/panel.lua); separate script VMs
    -- can only share data through player values, not by reading each other's tables
    player:setValue("copilot_state", newState)

    local msg
    if newState == "combat" then
        msg = "Copilot: engaging hostiles."
    elseif newState == "nocaptain" then
        msg = "Copilot: this ship needs a captain before it can mine or salvage."%_t
    elseif newState == "mine" then
        msg = "Copilot: mining asteroids."
    elseif newState == "salvage" then
        msg = "Copilot: salvaging wreckage."
    elseif newState == "full" then
        msg = "Copilot: cargo full, parking."
    elseif newState == "explore" then
        msg = "Copilot: jumping to a new sector."
    else
        msg = "Copilot: sector cleared, idling."
    end

    player:sendChatMessage("Server", ChatMessageType.Information, msg)
end

-- ★ 船长是硬门槛（LLM-OPS.md 记的实测结论）：所有后台命令都要求船上有船长。
--
-- 为什么必须在这里挡：原版采矿/打捞 AI 在没有船长时会**立刻自我移除**，
-- 而我们下一 tick 又会把脚本挂回去 —— 于是每 2 秒刷一次「需要一名船长」，
-- 玩家看到的现象就是「飞船一直在启动自动采矿模式」。先过门槛，循环就断了。
function Copilot.hasCaptain(craft)
    if craft.getCaptain == nil then return false end
    local ok, captain = pcall(function() return craft:getCaptain() end)
    return ok and captain ~= nil
end

function Copilot.ensureHarvest(craft, addScript, fullScript, otherFullScript)
    if otherFullScript and craft:hasScript(otherFullScript) then
        craft:removeScript(otherFullScript)
    end
    if not craft:hasScript(fullScript) then
        craft:addScriptOnce(addScript)
    end
end

function Copilot.stopHarvest(craft)
    if craft:hasScript(MINE_FULL) then craft:removeScript(MINE_FULL) end
    if craft:hasScript(SALVAGE_FULL) then craft:removeScript(SALVAGE_FULL) end
end

function Copilot.hasMineables(sector)
    local list = {sector:getEntitiesByComponent(ComponentType.MineableMaterial)}
    for _, a in pairs(list) do
        if a.type == EntityType.Asteroid then
            local r = a:getMineableResources()
            if r ~= nil and r > 0 then
                return true
            end
        end
    end
    return false
end

function Copilot.hasWreckage(sector)
    local list = {sector:getEntitiesByType(EntityType.Wreckage)}
    return #list > 0
end

function Copilot.nearest(entities, craft)
    local best = nil
    local bestDist = math.huge
    local p = craft.translationf
    for _, e in pairs(entities) do
        if valid(e) then
            local d = distSq(e.translationf, p)
            if d < bestDist then
                best = e
                bestDist = d
            end
        end
    end
    return best
end

function Copilot.tryJump(craft, ai)
    local x, y = Sector():getCoordinates()
    local dir = math.random(0, 3)
    local tx = x
    local ty = y
    if dir == 0 then
        tx = x + 1
    elseif dir == 1 then
        tx = x - 1
    elseif dir == 2 then
        ty = y + 1
    else
        ty = y - 1
    end

    if craft:jumpPossible(tx, ty) == 0 then
        ai:setJump(tx, ty)
    else
        ai:setPassive()
    end
end
