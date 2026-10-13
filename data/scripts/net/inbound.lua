package.path = package.path .. ";data/scripts/lib/?.lua"
package.path = package.path .. ";data/scripts/?.lua"
-- CopilotIn —— **入站数据流解析**（DSH → game 方向）。
--
-- 职责边界：把 CopilotNet 吐出来的**原始文本**变成**结构化消息**，并按 cmd 再发一层事件。
--   * **不做业务处理**（收到 order 之后要干什么，是 commands/ 下监听者的事）
--
-- 它自己就是 CopilotNet 的一个监听者：net 说"来了一条消息"，它就解包并转发。
-- 于是整个链路是分层的、事件驱动的：
--
--   DLL(tick 泵) → CopilotNet.emit("message", 原始文本)
--                    → CopilotIn 解包 → emit("cmd:order", 消息表)
--                                       → commands/ 下的监听者处理
--
-- 命名空间脚本：表不能清空
-- namespace CopilotIn
CopilotIn = CopilotIn or {}

local self = CopilotIn

-- 统计与诊断（先留着，等 /copilot ops 服役后可以精简）
self.received = self.received or 0
self.failed = self.failed or 0
self.last = self.last or nil

-- 原始文本 -> 消息表。失败返回 nil, err（**不抛错**：坏帧不能拖垮脚本）
function CopilotIn.decode(text)
    local ok, cp = pcall(require, "copilot")
    if not ok or type(cp) ~= "table" or cp.decode == nil then
        return nil, "native module 'copilot' unavailable"
    end
    local msg = cp.decode(text)
    if type(msg) ~= "table" then
        return nil, "not a JSON object"
    end
    -- 协议 v2：信封必须有 id / type / cmd（§2 铁律 5）。缺了就当坏帧丢掉 ✓，
    -- 不在这里回 error —— 回 error 需要 transport 协调，留给 rpc 层做 ✓
    if type(msg.id) ~= "number" then
        return nil, "missing/non-numeric id"
    end
    if msg.type ~= "request" and msg.type ~= "response" then
        return nil, "bad type: " .. tostring(msg.type)
    end
    if type(msg.cmd) ~= "string" then
        return nil, "missing cmd"
    end
    return msg
end

-- 收到一条原始消息：解包 -> 记统计 -> 按 cmd 发事件
function CopilotIn.onMessage(text)
    local msg, err = self.decode(text)
    if msg == nil then
        self.failed = self.failed + 1
        CopilotNet.emit("error", "inbound decode failed: " .. tostring(err))
        return
    end

    self.received = self.received + 1
    self.last = msg

    -- 通用事件 + 按动作细分的事件，两种都发，监听者按需选
    CopilotNet.emit("cmd", msg)
    CopilotNet.emit("cmd:" .. msg.cmd, msg)

    -- ★ 交给 RPC 框架分发：request → 查我的功能表并自动回答复；response → 结清待答复
    if CopilotRpc ~= nil then
        CopilotRpc.dispatch(msg)
    end
end

-- 把自己挂到 net 上。幂等：重复调用不会重复注册。
function CopilotIn.install()
    if self.installed then return end
    self.installed = true
    CopilotNet.on("message", function(text) CopilotIn.onMessage(text) end)
end

function CopilotIn.status()
    return "in: received=" .. tostring(self.received)
        .. " failed=" .. tostring(self.failed)
        .. " last=" .. tostring(self.last and self.last.cmd or "none")
end

return CopilotIn
