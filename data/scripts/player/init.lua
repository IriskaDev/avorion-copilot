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
    -- ★ 第二轮二分：连 RPC 链也停掉 ✓（上一轮证明自动驾驶不是原因 ✗）
    --   若这样就不死 → RPC 链有问题；若还死 → 与本 mod 全部无关 ✓
    -- copilotPlayer:addScriptOnce("net/net.lua")
    copilotPlayer:addScriptOnce("ai/ops.lua")

    -- 兼容老存档：脚本曾叫 player/ai/copilot.lua，改名后游戏找不到它，会把它从
    -- 存档里的对象上**移除**（日志里那句 "Script will be removed ... to avoid
    -- further errors"）。但 player value 里的 copilot_enabled 仍然是 true，
    -- 于是出现「开关显示开着、船却不动」的坏状态。
    -- 这里按需把**新路径**挂回去，让老存档自愈。
    -- ★ 排查用：暂时不挂载实体自动驾驶（唯一会 addScriptOnce/removeScript 的层）
    --
    -- 起因：2026-10-14 00:23:51 服务端进程消失，日志最后一行是
    --   `Entity with index … has no script with index '6'`
    -- 紧跟在游戏自己的 `Restoring 1's craft`（恢复刚跑完后台命令的船）之后。
    -- 形态是"无崩溃报告、无关闭消息、戛然而止"。
    --
    -- 二分法：这一层是唯一会挂/卸**实体脚本**的地方 ✓，先关掉它 ✓，保留 RPC 链（不挂脚本 ✓）。
    --   若不再崩 → 问题在这条线（addScriptOnce/removeScript 的用法）
    --   若仍崩   → 问题在游戏自身的后台命令恢复流程
    -- 恢复方式：把下面两行的注释去掉即可 ✓
    --
    -- if copilotPlayer:getValue("copilot_enabled") then
    --     copilotPlayer:addScriptOnce("data/scripts/player/ai/autopilot.lua")
    -- end
end