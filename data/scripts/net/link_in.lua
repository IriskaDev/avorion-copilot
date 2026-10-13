package.path = package.path .. ";data/scripts/lib/?.lua"
package.path = package.path .. ";data/scripts/?.lua"

-- CopilotLinkIn —— **DSH → game** 方向的处理者。
--
-- 它是 CopilotNet 的监听者：net 收到消息 → CopilotIn 解包并按 cmd 再发事件 →
-- 这里按 cmd 分别处理。分工见 link_out.lua 顶部说明。
--
-- 必须被 net.lua **include**（和泵同一个 VM），否则收不到事件。
--
-- 命名空间脚本：表不能清空
-- namespace CopilotLinkIn
CopilotLinkIn = CopilotLinkIn or {}

local self = CopilotLinkIn

self.orders = self.orders or 0
self.lastOrder = self.lastOrder or nil

-- 各 cmd 的处理入口。真正的"执行指令"会转交给战略指挥层（player/ai/ops.lua），
-- 那是唯一有权对被指定的船下后台命令的地方。
function CopilotLinkIn.onOrder(msg)
    self.orders = self.orders + 1
    self.lastOrder = msg

    local params = msg.params or {}

    -- 战略层还没写：先记下来并回报"暂未执行"，绝不静默吞掉。
    -- 等 player/ai/ops.lua 就位后，这里改成把它转交给战略层执行。
    CopilotOut.send(CopilotOut.result(params.ship, false, "ops layer not wired yet"))
end

function CopilotLinkIn.onHello(msg)
    -- 对面报身份/版本。版本不一致时只说一句，不做别的（协议协商留到需要时再扩）
    local params = msg.params or {}
    if params.ver ~= 1 then
        CopilotNet.emit("error", "dsh side protocol ver=" .. tostring(params.ver) .. " (expected 1)")
    end
end

function CopilotLinkIn.install()
    if self.installed then return end
    self.installed = true

    CopilotNet.on("cmd:hello",  function(msg) CopilotLinkIn.onHello(msg) end)
    CopilotNet.on("cmd:order",  function(msg) CopilotLinkIn.onOrder(msg) end)
    CopilotNet.on("cmd:result", function(msg)
        if CopilotLinkIn.onResult ~= nil then CopilotLinkIn.onResult(msg) end
    end)
end

function CopilotLinkIn.status()
    local action = "none"
    if self.lastOrder ~= nil and self.lastOrder.params ~= nil then
        action = tostring(self.lastOrder.params.action or "none")
    end
    return "in: orders=" .. tostring(self.orders) .. " last=" .. action
end

return CopilotLinkIn
