
-- ★★ 实体级自动驾驶（autopilot）**已移除（2026-10-24）** ✓✓
--
-- 主人原话：「autopilot 这功能给去掉吧，感觉一时半会用不上的，留自动运营就行」
--
-- 本文件**保留为弃用空壳**，不再是大脑：
--   · 不定义 updateServer / getUpdateInterval / decide → 引擎不会再每 2 秒调用它 ✓
--   · 不读 player value `copilot_enabled` / `copilot_explore`（旧存档里的值也不删 ✓）
--   · 调用点已全部断开（`player/init.lua` 不再挂载、面板不再有开关）✓
--
-- 为什么不直接删文件 ✗：
--   旧存档把本脚本**挂在玩家对象上**（`Player:addScriptOnce`）；文件消失时引擎会在日志里
--   报 "Script will be removed ... to avoid further errors" 并把它从存档里剥掉。
--   留一个同路径、同 namespace 的空壳 = 老存档照常加载、零报错 ✓✓。
--
-- initialize 只做**一次**清理：把玩家船从旧的自动驾驶状态里放出来
-- （复位 autoPilotEnabled + 摘掉可能残留的 mine / salvage 实体脚本）。
-- 这是旧存档自愈，不是新功能；没有任何每 tick 行为 ✓。

-- Don't remove or alter the following comment, it tells the game the namespace this script lives in. If you remove it, the script will break.
-- namespace Copilot
Copilot = Copilot or {}   -- 热重载友好：不要清空表

Copilot.removedOn = "2026-10-24"

local MINE_FULL = "data/scripts/entity/ai/mine.lua"
local SALVAGE_FULL = "data/scripts/entity/ai/salvage.lua"

function Copilot.initialize()
    if not onServer() then return end

    local player = Player()
    if not player then return end

    local craft = player.craft
    if not craft or not valid(craft) then return end

    -- ★ 一次性自愈；任何一步失败都不许拦住玩家加载存档 ✓
    pcall(function()
        local control = ControlUnit(craft)
        if control then
            control.autoPilotEnabled = false
        end
        if craft:hasScript(MINE_FULL) then craft:removeScript(MINE_FULL) end
        if craft:hasScript(SALVAGE_FULL) then craft:removeScript(SALVAGE_FULL) end
    end)
end
