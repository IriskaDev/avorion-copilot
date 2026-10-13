package.path = package.path .. ";data/scripts/lib/?.lua"
package.path = package.path .. ";data/scripts/?.lua"

-- CopilotLinkOut —— **game → DSH** 方向的处理者。
--
-- 它是 CopilotNet 的监听者：net 说「连上了」「该上报了」，它才决定发什么。
-- 与 net/inbound、net/outbound 的分工：
--   net/*        —— 只管"怎么变成字节/怎么变回消息"（纯解析）
--   link_out.lua —— 管"什么时候发什么"（业务决策）
--   link_in.lua  —— 管"收到指令后怎么办"（业务处理）
--
-- 必须被 net.lua **include**（和泵同一个 VM），否则注册到的不是同一条事件总线。
--
-- 命名空间脚本：表不能清空
-- namespace CopilotLinkOut
CopilotLinkOut = CopilotLinkOut or {}

local self = CopilotLinkOut

self.reports = self.reports or 0
self.connectedAt = self.connectedAt or nil

-- 其它层（ops 大脑、命令）想主动上报时调它
function CopilotLinkOut.sendState(ships)
    local msg = CopilotOut.state(ships)
    local ok, err = CopilotOut.send(msg)
    if ok then
        self.reports = self.reports + 1
    else
        CopilotNet.emit("error", "state report failed: " .. tostring(err))
    end
    return ok, err
end

function CopilotLinkOut.install()
    if self.installed then return end
    self.installed = true

    -- 连上就握手：告诉对面我是游戏侧、协议版本多少
    CopilotNet.on("connected", function()
        self.connectedAt = os.time()
        local msg, err = CopilotOut.hello("game")
        if msg == nil then
            CopilotNet.emit("error", "hello build failed: " .. tostring(err))
            return
        end
        CopilotOut.send(msg)
    end)

    -- 断开时只记一笔，重连策略留给上层（传输层不管策略）
    CopilotNet.on("disconnected", function()
        self.connectedAt = nil
    end)
end

function CopilotLinkOut.status()
    return "out: reports=" .. tostring(self.reports)
        .. " connected=" .. tostring(self.connectedAt ~= nil)
end

return CopilotLinkOut
