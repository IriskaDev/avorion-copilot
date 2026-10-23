package.path = package.path .. ";data/scripts/lib/?.lua"
package.path = package.path .. ";data/scripts/?.lua"
-- CopilotRpc —— **对称 RPC 框架**（游戏侧）。协议见 docs/dev/protocol.md。
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

-- ---------------------------------------------------------------------------
-- ★ 追踪（排查服务端进程猝死用 ✓）
--
-- 游戏侧 io.open 只允许 moddata/ 开头 ✓（本项目早验证过 ✓）→ 写到磁盘，agent 能读 ✓。
-- 这是**重证据**手段：进程猝死时日志戛然而止，必须知道"最后执行到哪一步" ✓。
-- ---------------------------------------------------------------------------

self.tracing = self.tracing ~= false       -- 排查期间默认开 ✓

-- ★★ 2026-10-24：trace 的 I/O 重写 —— **句柄常开 + 每行 flush + 大小轮转** ✓✓
--
-- 病根（真机量过 ✗）：旧版**每一行**都 open+write+close —— ≈0.97 ms/行，
--   一条 RPC 6~8 行 ≈ 6~8 ms 纯浪费在主循环上 ✗（trace 是为了救命，不该自己变成负载 ✗）。
-- 现在：
--   · 句柄**懒开一次、之后常开** ✓ → 每行只剩 write + flush ✓
--   · **每行照样 flush** ✗→✓：本日志的用途是「进程猝死前最后一句」（见本文件头 ✓）；
--     攒缓冲会把最后几行吃掉 = 证据当场消失 ✗ → 宁可一次 write 系统调用，绝不攒 ✓
--   · **每行照旧带时间戳** ✓（`HH:MM:SS  文本` 格式一字不改 → 老日志照样能对 ✓）
--   · **大小上限 + 轮转** ✓：超过 `TRACE_MAX_BYTES`（缺省 4 MB）→ 旧文件挪成 `.1`
--     （只留一代 ✓）。真机那份 **3.4 MB / 81701 行** 已经大到读一次要好几秒 ✓
self.TRACE_PATH = self.TRACE_PATH or "moddata/copilot/rpc_trace.log"
self.TRACE_MAX_BYTES = self.TRACE_MAX_BYTES or (4 * 1024 * 1024)

-- 关句柄（任何失败都吞掉 ✓ —— trace 自己绝不许抛错）
local function traceClose(fh)
    if fh == nil then return end
    pcall(function() fh:close() end)
end

-- 轮转：`rpc_trace.log` → `rpc_trace.log.1`，然后重开一个空的 ✓
--   ★ Windows 上 `rename` 到**已存在**的目标会失败 → 先删 `.1` ✓（删/改名全在 pcall 里）
--   ★ 挪不动（或被沙箱挡住）就退化成**截断**：宁可丢历史，也不许丢「现在能写」✓
local function traceRotate(path)
    pcall(function()
        os.remove(path .. ".1")
        os.rename(path, path .. ".1")
    end)
    local fh = io.open(path, "w")
    if fh ~= nil then fh:close() end
end

-- 打开（或轮转后重开）—— 打开时**先看大小**，超上限立刻轮转 ✓
--   返回句柄 + 当前字节数（字节数用于「写到一半超限」的第二道闸 ✓）
function CopilotRpc.traceOpen()
    local fh = io.open(self.TRACE_PATH, "a")
    if fh == nil then return nil end
    local okS, size = pcall(function() return fh:seek("end") end)
    size = (okS and tonumber(size)) or 0
    if size >= self.TRACE_MAX_BYTES then
        traceClose(fh)
        traceRotate(self.TRACE_PATH)
        fh = io.open(self.TRACE_PATH, "a")
        if fh == nil then return nil end
        size = 0
    end
    self.traceBytes = size
    return fh
end

-- 关闭常开句柄（重载/自检收尾用 ✓；正常游戏流程不需要调 ✓）
function CopilotRpc.traceClose()
    traceClose(self.traceFH)
    self.traceFH = nil
end

function CopilotRpc.trace(text)
    if not self.tracing then return end
    local line = string.format("%s  %s\n", os.date("%H:%M:%S"), tostring(text))
    local ok = pcall(function()
        local fh = self.traceFH
        if fh == nil then
            fh = CopilotRpc.traceOpen()
            self.traceFH = fh
        end
        if fh == nil then error("io.open failed") end
        fh:write(line)
        fh:flush()                     -- ★ 每行落盘：猝死前的最后一句必须在 ✓
        self.traceBytes = (self.traceBytes or 0) + #line
        -- 第二道闸：写到一半超上限 → 本行已落盘，随即关掉、轮转、下次重开 ✓
        if self.traceBytes >= self.TRACE_MAX_BYTES then
            traceClose(fh)
            self.traceFH = nil
            traceRotate(self.TRACE_PATH)
            self.traceBytes = 0
        end
    end)
    -- 追踪失败绝不影响主流程 ✓ —— 而且**不报错**，避免刷屏
    if not ok then
        traceClose(self.traceFH)
        self.traceFH = nil
        self.tracing = false
        -- ★ 写文件失败要**说出来** ✗ → 否则静默失效、排查时看不见 ✓
        if CopilotNet ~= nil and CopilotNet.report ~= nil then
            CopilotNet.report("警告：io.open 写 rpc_trace.log 失败，追踪已关闭")
        end
    end
end

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

-- ★★ 2026-10-24：**慢查询探针**（主人原话：「注意不要再加之前那种超高消耗的操作了」✓✓）
--
--   为什么要有它 ✗→✓：`tradePlan` 那种 10~21 s 的单次 RPC 当年是把游戏主循环整个占住 ✓；
--   而它**不在** clientlog、也不在帧计数器里 ✗ —— 唯一能看见它的地方是「这个 handler 跑了多久」✓。
--
--   规矩（与 `perf.lua` 同一套 ✓，见 docs/dev/interface-atomicity.md §★★★ G4 ✓）：
--     · 超过 `QUERY_THRESHOLD_MS`（缺省 **100 ms**，可调 ✓）才写一行到 perf.log ✓
--     · 名字带 what：`rpc.query:predict` / `rpc.order` ✓ —— 一眼看出是谁慢 ✓
--     · **每个名字 30 秒最多一行** ✓（节流在 perf.lua 里按名字做 ✓）→ 不刷屏 ✓
--     · 探针全程 pcall ✓ —— 写失败绝不影响答复 ✓
--
--   懒加载 perf 库（失败一次就记住失败 ✓ 别每个请求都重试 include ✗）
function CopilotRpc.perfModule()
    if self._perf ~= nil then return self._perf or nil end
    local ok, mod = pcall(include, "copilot/perf")
    self._perf = (ok and type(mod) == "table") and mod or false
    return self._perf or nil
end

-- 探针名字：`rpc.<cmd>`；query 再带上 what ✓（`rpc.query:tradeEvaluate` ✓）
function CopilotRpc.queryLabel(cmd, data)
    local label = "rpc." .. tostring(cmd)
    if tostring(cmd) == "query" and type(data) == "table" and data.what ~= nil then
        label = label .. ":" .. tostring(data.what)
    end
    return label
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

    CopilotRpc.trace("call 发出 cmd=" .. tostring(cmd) .. " id=" .. tostring(id))
    local ok, err = CopilotOut.send(msg)
    if not ok then
        self.pending[id] = nil
        CopilotRpc.trace("call **发送失败** cmd=" .. tostring(cmd) .. " err=" .. tostring(err))
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
    CopilotRpc.trace("  response: ok=" .. tostring(msg.ok) .. " cmd=" .. tostring(msg.cmd))
    local entry = self.pending[msg.id]
    if entry == nil then
        -- 协议 §2 铁律 4：id 未知的答复 → 丢弃并记日志 ✓（不崩、不断连 ✓）
        self.stats.unknown = self.stats.unknown + 1
        CopilotNet.emit("rpc_unknown", msg.id)
        return
    end
    self.pending[msg.id] = nil

    if type(entry.callback) == "function" then
        CopilotRpc.trace("  调用回调 cmd=" .. tostring(entry.cmd))
        local ok = { pcall(entry.callback, msg.ok and true or false, msg.data, msg.message or msg.code) }
        CopilotRpc.trace("  回调返回 ok=" .. tostring(ok[1]))
        if not ok[1] then
            CopilotNet.emit("error", "rpc callback for " .. tostring(entry.cmd) .. " failed: " .. tostring(ok[2]))
        end
    end
end

-- 请求：{id, type="request", cmd, data}
function CopilotRpc.onRequest(msg)
    self.stats.received = self.stats.received + 1

    CopilotRpc.trace("  request: 查 handler cmd=" .. tostring(msg.cmd))

    local fn = self.handlers[msg.cmd]
    if fn == nil then
        -- 不认识的功能 → 回 ok=false（协议 §7 ✓），不断连 ✓
        CopilotOut.sendReply(msg.id, msg.cmd, false, "UNSUPPORTED",
            "this side has no handler for '" .. tostring(msg.cmd) .. "'")
        return
    end

    -- ★ 计时起点在 **handler 调用之前** ✓（探针不许自己变成负载：只有超阈值才写 ✓）
    local t0 = os.clock()
    local data = msg.data or {}

    -- 在 pcall 里执行：一个坏 handler 不许拖垮整条链 ✓
    local r = { pcall(fn, data) }

    -- ★★ 慢查询探针（2026-10-24 ✓✓）：> 100 ms 记一行 `rpc.query:<what>` + 毫秒 ✓
    --   ★ 失败也记（带 ERR 前缀 ✓）—— 一个跑很久然后报错的 handler 同样要能看见 ✓
    local Perf = CopilotRpc.perfModule()
    if Perf ~= nil then
        Perf.log(CopilotRpc.queryLabel(msg.cmd, data), t0,
            r[1] and "" or ("ERR " .. tostring(r[2])),
            Perf.QUERY_THRESHOLD_MS)
    end

    if not r[1] then
        CopilotOut.sendReply(msg.id, msg.cmd, false, "HANDLER_ERROR", tostring(r[2]))
        return
    end

    local ok = r[2] and true or false
    local payload = r[3]
    local message = r[4]
    CopilotRpc.trace("  准备答复 ok=" .. tostring(ok) .. " cmd=" .. tostring(msg.cmd))
    CopilotOut.sendReply(msg.id, msg.cmd, ok, payload, message)
    CopilotRpc.trace("  答复已发出 id=" .. tostring(msg.id))
    self.stats.answered = self.stats.answered + 1
end

function CopilotRpc.dispatch(msg)
    if type(msg) ~= "table" then return end
    CopilotRpc.trace("dispatch type=" .. tostring(msg.type) .. " cmd=" .. tostring(msg.cmd) .. " id=" .. tostring(msg.id))
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
