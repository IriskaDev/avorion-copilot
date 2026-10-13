-- Copilot mod: 玩家级挂载点（客户端 UI + 到 DSH 的链 + 自动驾驶大脑）。
--
-- 本文件由 VFS **追加**到原版 data/scripts/player/init.lua 末尾，
-- 所以不能抄原版内容、不能以 return 结尾。
--
-- 为什么挂玩家而不是星系：Copilot 是**每个玩家自己的**（名单、开关、连接都是 per-player）。
-- 挂星系会变成全服共享 —— 多人游戏里一个玩家的 copilot 会给所有人生效。
--
-- 为什么 net 链也挂这里（而不是星系级）：
--   玩家不在线时副驾驶本就不该替他下新决策；已下达的命令由游戏自身的后台模拟（BGS）
--   继续推进，不会停。推导：无人的专用服务器上本链不启动，这是**预期行为**。
if onServer() then
    local copilotPlayer = Player()

    copilotPlayer:addScriptOnce("ui/panel.lua")
    copilotPlayer:addScriptOnce("net/net.lua")
    copilotPlayer:addScriptOnce("ai/ops.lua")

    -- 兼容老存档：脚本曾叫 player/ai/copilot.lua，改名后游戏找不到它，会把它从
    -- 存档里的对象上**移除**（日志里那句 "Script will be removed ... to avoid
    -- further errors"）。但 player value 里的 copilot_enabled 仍然是 true，
    -- 于是出现「开关显示开着、船却不动」的坏状态。
    -- 这里按需把**新路径**挂回去，让老存档自愈。
    if copilotPlayer:getValue("copilot_enabled") then
        copilotPlayer:addScriptOnce("data/scripts/player/ai/autopilot.lua")
    end
end