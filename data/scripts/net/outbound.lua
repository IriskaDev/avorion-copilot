package.path = package.path .. ";data/scripts/lib/?.lua"
package.path = package.path .. ";data/scripts/?.lua"
-- CopilotOut —— **出站消息构造**（game → DSH 方向）。
--
-- 职责边界：把「要说什么」变成「可以发的表」。**不做传输**（send 由 CopilotNet 负责），
-- **不做业务决策**（该不该发是 link_out 的事）。
--
-- 协议见 PROTOCOL.md v2：
--   * 信封 = 元信息：`id` / `type` / `cmd`（答复再加 `ok` / `code` / `message`）
--   * **`data`** = 载荷：**由 `cmd` 决定其形状** ✓（request 和 response 都叫 data ✓）
--   * 答复的 `id` 与 **`cmd` 都与请求相同** ✓（`type` 说明问/答，`cmd` 说明在谈什么事 ✓）
--
-- 命名空间脚本：表不能清空
-- namespace CopilotOut
CopilotOut = CopilotOut or {}

local self = CopilotOut

-- 协议版本（与 PROTOCOL.md 同步）
self.VER = 2

-- id 生成：单条连接内唯一即可。连接重建时清零（见 reset）
self.nextIdValue = self.nextIdValue or 0

function CopilotOut.nextId()
    self.nextIdValue = self.nextIdValue + 1
    return self.nextIdValue
end

function CopilotOut.reset()
    self.nextIdValue = 0
end

-- 底层：表 -> JSON 文本。用 DLL 里的 cJSON，避免手写编解码出错。
function CopilotOut.encode(msg)
    -- ★★ 2026-10-15：改用**纯 Lua** JSON 编码 ✓✓（同 inbound.lua 的理由：
    -- 原生建表会触发 Lua GC，而我们的脚本是被多线程并发跑的 ✗。
    -- 原生模块从此刻起**只做 socket 收发**（已实测 5 分钟安全 ✓✓）。
    local Json = include("copilotjson")
    local text = Json.encode(msg)
    if text == nil then return nil, "encode failed" end
    return text
end

-- ---------------------------------------------------------------------------
-- 两种消息类型（协议 v2 的全部形态）
-- ---------------------------------------------------------------------------

-- 请求：{id, type="request", cmd, data}
--   `data` 的形状由 `cmd` 决定（例如 query 需要 data.what ✓）
function CopilotOut.request(cmd, data, id)
    return {
        id = id or CopilotOut.nextId(),
        type = "request",
        cmd = cmd,
        data = data or {},
    }
end

-- 答复：{id, type="response", cmd=原 cmd, ok, data?} / 失败时 {..., ok=false, code, message}
--   ★ cmd 必须与请求相同 → 所以由调用方把它传进来
--   CopilotOut.reply(id, cmd, true,  {ships = {...}})
--   CopilotOut.reply(id, cmd, false, "NO_SUCH_SHIP", "船名不存在")
function CopilotOut.reply(id, cmd, ok, payloadOrCode, message)
    local msg = {
        id = id,
        type = "response",
        cmd = cmd,
        ok = ok and true or false,
    }
    if msg.ok then
        msg.data = payloadOrCode or {}
    else
        msg.code = payloadOrCode or "ERROR"
        if message ~= nil then msg.message = tostring(message) end
        msg.data = {}          -- 失败也给一个空 data，保证形状稳定 ✓
    end
    return msg
end

-- ---------------------------------------------------------------------------
-- 具体的请求构造（纯拼装，不含"要不要发"的判断）
-- ---------------------------------------------------------------------------

function CopilotOut.hello(side, caps)
    return CopilotOut.request("hello", {
        ver = self.VER,
        side = side or "game",
        caps = caps or {},
    })
end

function CopilotOut.state(ships)
    return CopilotOut.request("state", { ships = ships or {} })
end

function CopilotOut.event(kind, extra)
    local data = { kind = kind }
    if type(extra) == "table" then
        for k, v in pairs(extra) do data[k] = v end
    end
    return CopilotOut.request("event", data)
end

-- ---------------------------------------------------------------------------
-- 发送
-- ---------------------------------------------------------------------------

function CopilotOut.send(msg)
    if type(msg) ~= "table" then return false, "not a table" end
    local text, err = self.encode(msg)
    if text == nil then return false, err end
    return CopilotNet.send(text)
end

-- 构造并发送一个请求：返回 ok, err, id
function CopilotOut.sendRequest(cmd, data)
    local msg = CopilotOut.request(cmd, data)
    local ok, err = self.send(msg)
    if not ok then return false, err, nil end
    return true, nil, msg.id
end

-- 构造并发送一个答复（cmd 必须传原请求的 cmd ✓）
function CopilotOut.sendReply(id, cmd, ok, payloadOrCode, message)
    local msg = CopilotOut.reply(id, cmd, ok, payloadOrCode, message)
    return self.send(msg)
end

return CopilotOut
