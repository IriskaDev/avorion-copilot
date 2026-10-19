-- _panel_roster_selftest.lua —— 面板「舰船列表」↔ 插件名单 的离线自检（2026-10-19 加 ✓✓）
--
-- 起因（主人真机报告）：「面板第 0 列一个勾都没有」，而 `fleet_query {what:list}` 回
-- `designated: 4`。真机截图查明：这 4 艘船**其实都打着勾**，只是 ListBoxEx 的 CheckBox
-- 把「已勾」画成**实心方块**、没有 ✓ 号 → 肉眼读成"没勾" ✗。
--
-- 本自检不开游戏，把面板脚本 `data/scripts/player/ui/panel.lua` **原样加载**
-- （UI / Player 全部换成内存替身），然后真的走一遍：
--
--   ① 布局：5 列、列宽和 = PANEL_WIDTH-20（420）、5 个列头文字、所有控件不越界 ✓
--   ② 勾选同源：第 0 列 = `copilot_auto_ships`，第 1 列 = 它的文字镜像 ✓
--   ③ 勾选一舥 → `setAutoShips` 落盘 → `card.lua` 的 `designated` 跟着 +1；取消 → 立刻消失 ✓
--   ④ 任务列写的是**真目标** `copilot_goal_kind_<船>`（goal.lua），不是没人读的 cfg.target ✓
--   ⑤ 只读自检行：`reportRoster` 回执 = `card.lua` 的 `designated` ✓
--
-- 跑法（在仓库根执行）：
--   native\harness\lua.exe native\harness\_panel_roster_selftest.lua

package.path = package.path .. ";data/scripts/lib/?.lua"
package.path = package.path .. ";data/scripts/?.lua"

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
-- `%_t` 替身：真脚本 VM 里 `"text"%_t` 由引擎预替换成本地化字面量 ✓；
-- 纯 Lua 里它是「取模」，所以给全局 `_t` 一个 __mod 元方法，让它原样返回 ✓✓
-- ---------------------------------------------------------------------------
_t = setmetatable({}, { __mod = function(a) return a end })

-- ---------------------------------------------------------------------------
-- 引擎替身：几何 / 颜色 / 枚举（panel.lua 把它们当**全局**调用 ✓）
-- ---------------------------------------------------------------------------
function vec2(x, y)
    return setmetatable({ x = x, y = y }, { __add = function(a, b)
        return vec2(a.x + b.x, a.y + b.y) end })
end

function Rect(lower, upper) return { lower = lower, upper = upper } end
function ColorRGB(r, g, b) return { r = r, g = g, b = b } end

ListBoxEntryType = { Icon = "Icon", Text = "Text", CheckBox = "CheckBox",
                     PixelIcon = "PixelIcon", Texture = "Texture" }

-- 原版 UIVerticalLister 只保证"从上往下依次给 Rect"；这里同一个语义（height + offset）
function UIVerticalLister(rect, offset)
    local cursor = rect.lower.y
    local api = {}
    function api.nextRect(_, height)
        local top = cursor
        cursor = cursor + height + (offset or 0)
        return Rect(vec2(rect.lower.x, top), vec2(rect.upper.x, top + height))
    end
    return api
end

-- ---------------------------------------------------------------------------
-- Player value 内存表（**这就是"持久化字段"** ✓）
-- ---------------------------------------------------------------------------
local VALUES = {
    -- 真机当前状态的样子：4 艘在名单里
    ["copilot_auto_ships"] = "Miner-00001\nMiner-00002\nSalvager-00001\nTrader-00001",
    ["copilot_auto_cfg"] = "Miner-00001|1|Mine\nMiner-00002|1|Mine\nSalvager-00001|1|Salvage\nTrader-00001|1|Trade",
    ["copilot_goal_kind_Salvager-00001"] = "Salvage",
}

local SHIP_NAMES = { "Combat-00001", "Lady", "Miner-00001", "Miner-00002", "Raven",
                     "Salvager-00001", "Salvager-00002", "Scout-00001", "Trader-00001" }

local player = {
    index = 1,
    craft = nil,
    getValue = function(_, key) return VALUES[key] end,
    setValue = function(_, key, value) VALUES[key] = value end,
    getShipNames = function(_)
        local out = {}
        for _, n in ipairs(SHIP_NAMES) do out[#out + 1] = n end
        return table.unpack(out)
    end,
}

function Player() return player end
function valid(v) return v ~= nil end
function onClient() return false end
function onServer() return true end
function getResolution() return vec2(1920, 1080) end
callingPlayer = 1

-- 客户端 -> 服务端的调用：记下来，稍后**真的**在服务端跑一遍 ✓
local RPC = {}
function invokeServerFunction(name, ...)
    RPC[#RPC + 1] = { name = name, args = { ... } }
end

include = function(name)
    if name == "callable" then return function() end end
    if name == "copilot/card" then return dofile("data/scripts/lib/copilot/card.lua") end
    if name == "copilot/goal" then return dofile("data/scripts/lib/copilot/goal.lua") end
    if name == "copilot/rename" then return dofile("data/scripts/lib/copilot/rename.lua") end
    if name == "captainutility" then return { ClassType = {} } end
    if name == "areaanalysis" then return nil end
    if name == "commandfactory" then return { makeCommand = function() return {} end } end
    if name == "goods" then return {} end
    error("unexpected include: " .. tostring(name))
end
callable = function() end

-- ---------------------------------------------------------------------------
-- 假 UI：ListBoxEx / Window / Label
-- ---------------------------------------------------------------------------
local function newList()
    local list = { rows = 0, cells = {}, columns = 0, widths = {}, rowHeight = 0,
                   entriesSelectable = false, onChangedFunction = "",
                   onSelectFunction = "", selected = -1 }
    function list:clear() self.rows = 0; self.cells = {} end
    function list:addRow() self.rows = self.rows + 1 end
    function list:setColumnWidth(i, w) self.widths[i] = w end
    function list:setEntry(col, row, text)
        self.cells[row] = self.cells[row] or {}
        self.cells[row][col] = text
    end
    function list:getEntry(col, row)
        local r = self.cells[row]
        return (r and r[col]) or ""
    end
    function list:setEntryType() end
    -- 模拟玩家点了第 row 行的勾选框（引擎翻转那格文本，然后回调 onChangedFunction ✓）
    function list:toggle(col, row)
        self.cells[row] = self.cells[row] or {}
        local now = self.cells[row][col]
        self.cells[row][col] = (now ~= nil and now ~= "") and "" or "checked"
    end
    return list
end

local created = { labels = {}, buttons = {}, checkboxes = {}, lists = {} }

local function newWindow()
    local w = { visible = false, caption = "", moveable = false, showCloseButton = false }
    function w:show() self.visible = true end
    function w:hide() self.visible = false end
    function w:createLabel(rect, text, font)
        local l = { rect = rect, caption = text or "", fontSize = font }
        function l:setCenterAligned() self.centered = true end
        created.labels[#created.labels + 1] = l
        return l
    end
    function w:createButton(rect, caption)
        local b = { rect = rect, caption = caption }
        created.buttons[#created.buttons + 1] = b
        return b
    end
    function w:createCheckBox(rect, caption)
        local c = { rect = rect, caption = caption }
        created.checkboxes[#created.checkboxes + 1] = c
        return c
    end
    function w:createListBoxEx(rect)
        local l = newList()
        l.rect = rect
        created.lists[#created.lists + 1] = l
        return l
    end
    return w
end

function Hud()
    return { createWindow = function() return newWindow() end,
             addMouseShowingWindow = function() end }
end

-- ---------------------------------------------------------------------------
-- 加载面板脚本（**原样**，不复制粘贴 ✓）。它不 return，定义的是全局 `CopilotUI` ✓
-- ---------------------------------------------------------------------------
dofile("data/scripts/player/ui/panel.lua")
local Panel = CopilotUI

local Card = include("copilot/card")
local Goal = include("copilot/goal")

local function designated() return Card.designated(player) end

-- 最近一次某名字的 RPC（saveShipList 连着发 setAutoShips + reportRoster ✓）
local function lastRPC(name)
    for i = #RPC, 1, -1 do
        if RPC[i].name == name then return RPC[i] end
    end
    return nil
end

-- 客户端记下的那次 setAutoShips，在服务端**真的**跑一遍（引擎就是这么做的 ✓）
local function applyLastSetAutoShips()
    local call = lastRPC("setAutoShips")
    if call == nil then return false end
    Panel.setAutoShips(call.args[1], call.args[2], call.args[3])
    return true
end

-- ---------------------------------------------------------------------------
-- ① 布局：5 列 + 列头 + 不越界
-- ---------------------------------------------------------------------------
print("== ① 布局：5 列 / 列头和列宽一致 / 控件不越界 ==")
Panel.buildPanel()

local list = Panel.shipList
check("① 列表列数 = 5", list.columns == 5, tostring(list.columns))

local widthSum = 0
for i = 0, list.columns - 1 do widthSum = widthSum + (list.widths[i] or 0) end
check("① 列宽和 = PANEL_WIDTH-20（420）", widthSum == 420, tostring(widthSum))

-- 列头 = 前 5 个 11 号字（后面两个 11 号字是「名单自检行」和「说明行」✓）
local headers = {}
for _, l in ipairs(created.labels) do
    if l.fontSize == 11 and l.rect ~= nil and #headers < 5 then headers[#headers + 1] = l end
end
check("① 11 号列头 = 5 个", #headers == 5, tostring(#headers))

local aligned = true
local x = list.rect.lower.x
for i, l in ipairs(headers) do
    if math.abs(l.rect.lower.x - x) > 0.001 then aligned = false end
    if l.caption == nil or l.caption == "" then aligned = false end
    x = x + (list.widths[i - 1] or 0)
end
check("① 每个列头的 x 与列宽累加一致、且都有文字", aligned, "")

local inside = true
local worst = 0
for _, group in ipairs({ created.labels, created.buttons, created.checkboxes, created.lists }) do
    for _, e in ipairs(group) do
        if e.rect ~= nil then
            if e.rect.lower.y < 9 then inside = false end
            if e.rect.upper.y > 580 then inside = false end
            if e.rect.upper.y > worst then worst = e.rect.upper.y end
        end
    end
end
check("① 所有控件都在 590 高的面板内", inside, "最低边 = " .. tostring(worst))

-- ---------------------------------------------------------------------------
-- ② 刷新：第 0 列勾 / 第 1 列文字 = 同一个名单
-- ---------------------------------------------------------------------------
print("== ② 刷新：第 0 列勾 / 第 1 列文字 = 同一个名单 ==")
Panel.refreshShipList()

-- 行序 = 船名排序
local rowOf = {}
for i = 0, list.rows - 1 do rowOf[list:getEntry(2, i)] = i end

check("② 行数 = 9", list.rows == 9, tostring(list.rows))
check("② Miner-00001 第 0 列 = checked", list:getEntry(0, rowOf["Miner-00001"]) == "checked", "")
check("② Scout-00001 第 0 列 = 空（没勾）", list:getEntry(0, rowOf["Scout-00001"]) == "", "")
check("② Miner-00001 第 1 列文字 = Taken over",
    tostring(list:getEntry(1, rowOf["Miner-00001"])):find("Taken over", 1, true) ~= nil,
    tostring(list:getEntry(1, rowOf["Miner-00001"])))
check("② Scout-00001 第 1 列文字 = Not taken over",
    tostring(list:getEntry(1, rowOf["Scout-00001"])):find("Not taken over", 1, true) ~= nil,
    tostring(list:getEntry(1, rowOf["Scout-00001"])))

local names = designated()
check("② 插件同源名单 = 4（与真机 designated:4 一致）", #names == 4, tostring(#names))
check("② 名单里就是那 4 艘", table.concat(names, ",") ==
    "Miner-00001,Miner-00002,Salvager-00001,Trader-00001", table.concat(names, ","))

-- ---------------------------------------------------------------------------
-- ③ 勾选一艘 → 落盘 → 插件名单跟着变；取消勾选 → 立刻消失
-- ---------------------------------------------------------------------------
print("== ③ 勾选 / 取消勾选 → 插件 designated 跟着变 ==")
list:toggle(0, rowOf["Scout-00001"])
Panel.onShipToggled()

check("③ 回调发出了 setAutoShips", lastRPC("setAutoShips") ~= nil, tostring(#RPC))
check("③ 服务端真的执行一次", applyLastSetAutoShips(), "")

names = designated()
check("③ 勾上 Scout-00001 后 designated = 5", #names == 5, tostring(#names))
local has = false
for _, n in ipairs(names) do if n == "Scout-00001" then has = true end end
check("③ Scout-00001 在名单里", has, table.concat(names, ","))
check("③ 第 1 列文字同步变成 Taken over",
    tostring(list:getEntry(1, rowOf["Scout-00001"])):find("Taken over", 1, true) ~= nil,
    tostring(list:getEntry(1, rowOf["Scout-00001"])))

-- 重新刷新（= 面板下次打开）后仍然一致 ✓
Panel.refreshShipList()
check("③ 重新刷新后 Scout-00001 仍勾着", list:getEntry(0, rowOf["Scout-00001"]) == "checked", "")

-- 再取消
list:toggle(0, rowOf["Scout-00001"])
Panel.onShipToggled()
applyLastSetAutoShips()

names = designated()
check("③ 取消勾选后 designated 回到 4", #names == 4, tostring(#names))
has = false
for _, n in ipairs(names) do if n == "Scout-00001" then has = true end end
check("③ Scout-00001 立刻不在名单里", has == false, table.concat(names, ","))

-- ---------------------------------------------------------------------------
-- ④ 任务列写的是**真目标**，不是没人读的 cfg.target
-- ---------------------------------------------------------------------------
print("== ④ 任务列：写进 copilot_goal_kind_<船>（goal.lua）==")
-- ★ 关键反证：cfg 里 Miner-00001 明明写着 `Mine`（见 VALUES["copilot_auto_cfg"]），
--   但**真目标**是空的 → 列里必须显示「不指派」。只有这样才证明面板读的是 goal.lua、
--   没有去读那个没人消费的 cfg.target ✓✓
check("④ 初始显示不是 Mine（证明读 goal.lua 而非 cfg.target）",
    tostring(list:getEntry(4, rowOf["Miner-00001"])) ~= "Mine",
    tostring(list:getEntry(4, rowOf["Miner-00001"])))
check("④ 初始真目标为空", #Goal.get(player, "Miner-00001").options == 0,
    table.concat(Goal.get(player, "Miner-00001").options, ","))

-- 点第一下："" 的下一档 = Mine
list.selected = rowOf["Miner-00001"]
Panel.onShipSelected()
applyLastSetAutoShips()
check("④ 点一下 → 真目标 Mine", Goal.get(player, "Miner-00001").options[1] == "Mine",
    tostring(Goal.get(player, "Miner-00001").options[1]))
check("④ 显示同步 Mine", tostring(list:getEntry(4, rowOf["Miner-00001"])) == "Mine",
    tostring(list:getEntry(4, rowOf["Miner-00001"])))
check("④ 名单没被目标操作改动（仍 4 艘）", #designated() == 4, tostring(#designated()))

-- 再点 → Salvage
list.selected = rowOf["Miner-00001"]
Panel.onShipSelected()
applyLastSetAutoShips()
check("④ 再点一次循环到 Salvage", Goal.get(player, "Miner-00001").options[1] == "Salvage",
    tostring(Goal.get(player, "Miner-00001").options[1]))

-- ★ 多选项保护：API 写进来的 `Mine + Sell`，不能被"点了一个勾"的保存覆盖成单选 ✗
Goal.setOptions(player, "Salvager-00002", { "Mine", "Sell" })
Panel.refreshShipList()
list:toggle(0, rowOf["Scout-00001"])
Panel.onShipToggled()
applyLastSetAutoShips()
local multi = Goal.get(player, "Salvager-00002").options
check("④ 碰勾不会覆盖 API 写的多选项目标", #multi == 2 and multi[1] == "Mine" and multi[2] == "Sell",
    table.concat(multi, ","))
-- 收尾：把 Scout 的勾改回去（保持 4 艘）
list:toggle(0, rowOf["Scout-00001"])
Panel.onShipToggled()
applyLastSetAutoShips()

-- 循环一整圈（Salvage→Trade→Travel→Sell→Scout→Refine→不指派）
for _ = 1, 6 do
    list.selected = rowOf["Miner-00001"]
    Panel.onShipSelected()
    applyLastSetAutoShips()
end
check("④ 循环一整圈后回到「不指派」", #Goal.get(player, "Miner-00001").options == 0,
    table.concat(Goal.get(player, "Miner-00001").options, ","))

-- ---------------------------------------------------------------------------
-- ⑤ 只读自检行：reportRoster 回执 = card.designated
-- ---------------------------------------------------------------------------
print("== ⑤ 面板底部自检行 ==")
local call = lastRPC("reportRoster")
if call ~= nil then Panel.reportRoster() end
Panel.refreshRosterReport()

local report = tostring(VALUES["copilot_roster_report"] or "")
local count = report:match("^(%d+)|")
check("⑤ reportRoster 回执里艘数 = 4", tonumber(count) == 4, report)
check("⑤ 自检行文字含「4 / 4」且打 ✓",
    tostring(Panel.rosterLabel.caption):find("4 / 4", 1, true) ~= nil and
    tostring(Panel.rosterLabel.caption):find("✓", 1, true) ~= nil,
    tostring(Panel.rosterLabel.caption))

-- ---------------------------------------------------------------------------
print("")
if failures == 0 then
    print(string.format("OK: %d checks, 0 failure(s)", checks))
else
    print(string.format("FAILED: %d checks, %d failure(s)", checks, failures))
    os.exit(1)
end
