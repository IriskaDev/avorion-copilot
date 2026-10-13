package.path = package.path .. ";data/scripts/lib/?.lua"
package.path = package.path .. ";data/scripts/?.lua"
-- CopilotRpc —— **对称 RPC 框架**（游戏侧）。协议见 PROTOCOL.md。
--
-- 本层的本质只有一句话（主人说的）：
--   **让对面能调我的功能，也让我能调对面的功能。** ✓
--
-- 所以两端各有一份**同样的**框架，各有三样东西：
--   * `handle(cmd, fn)`  我提供哪些功能  → 声明后自动进入 `caps` ✓
--   * `call(cmd, data, cb)` 我调用对面  → 进待答复表，等答复 ✓
--   * `tick()`           扫超时         → Lua 没有定时器，靠 tick 泵驱动 ✓
--
-- 本层**不做传输**（那是 CopilotNet 的事），**不做业务**（那是 link_in/link_out 的事）✓
--
-- 命名空间脚本：表不能清空（热重载友好）
-- namespace CopilotRpc
CopilotRpc = CopilotRpc or {}

local self = CopilotRpc

-- 我提供的功能：cmd -> handler(data) -> ok, dataOrCode, message
self.handlers = self.handlers or {}

-- 我发出去、还没被答复的请求：id -> {cmd, callback, deadline}
self.pending = self.pending or {}

-- 统计（诊断用）
self.stats = self.stats or { sent = 0, received = 0, answered = 0, timedOut = 0, unknown = 0 }

-- 默认超时（秒）。协议 §6：query 5 秒；order/decide 由调用方显式给更长的值 ✓
self.DEFAULT_TIMEOUT = 5

-- ---------------------------------------------------------------------------
-- 我提供的功能
-- ---------------------------------------------------------------------------

-- handler 约定：function(data) -> ok:boolean, payload:any, message:string?
--   ok=true  → payload 放进答复的 data ✓
--   ok=false → payload 当作 code，message 当作说明 ✓
function CopilotRpc.handle(cmd, fn)
    self.handlers[cmd] = fn
end

-- caps：给 `hello` 用 ✓ —— 自动反映我注册了哪些功能 ✓
function CopilotRpc.caps()
    local out = {}
    for cmd in pairs(self.handlers) do out[#out + 1] = cmd end
    table.sort(out)
    return out
end

-- ---------------------------------------------------------------------------
-- 我调用对面
-- ---------------------------------------------------------------------------

-- callback 约定：function(ok, payload, message)  —— 与 handler 的返回形状一致 ✓
function CopilotRpc.call(cmd, data, callback, timeoutSec)
    local msg = CopilotOut.request(cmd, data)
    local id = msg.id

    self.pending[id] = {
        cmd = cmd,
        callback = callback,
        -- 用 os.clock（单调、秒）算超时，避免 os.time 的整秒粒度 ✓
        deadline = os.clock() + (timeoutSec or self.DEFAULT_TIMEOUT),
    }

    local ok, err = CopilotOut.send(msg)
    if not ok then
        self.pending[id] = nil
        return false, err
    end

    self.stats.sent = self.stats.sent + 1
    return true, id
end

-- ---------------------------------------------------------------------------
-- 收到一条消息（由 CopilotIn 调用 ✓）—— 整个框架的唯一入口
-- ---------------------------------------------------------------------------

-- 答复：{id, type="response", cmd, ok, data?, code?, message?}
function CopilotRpc.onResponse(msg)
    local entry = self.pending[msg.id]
    if entry == nil then
        -- 协议 §2 铁律 4：id 未知的答复 → 丢弃并记日志 ✓（不崩、不断连 ✓）
        self.stats.unknown = self.stats.unknown + 1
        CopilotNet.emit("rpc_unknown", msg.id)
        return
    end
    self.pending[msg.id] = nil

    if type(entry.callback) == "function" then
        local ok = { pcall(entry.callback, msg.ok and true or false, msg.data, msg.message or msg.code) }
        if not ok[1] then
            CopilotNet.emit("error", "rpc callback for " .. tostring(entry.cmd) .. " failed: " .. tostring(ok[2]))
        end
    end
end

-- 请求：{id, type="request", cmd, data}
function CopilotRpc.onRequest(msg)
    self.stats.received = self.stats.received + 1

    local fn = self.handlers[msg.cmd]
    if fn == nil then
        -- 不认识的功能 → 回 ok=false（协议 §7 ✓），不断连 ✓
        CopilotOut.sendReply(msg.id, msg.cmd, false, "UNSUPPORTED",
            "this side has no handler for '" .. tostring(msg.cmd) .. "'")
        return
    end

    -- 在 pcall 里执行：一个坏 handler 不许拖垮整条链 ✓
    local r = { pcall(fn, msg.data or {}) }
    if not r[1] then
        CopilotOut.sendReply(msg.id, msg.cmd, false, "HANDLER_ERROR", tostring(r[2]))
        return
    end

    local ok = r[2] and true or false
    local payload = r[3]
    local message = r[4]
    CopilotOut.sendReply(msg.id, msg.cmd, ok, payload, message)
    self.stats.answered = self.stats.answered + 1
end

function CopilotRpc.dispatch(msg)
    if type(msg) ~= "table" then return end
    if msg.type == "response" then
        CopilotRpc.onResponse(msg)
    elseif msg.type == "request" then
        CopilotRpc.onRequest(msg)
    else
        self.stats.unknown = self.stats.unknown + 1
        CopilotNet.emit("rpc_badtype", msg.type)
    end
end

-- ---------------------------------------------------------------------------
-- 超时（由 net 的 tick 泵驱动 ✓ —— Lua 没有定时器）
-- ---------------------------------------------------------------------------

function CopilotRpc.tick()
    local now = os.clock()
    local expired = nil

    for id, entry in pairs(self.pending) do
        if now >= entry.deadline then
            expired = expired or {}
            expired[#expired + 1] = id
        end
    end

    if expired == nil then return end

    for _, id in ipairs(expired) do
        local entry = self.pending[id]
        self.pending[id] = nil
        self.stats.timedOut = self.stats.timedOut + 1
        -- 超时也走同一个 callback 形状 ✓（ok=false, code="TIMEOUT"）✓
        if entry and type(entry.callback) == "function" then
            pcall(entry.callback, false, "TIMEOUT", "no response for " .. tostring(entry.cmd))
        end
    end
end

-- 断线时把所有待答复作废 ✓（否则连接重建后会永远挂着）
function CopilotRpc.reset()
    for id, entry in pairs(self.pending) do
        if entry and type(entry.callback) == "function" then
            pcall(entry.callback, false, "DISCONNECTED", "connection lost")
        end
    end
    self.pending = {}
    CopilotOut.reset()          -- id 计数器也重置（新连接从 1 开始 ✓）
end

function CopilotRpc.status()
    local n = 0
    for _ in pairs(self.pending) do n = n + 1 end
    return string.format("rpc: handlers=%d pending=%d sent=%d recv=%d answered=%d timeout=%d unknown=%d",
        (function() local c = 0 for _ in pairs(self.handlers) do c = c + 1 end return c end)(),
        n, self.stats.sent, self.stats.received, self.stats.answered, self.stats.timedOut, self.stats.unknown)
end

return CopilotRpc
