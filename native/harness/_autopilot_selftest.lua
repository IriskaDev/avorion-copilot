-- _autopilot_selftest.lua —— 「实体级自动驾驶已移除」的离线守卫（2026-10-24 改写 ✓）
--
-- 背景：主人原话「autopilot 这功能给去掉吧，感觉一时半会用不上的，留自动运营就行」
--   → 实体层（玩家所开那艘船）整个摘掉 ✓；`player/ai/ops.lua` 的舰队运营**保留** ✓。
--
-- 本自检**不再测大脑策略**（大脑已经没有了 ✗），改成守三件事：
--   ① 大脑确实不存在：`autopilot.lua` 里没有 updateServer / getUpdateInterval / decide
--   ② 调用点确实断开：`player/init.lua` / `player/ui/panel.lua` / `lib/copilot/cli.lua`
--      都不再挂载它、不再读写 `copilot_enabled` / `copilot_explore`
--   ③ 旧存档自愈：空壳的 initialize 只做一次清理
--      （复位 autoPilotEnabled + 摘掉残留的 mine / salvage 实体脚本），且没有每 tick 行为
--
-- 跑法（在仓库根执行）：
--   build\harness\lua.exe native\harness\_autopilot_selftest.lua

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

local function readFile(path)
    local f = assert(io.open(path, "rb"))
    local text = f:read("*a")
    f:close()
    return text
end

-- 按**行**找（避免被注释里的词误判 ✓）：返回该行（找不到返回 nil）
local function lineContaining(text, needle)
    for line in text:gmatch("[^\r\n]+") do
        if line:find(needle, 1, true) then return line end
    end
    return nil
end

local AP_PATH = "data/scripts/player/ai/autopilot.lua"
local apSource = readFile(AP_PATH)

-- ---------------------------------------------------------------------------
print("== ① 大脑函数确实不存在（不再每 2 秒跑）==")
-- ---------------------------------------------------------------------------
check("① 没有 function Copilot.updateServer",
    apSource:find("function Copilot.updateServer", 1, true) == nil)
check("① 没有 function Copilot.getUpdateInterval（旧值 = 2 秒）",
    apSource:find("function Copilot.getUpdateInterval", 1, true) == nil)
check("① 没有 function Copilot.decide（不再接管玩家船）",
    apSource:find("function Copilot.decide", 1, true) == nil)
check("① 没有 ShipAI 接管（不再下单 / 接管飞行）",
    apSource:find("ShipAI", 1, true) == nil)
check("① 不再读 copilot_enabled",
    apSource:find('getValue("copilot_enabled")', 1, true) == nil)
check("① 不再读 copilot_explore",
    apSource:find('getValue("copilot_explore")', 1, true) == nil)
check("① 记录了移除日期（2026-10-24）",
    apSource:find('removedOn = "2026-10-24"', 1, true) ~= nil)

-- ---------------------------------------------------------------------------
print("== ② 调用点确实断开（init / panel / cli）==")
-- ---------------------------------------------------------------------------
local initSource = readFile("data/scripts/player/init.lua")
local mountLine = lineContaining(initSource, "addScriptOnce")
local initMountsAutopilot = false
for line in initSource:gmatch("[^\r\n]+") do
    if line:find("addScriptOnce", 1, true) and line:find("autopilot", 1, true) then
        initMountsAutopilot = true
    end
end
check("② init.lua 不再 addScriptOnce autopilot", not initMountsAutopilot, tostring(mountLine))
check("② init.lua 不再读 copilot_enabled",
    initSource:find('getValue("copilot_enabled")', 1, true) == nil)
check("② init.lua 仍然挂载舰队运营层 ai/ops.lua",
    initSource:find('addScriptOnce("ai/ops.lua")', 1, true) ~= nil)

local panelSource = readFile("data/scripts/player/ui/panel.lua")
check("② 面板不再挂载 autopilot.lua",
    panelSource:find("autopilot.lua", 1, true) == nil)
check("② 面板不再有 setEnabled（开关按钮的服务端面）",
    panelSource:find("function CopilotUI.setEnabled", 1, true) == nil)
check("② 面板不再有 setExplore（自动跃迁勾选框的服务端面）",
    panelSource:find("function CopilotUI.setExplore", 1, true) == nil)
check("② 面板不再有 refresh（自动驾驶状态行）",
    panelSource:find("function CopilotUI.refresh()", 1, true) == nil)
check("② 面板不再读 copilot_enabled / copilot_explore / copilot_state",
    panelSource:find('getValue("copilot_enabled")', 1, true) == nil
    and panelSource:find('getValue("copilot_explore")', 1, true) == nil
    and panelSource:find('getValue("copilot_state")', 1, true) == nil)
check("② 面板不再显示 Autopilot: ON/OFF",
    panelSource:find('"Autopilot: ON"', 1, true) == nil
    and panelSource:find('"Autopilot: OFF"', 1, true) == nil)
-- 舰队运营三块必须还在 ✓
check("② 面板名单 / 任务 / 目标输入框仍在",
    panelSource:find('"Ships operated by the AI"', 1, true) ~= nil
    and panelSource:find("refreshShipList", 1, true) ~= nil
    and panelSource:find("goalEditBox", 1, true) ~= nil)

local cliSource = readFile("data/scripts/lib/copilot/cli.lua")
-- 只看 RELOADABLE 表里**真正的条目行**（以引号开头）；表内注释提到 autopilot 不算 ✗
local reloadableHasAutopilot, inReloadable = false, false
for line in cliSource:gmatch("[^\r\n]+") do
    if line:find("local RELOADABLE = {", 1, true) then
        inReloadable = true
    elseif inReloadable and line:sub(1, 1) == "}" then
        inReloadable = false
    elseif inReloadable then
        local stripped = line:match("^%s*(.*)$") or ""
        if stripped:sub(1, 1) == '"' and stripped:find("autopilot", 1, true) then
            reloadableHasAutopilot = true
        end
    end
end
check("② cli.lua 的 RELOADABLE 不再列 autopilot.lua", not reloadableHasAutopilot)

-- ---------------------------------------------------------------------------
print("== ③ 旧存档自愈：空壳 initialize 只清理一次 ==")
-- ---------------------------------------------------------------------------
local calls = { autoPilotFalse = 0, autoPilotTrue = 0, removed = 0, added = 0 }

local craft = {}
function craft:hasScript(path)
    return path == "data/scripts/entity/ai/mine.lua"
        or path == "data/scripts/entity/ai/salvage.lua"
end
function craft:removeScript(path) calls.removed = calls.removed + 1 end
function craft:addScriptOnce(path) calls.added = calls.added + 1 end

local control = { _autoPilotEnabled = true }
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

local player = { craft = craft }
onServer = function() return true end
Player = function() return player end
valid = function(e) return e ~= nil end
ControlUnit = function(c) return control end

local chunk, err = load(apSource, "@autopilot", "t", _ENV)
check("③ 空壳能编译 + 执行", chunk ~= nil, tostring(err))
if chunk then chunk() end

check("③ 加载后仍然没有 updateServer", Copilot.updateServer == nil)
check("③ 加载后仍然没有 getUpdateInterval", Copilot.getUpdateInterval == nil)
check("③ 加载后仍然没有 decide", Copilot.decide == nil)

local okRun = pcall(function() Copilot.initialize() end)
check("③ initialize 不报错", okRun, tostring(okRun))
check("③ 复位 autoPilotEnabled=false **一次**", calls.autoPilotFalse == 1, calls.autoPilotFalse)
check("③ 绝不写 autoPilotEnabled=true", calls.autoPilotTrue == 0, calls.autoPilotTrue)
check("③ 摘掉残留的 mine + salvage（2 次）", calls.removed == 2, calls.removed)
check("③ 不挂任何脚本（addScriptOnce = 0）", calls.added == 0, calls.added)

-- 没有船（离船 / 换船瞬间）不能报错
local savedCraft = player.craft
player.craft = nil
local okNoCraft = pcall(function() Copilot.initialize() end)
player.craft = savedCraft
check("③ 没有船时不报错（直接返回）", okNoCraft, tostring(okNoCraft))

-- ---------------------------------------------------------------------------
print(string.format("== 共 %d 项断言，失败 %d 项 ==", checks, failures))
if failures == 0 then
    print("autopilotSelfTest: OK")
    os.exit(0)
else
    print("autopilotSelfTest: FAIL")
    os.exit(1)
end
