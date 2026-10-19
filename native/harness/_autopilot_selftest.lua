-- _autopilot_selftest.lua —— 「开关关闭时对玩家船完全惰性」的离线自检 ✓
--
-- 不开游戏就能验：把游戏 API 全换成替身，**真的执行** data/scripts/player/ai/autopilot.lua
-- 里的 Copilot.updateServer / Copilot.release，逐次统计它对玩家船发的控制动作：
--   · autoPilotEnabled 被写 true / 写 false 的次数
--   · addScriptOnce / removeScript（挂/摘 mine、salvage）的次数
--   · decide（真正接管并下指令）被调用的次数
--
-- 断言点（对应主人的验收 ✓）：
--   · 停用 + 已接管（刚关掉）→ 只复位一次 autoPilotEnabled=false，之后绝不碰 ✓
--   · 停用 + 未接管（关掉后的每个后续 tick）→ **零控制调用**（不写 autoPilotEnabled、
--     不 removeScript、不 addScriptOnce、不 decide）✗✓ —— 这是修掉「跃迁被打断」的关键 ✓
--   · 开启 → 接管一次 autoPilotEnabled=true（engage once 不被破坏 ✓）
--
-- 跑法：  build\harness\lua.exe native\harness\_autopilot_selftest.lua

package.path = package.path .. ";data/scripts/lib/?.lua"

local failures, checks = 0, 0
local function check(name, ok, extra)
    checks = checks + 1
    if ok then
        print(string.format("  PASS  %s", name))
    else
        failures = failures + 1
        print(string.format("  FAIL  %s   -> %s", name, tostring(extra)))
    end
end

-- ---------------------------------------------------------------------------
-- 控制调用计数器（这就是「一帧内我们对玩家船下了几次控制指令」的探针 ✓）
-- ---------------------------------------------------------------------------
local calls = {
    autoPilotTrue  = 0,     -- autoPilotEnabled 被写成 true
    autoPilotFalse = 0,     -- autoPilotEnabled 被写成 false
    removeScript   = 0,
    addScriptOnce  = 0,
    decide         = 0,
}

-- 替身：craft（玩家正在开的船）
local craft = {}
function craft:hasScript(path) return false end
function craft:removeScript(path) calls.removeScript = calls.removeScript + 1 end
function craft:addScriptOnce(path) calls.addScriptOnce = calls.addScriptOnce + 1 end

-- 替身：ControlUnit —— 用 metatable 拦 autoPilotEnabled 的读写
local control = { _autoPilotEnabled = false }
setmetatable(control, {
    __index = function(t, k)
        if k == "autoPilotEnabled" then return rawget(t, "_autoPilotEnabled") end
        return nil
    end,
    __newindex = function(t, k, v)
        if k == "autoPilotEnabled" then
            if v == true then calls.autoPilotTrue = calls.autoPilotTrue + 1
            else calls.autoPilotFalse = calls.autoPilotFalse + 1 end
            rawset(t, "_autoPilotEnabled", v)
        else
            rawset(t, k, v)
        end
    end,
})

-- 替身：player
local player = {
    enabled = false,
    craft = craft,
    getValue = function(self, k)
        if k == "copilot_enabled" then return self.enabled end
        return nil
    end,
    setValue = function() end,
    sendChatMessage = function() end,
}

-- 替身：全局游戏 API
onServer = function() return true end
Player = function() return player end
valid = function(e) return e ~= nil end
ControlUnit = function(c) return control end
ShipAI = function(c) return {} end

-- ---------------------------------------------------------------------------
-- 载入 autopilot.lua（真跑 updateServer / release 的实现 ✓）
-- ---------------------------------------------------------------------------
local f = assert(io.open("data/scripts/player/ai/autopilot.lua", "rb"))
local text = f:read("*a")
f:close()
local chunk, err = load(text, "@autopilot", "t", _ENV)
assert(chunk, tostring(err))
chunk()

-- decide 换成计数替身：我们只断言「停用时不进 decide」，不测 decide 内部策略 ✓
Copilot.decide = function() calls.decide = calls.decide + 1 end

print("== 场景 1：停用 + 已接管（刚关掉后的第一个 tick）==")
Copilot.tookControl = true
Copilot.updateServer()
check("只复位一次 autoPilotEnabled=false", calls.autoPilotFalse == 1, calls.autoPilotFalse)
check("不写 autoPilotEnabled=true", calls.autoPilotTrue == 0, calls.autoPilotTrue)
check("不进 decide（不接管不下指令）", calls.decide == 0, calls.decide)
check("释放后 tookControl=false", Copilot.tookControl == false, tostring(Copilot.tookControl))

print("== 场景 2：停用 + 未接管（关掉后的每个后续 tick）★核心★ ==")
local f0, t0, r0 = calls.autoPilotFalse, calls.autoPilotTrue, calls.removeScript
Copilot.updateServer()
Copilot.updateServer()
Copilot.updateServer()
check("后续 tick 不再写 autoPilotEnabled=false", calls.autoPilotFalse == f0, calls.autoPilotFalse - f0)
check("后续 tick 不写 autoPilotEnabled=true", calls.autoPilotTrue == t0, calls.autoPilotTrue - t0)
check("后续 tick 不 removeScript", calls.removeScript == r0, calls.removeScript - r0)
check("后续 tick 不 addScriptOnce", calls.addScriptOnce == 0, calls.addScriptOnce)
check("后续 tick 不进 decide", calls.decide == 0, calls.decide)

print("== 场景 3：开启 + 未接管（重新打开）==")
player.enabled = true
Copilot.tookControl = false
Copilot.updateServer()
check("开启后接管一次 autoPilotEnabled=true", calls.autoPilotTrue == 1, calls.autoPilotTrue)
check("开启后进 decide", calls.decide == 1, calls.decide)

print("== 场景 4：开启 + 已接管（后续 tick 不重复接管）==")
Copilot.updateServer()
Copilot.updateServer()
check("已接管时不再写 autoPilotEnabled=true（engage once）", calls.autoPilotTrue == 1, calls.autoPilotTrue)

-- ---------------------------------------------------------------------------
print(string.format("== 共 %d 项断言，失败 %d 项 ==", checks, failures))
if failures == 0 then
    print("autopilotSelfTest: OK")
    os.exit(0)
else
    print("autopilotSelfTest: FAIL")
    os.exit(1)
end
