package.path = package.path .. ";data/scripts/lib/?.lua"
package.path = package.path .. ";data/scripts/?.lua"
-- CopilotNet —— 对外链路的**传输层与事件源**。
--
-- 职责边界（很重要，别在这层写业务）：
--   * 只负责：连/断、把 DLL 收到的完整帧变成事件、把消息交出去
--   * **不解析业务**（那是 net/inbound.lua、net/outbound.lua 的事）
--   * **不处理业务**（那是 commands/ 下两个监听者的事）
--
-- 为什么是"tick 泵"而不是真异步：
--   Lua 这边没有真正的异步回调（引擎不会因为我们而回调）✗，
--   DLL 的 recv 又是非阻塞的 ✓，所以唯一形态是"每 tick 拉一次"。
--   对外仍然表现为事件：上层只管 CopilotNet.on(...)，不用关心轮询。
--
-- 命名空间脚本：表不能清空（否则 /copilot reload 会重载即失忆）
-- namespace CopilotNet
CopilotNet = CopilotNet or {}

local self = CopilotNet

-- 事件总线 -------------------------------------------------------------------

self.listeners = self.listeners or {}      -- [event] = { fn, ... }

function CopilotNet.on(event, fn)
    self.listeners[event] = self.listeners[event] or {}
    table.insert(self.listeners[event], fn)
end

-- 派发时逐个 pcall：一个监听者出错不能拖垮其他监听者，也不能中断本 tick
function CopilotNet.emit(event, payload)
    local list = self.listeners[event]
    if not list then return end
    for _, fn in ipairs(list) do
        local ok, err = pcall(fn, payload)
        if not ok then
            print("[copilot net] listener for '" .. tostring(event) .. "' failed: " .. tostring(err))
        end
    end
end

-- 配置 -----------------------------------------------------------------------

self.host = self.host or "127.0.0.1"
self.port = self.port or 8765

self.state = self.state or "idle"          -- idle / connecting / ready / dead
self.handlersReady = self.handlersReady or false

-- 连接 -----------------------------------------------------------------------

function CopilotNet.getModule()
    local ok, cp = pcall(require, "copilot")
    if ok and type(cp) == "table" then return cp end
    return nil
end

function CopilotNet.connect()
    local cp = CopilotNet.getModule()
    if cp == nil then
        CopilotNet.emit("error", "native module 'copilot' unavailable")
        return false
    end
    local ok, err = cp.connect(self.host, self.port)
    if not ok then
        CopilotNet.emit("error", "connect failed: " .. tostring(err))
        return false
    end
    self.state = "connecting"
    return true
end

function CopilotNet.isConnected()
    local cp = CopilotNet.getModule()
    if cp == nil then return false end
    return cp.connected() and true or false
end

-- 发送：这里只做"交出去"，不决定发什么
function CopilotNet.send(text)
    local cp = CopilotNet.getModule()
    if cp == nil then return false, "no module" end
    return cp.send(text)
end

-- 事件泵 ---------------------------------------------------------------------

function CopilotNet.getUpdateInterval()
    return 1                                -- 每秒拉一次；决策是秒级场景，够用
end

function CopilotNet.updateServer()
    if not onServer() then return end

    local cp = CopilotNet.getModule()
    if cp == nil then return end

    local connected = cp.connected() and true or false

    -- 连接状态变化 → 事件（"connected" / "disconnected"）
    if connected and self.state ~= "ready" then
        self.state = "ready"
        CopilotNet.emit("connected", nil)
    elseif not connected and self.state == "ready" then
        self.state = "dead"
        if CopilotRpc ~= nil then CopilotRpc.reset() end   -- 待答复全部作废 ✓
        CopilotNet.emit("disconnected", nil)
    end

    if not connected then
        -- ★ BUG 修复：断开后必须**再连一次** ✗→✓
        -- 原先只在 initialize 里连一次，于是掉线后再也连不上（实测：对端第二次 hello 超时 ✗）。
        -- 协议 §6：重连是**本侧（DLL 侧）的职责** ✓ —— 每 5 秒试一次 ✓。
        local now = os.clock()
        if now - (self.lastConnectAt or 0) > 5 then
            self.lastConnectAt = now
            CopilotNet.connect()
        end
        return
    end
    self.lastConnectAt = nil

    -- 把 DLL 里已到的完整帧全部取干净，一条一条 emit 出去。
    -- 用上限防止坏帧导致死循环；recv 是非阻塞的，没有就返回 nil。
    for _ = 1, 32 do
        local text = cp.recv()
        if text == nil then break end
        CopilotRpc.trace("收到一帧 " .. tostring(#text) .. " 字节")
        CopilotNet.emit("message", text)    -- 原始文本；解析交给 inbound
    end

    -- ★ 扫 RPC 超时（Lua 没有定时器 → 由这个 tick 泵驱动 ✓，和 recv 同一个 1 Hz 节拍）
    if CopilotRpc ~= nil then
        CopilotRpc.tick()
    end
end

function CopilotNet.initialize()
    if self.handlersReady then return end
    self.handlersReady = true

    -- 把整条链装进**同一个 VM**：解析层与监听者都必须和泵在一起，
    -- 否则它们注册到的事件总线不是同一条，事件永远不会到监听者手里。
    self.rpc = include("net/rpc")            -- ★ 对称 RPC 框架（我先 include，inbound 才能用）
    self.inbound = include("net/inbound")
    self.outbound = include("net/outbound")
    self.linkOut = include("net/link_out")
    self.linkIn = include("net/link_in")

    self.inbound.install()          -- 自己挂到 net 上：net 一有消息就解包并转发
    self.linkOut.install()          -- game -> DSH
    self.linkIn.install()           -- DSH -> game

    CopilotNet.connect()
end

return CopilotNet
