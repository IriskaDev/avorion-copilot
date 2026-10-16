package.path = package.path .. ";data/scripts/lib/?.lua"
package.path = package.path .. ";data/scripts/?.lua"
-- copilotjson -- **纯 Lua 的 JSON 编解码**（2026-10-15，为修崩溃而引入）。
--
-- 为什么不能用原生模块做这件事 ✗：
--   DLL 里的 cJSON 解码会 `lua_createtable` + 逐字段 `lua_setfield` ✗ —— 这会**触发 Lua 的 GC** ✓。
--   而游戏从**多个 Lua worker 线程并发**运行我们的脚本 ✓（DLL 日志里出现过 10 个不同 tid ✓），
--   我们的锁**保护不了那个 lua_State** ✗ —— 因为游戏自己的 Lua 代码不会去拿我们的锁 ✓✓。
--   两个线程同时 GC 同一个 global_State → 堆损坏 → 约 80 秒后 `X_X` + `lua::WorkerPool` 崩溃 ✗✓。
--
-- 实测证据：
--   * 只调 recv（pushlstring，小分配）→ 5 分钟不崩 ✓
--   * 只要走到 decode（建表 + GC）→ ~80 秒必崩 ✗
--
-- 所以 JSON 一律在 **Lua 里**做 ✓ —— 它跑在游戏自己的 Lua 执行中，天然安全 ✓✓。
-- 原生模块只剩 socket 收发 + push 字符串 ✓（已实测安全 ✓）。
--
-- 这是 lib：只能 return 命名空间表，不许定义全局生命周期回调 ✓。
-- ⚠️ 本文件里**不许出现**那个会被引擎误解析的关键字（见 copilotgoal.lua 的教训 ✓）。

local M = {}

-- ===========================================================================
-- 解码（JSON 文本 -> Lua 值）
-- ===========================================================================

local function skip_ws(s, i)
    local _, e = s:find("^[ \t\r\n]*", i)
    return e + 1
end

local decode_value

-- 解析字符串字面量（i 指向开引号之后的第一个字符）；返回 值, 下一位置
local function decode_string(s, i)
    local out = {}
    while true do
        local c = s:sub(i, i)
        if c == "" then return nil, nil end
        if c == '"' then return table.concat(out), i + 1 end
        if c == "\\" then
            local esc = s:sub(i + 1, i + 1)
            if esc == "u" then
                local hex = s:sub(i + 2, i + 5)
                local n = tonumber(hex, 16)
                if n == nil then return nil, nil end
                if n < 128 then
                    out[#out + 1] = string.char(n)
                elseif n < 2048 then
                    out[#out + 1] = string.char(192 + math.floor(n / 64), 128 + n % 64)
                else
                    out[#out + 1] = string.char(
                        224 + math.floor(n / 4096),
                        128 + math.floor(n / 64) % 64,
                        128 + n % 64)
                end
                i = i + 6
            else
                local map = { ['"'] = '"', ["\\"] = "\\", ["/"] = "/", b = "\b",
                              f = "\f", n = "\n", r = "\r", t = "\t" }
                local rep = map[esc]
                if rep == nil then return nil, nil end
                out[#out + 1] = rep
                i = i + 2
            end
        else
            out[#out + 1] = c
            i = i + 1
        end
    end
end

local function decode_number(s, i)
    local num = s:match("^-?%d+%.?%d*[eE]?[-+]?%d*", i)
    if num == nil or num == "" then return nil, nil end
    local n = tonumber(num)
    if n == nil then return nil, nil end
    return n, i + #num
end

decode_value = function(s, i)
    i = skip_ws(s, i)
    local c = s:sub(i, i)
    if c == "" then return nil, nil end

    if c == "{" then
        local obj = {}
        i = skip_ws(s, i + 1)
        if s:sub(i, i) == "}" then return obj, i + 1 end
        while true do
            i = skip_ws(s, i)
            if s:sub(i, i) ~= '"' then return nil, nil end
            local key, ni = decode_string(s, i + 1)
            if key == nil then return nil, nil end
            i = skip_ws(s, ni)
            if s:sub(i, i) ~= ":" then return nil, nil end
            local val, vi = decode_value(s, i + 1)
            if vi == nil then return nil, nil end
            obj[key] = val
            i = skip_ws(s, vi)
            local sep = s:sub(i, i)
            if sep == "," then i = i + 1
            elseif sep == "}" then return obj, i + 1
            else return nil, nil end
        end
    elseif c == "[" then
        local arr = {}
        i = skip_ws(s, i + 1)
        if s:sub(i, i) == "]" then return arr, i + 1 end
        while true do
            local val, vi = decode_value(s, i)
            if vi == nil then return nil, nil end
            arr[#arr + 1] = val
            i = skip_ws(s, vi)
            local sep = s:sub(i, i)
            if sep == "," then i = i + 1
            elseif sep == "]" then return arr, i + 1
            else return nil, nil end
        end
    elseif c == '"' then
        return decode_string(s, i + 1)
    elseif c == "t" and s:sub(i, i + 3) == "true" then
        return true, i + 4
    elseif c == "f" and s:sub(i, i + 4) == "false" then
        return false, i + 5
    elseif c == "n" and s:sub(i, i + 3) == "null" then
        return nil, i + 4          -- ⚠️ nil 值 + 有效的下一位置（调用方靠 pos 判成功 ✓）
    else
        return decode_number(s, i)
    end
end

-- 返回 值, nil 或 nil, 错误说明 ✓
function M.decode(text)
    if type(text) ~= "string" then return nil, "not a string" end
    local ok, val, pos = pcall(decode_value, text, 1)
    if not ok then return nil, "decode error: " .. tostring(val) end
    if pos == nil then return nil, "malformed JSON" end
    return val
end

-- ===========================================================================
-- 编码（Lua 值 -> JSON 文本）
-- ===========================================================================

local function enc_string(v)
    return '"' .. v:gsub('[%c"\\]', function(ch)
        if ch == '"' then return '\\"' end
        if ch == "\\" then return "\\\\" end
        if ch == "\n" then return "\\n" end
        if ch == "\r" then return "\\r" end
        if ch == "\t" then return "\\t" end
        if ch == "\b" then return "\\b" end
        if ch == "\f" then return "\\f" end
        return string.format("\\u%04x", ch:byte())
    end) .. '"'
end

local function is_array(t)
    local n = 0
    for k in pairs(t) do
        if type(k) ~= "number" then return false end
        n = n + 1
    end
    return n > 0 and n == #t
end

local enc_value

enc_value = function(v)
    local tv = type(v)
    if v == nil then return "null" end
    if tv == "boolean" then return v and "true" or "false" end
    if tv == "number" then
        if v == math.floor(v) and math.abs(v) < 2 ^ 53 then
            return string.format("%d", v)
        end
        return string.format("%.14g", v)
    end
    if tv == "string" then return enc_string(v) end
    if tv == "table" then
        if is_array(v) then
            local parts = {}
            for i = 1, #v do parts[i] = enc_value(v[i]) end
            return "[" .. table.concat(parts, ",") .. "]"
        end
        local parts = {}
        for k, val in pairs(v) do
            parts[#parts + 1] = enc_string(tostring(k)) .. ":" .. enc_value(val)
        end
        return "{" .. table.concat(parts, ",") .. "}"
    end
    return enc_string("<" .. tv .. ">")
end

function M.encode(v)
    local ok, text = pcall(enc_value, v)
    if not ok then return nil, "encode error: " .. tostring(text) end
    return text
end

return M
