-- _panel_roster_selftest.lua —— 面板「舰船列表」↔ 插件名单 的离线自检（2026-10-19 加 ✓✓）
--
-- 起因（主人真机报告）：「面板第 0 列一个勾都没有」，而 `fleet_query {what:list}` 回
-- `designated: 4`。真机截图查明：这 4 艘船**其实都打着勾**，只是 ListBoxEx 的 CheckBox
-- 把「已勾」画成**实心方块**、没有 ✓ 号 → 肉眼读成"没勾" ✗。
--
-- 本自检不开游戏，把面板脚本 `data/scripts/player/ui/panel.lua` **原样加载**
-- （UI / Player 全部换成内存替身），然后真的走一遍：
--
--   ① 布局：4 列、列宽和 = PANEL_WIDTH-20（600）、4 个列头文字、所有控件不越界 ✓
--      ★ 2026-10-19 第三次修正：删掉「本船自驾」死列 → 4 列；窗口加宽 440 → 620（任务列 350）；
--        目标输入框从单行 TextBox → 原版**多行** MultiLineTextBox（宽 600 / 高 100）✓
--   ② 勾选同源：第 0 列 = `copilot_auto_ships`，第 1 列 = 它的文字镜像 ✓
--   ③ 勾选一舥 → `setAutoShips` 落盘 → `card.lua` 的 `designated` 跟着 +1；取消 → 立刻消失 ✓
--   ④ 任务列写的是**真目标** `copilot_goal_kind_<船>`（goal.lua），不是没人读的 cfg.target ✓
--   ⑤ 只读自检行：`reportRoster` 回执 = `card.lua` 的 `designated` ✓
--
-- 跑法（在仓库根执行）：
--   build\harness\lua.exe native\harness\_panel_roster_selftest.lua

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

local created = { labels = {}, buttons = {}, checkboxes = {}, lists = {}, textboxes = {} }

local function newWindow()
    -- ★ closeableWithEscape：Avorion 窗口**没有** onCloseFunction ✗
    --   ESC 能不能关窗只看这个属性（`Documentation/Window.html:363` ✓）
    local w = { visible = false, caption = "", moveable = false, showCloseButton = false,
                closeableWithEscape = false }
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
    -- ★ 目标的**自然语言输入框**（主人 2026-10-19 要的 ✓）
    function w:createTextBox(rect, callback)
        local t = { rect = rect, text = "", callback = callback, kind = "TextBox" }
        created.textboxes[#created.textboxes + 1] = t
        return t
    end
    -- ★★ 原版**多行**输入控件（`Documentation/MultiLineTextBox.html` ✓）——
    --    面板第三次修正后用的就是它，不再是单行 TextBox ✓✓
    function w:createMultiLineTextBox(rect, callback)
        local t = { rect = rect, text = "", callback = callback, kind = "MultiLineTextBox" }
        created.textboxes[#created.textboxes + 1] = t
        return t
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
-- ① 布局：4 列 + 列头 + 多行目标框 + 不越界
-- ---------------------------------------------------------------------------
print("== ① 布局：4 列 / 列头和列宽一致 / 多行目标框 / 控件不越界 ==")
Panel.buildPanel()

-- panel.lua 的几何常量（两个都是文件内 local，这里按源码同步 ✓）
local PANEL_WIDTH, PANEL_HEIGHT = 620, 782

local list = Panel.shipList
check("① 列表列数 = 4（「本船自驾」死列已删）", list.columns == 4, tostring(list.columns))

local widthSum = 0
for i = 0, list.columns - 1 do widthSum = widthSum + (list.widths[i] or 0) end
check("① 列宽和 = PANEL_WIDTH-20（600）", widthSum == PANEL_WIDTH - 20, tostring(widthSum))
check("① 任务列 = 350px（原来 110px，约 3 倍）", list.widths[3] == 350, tostring(list.widths[3]))

-- 列头 = 前 4 个 11 号字（后面几个 11 号字是「目标框标题」「名单自检行」「说明行」✓）
local headers = {}
for _, l in ipairs(created.labels) do
    if l.fontSize == 11 and l.rect ~= nil and #headers < 4 then headers[#headers + 1] = l end
end
check("① 11 号列头 = 4 个", #headers == 4, tostring(#headers))

local aligned, captions = true, {}
local x = list.rect.lower.x
for i, l in ipairs(headers) do
    if math.abs(l.rect.lower.x - x) > 0.001 then aligned = false end
    if l.caption == nil or l.caption == "" then aligned = false end
    captions[#captions + 1] = tostring(l.caption)
    x = x + (list.widths[i - 1] or 0)
end
check("① 每个列头的 x 与列宽累加一致、且都有文字", aligned, "")
check("① 列头 = OK / Take-over / Ship / Task（没有 Auto/P ✓）",
    table.concat(captions, "|") == "OK|Take-over|Ship|Task", table.concat(captions, "|"))

-- ★★ 说明区：**一行一个 Label**（2026-10-19 第四次修正 ✓）
--   旧版是**一个** 11 号 Label 里塞 3 行、单行 200+ 字符的长文本 ——
--   `Label` 放不下时是**整体缩字**而不是换行 ✗ → 真机上被缩成 5px 糊字 ✗✓。
--   这里锁死：4 个独立 Label、每行都短、且不含换行符（= 不会再触发缩字 ✓）。
local hintLabels = {}
for _, l in ipairs(created.labels) do
    local c = tostring(l.caption or "")
    if l.fontSize == 11 and (c:sub(1, 7) == "Column " or c:sub(1, 4) == "RPC:") then
        hintLabels[#hintLabels + 1] = l
    end
end
check("① 说明区 = 4 个独立 Label（不再是一个大 Label ✓）", #hintLabels == 4,
    tostring(#hintLabels))

local hintOk, longest = true, 0
for _, l in ipairs(hintLabels) do
    local c = tostring(l.caption)
    if #c > 100 or c:find("\n", 1, true) ~= nil then hintOk = false end
    if #c > longest then longest = #c end
end
check("① 每条说明 <=100 字符且不含换行（不触发 Label 缩字 ✓）", hintOk,
    "最长 = " .. tostring(longest))

-- ★★ 目标输入框：**原版多行控件**、宽度撑满、约 4~6 行 ✓（第三次修正的核心 ✓）
local box = Panel.goalEditBox
check("① 目标输入框是原版多行控件 createMultiLineTextBox",
    box ~= nil and box.kind == "MultiLineTextBox", tostring(box and box.kind))
if box ~= nil then
    local rect = box.rect
    local boxWidth = rect.upper.x - rect.lower.x
    local boxHeight = rect.upper.y - rect.lower.y
    check("① 目标输入框撑满面板宽度（= PANEL_WIDTH-20）", boxWidth == PANEL_WIDTH - 20,
        tostring(boxWidth))
    check("① 目标输入框高度 ≈ 4~6 行（80..130px）", boxHeight >= 80 and boxHeight <= 130,
        tostring(boxHeight))
    local save = Panel.goalSaveButton
    check("① 「保存目标」按钮还在，且在输入框**下面**（不挤同一行）",
        save ~= nil and save.rect.lower.y >= rect.upper.y,
        tostring(save and save.rect.lower.y))
end

local inside = true
local worst = 0
for _, group in ipairs({ created.labels, created.buttons, created.checkboxes, created.lists,
                         created.textboxes }) do
    for _, e in ipairs(group) do
        if e.rect ~= nil then
            if e.rect.lower.y < 9 then inside = false end
            if e.rect.upper.y > PANEL_HEIGHT - 10 then inside = false end
            if e.rect.upper.y > worst then worst = e.rect.upper.y end
        end
    end
end
check("① 所有控件都在 " .. PANEL_HEIGHT .. " 高的面板内", inside, "最低边 = " .. tostring(worst))

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
-- ④ 任务列 = 预设（「自动」+ 多动作），写进**真目标**，不是没人读的 cfg.target
-- ---------------------------------------------------------------------------
print("== ④ 任务列：默认「自动」，指派 = 自然语言输入框 ==")
-- ★ 关键反证：cfg 里 Miner-00001 明明写着 `Mine`（见 VALUES["copilot_auto_cfg"]），
--   但**真目标**是空的 → 列里必须显示「Auto」（默认就是自动、不指派 ✓）。
--   只有这样才证明面板读的是 goal.lua、没有去读那个没人消费的 cfg.target ✓✓
check("④ 默认显示 Auto（证明读 goal.lua 而非 cfg.target）",
    tostring(list:getEntry(3, rowOf["Miner-00001"])) == "Auto",
    tostring(list:getEntry(3, rowOf["Miner-00001"])))
check("④ 默认没有文字目标（= 自动 ✓）", Goal.get(player, "Miner-00001").text == "",
    Goal.get(player, "Miner-00001").text)

-- ★ 点行**只载入输入框**，不改目标（主人要的是"自己写一句话"，不是点一下换一档 ✗✓）
list.selected = rowOf["Miner-00001"]
Panel.onShipSelected()
check("④ 点行不改目标（真目标仍是空 ✓）",
    Goal.get(player, "Miner-00001").text == "" and #Goal.get(player, "Miner-00001").options == 0, "")
check("④ 输入框装的是这艘船的目标（此刻空串）", tostring(Panel.goalEditBox.text) == "",
    tostring(Panel.goalEditBox.text))
check("④ 输入框标题写着船名",
    tostring(Panel.goalEditCaption.caption):find("Miner-00001", 1, true) ~= nil,
    tostring(Panel.goalEditCaption.caption))

-- ★★ 自然语言：写一句话 → 保存 → 真目标 text 就是它 ✓
--   ★ onGoalSavePressed 是**客户端**回调（`if not onClient() then return end`），
--     所以这里临时把 onClient 切成 true 再调用 —— 引擎里它本来就在客户端跑 ✓
local function clickSaveAsClient()
    local saved = onClient
    onClient = function() return true end
    Panel.onGoalSavePressed()
    onClient = saved
end

local SENTENCE = "去西北方挖矿，遇到敌人就先跑"
Panel.goalEditBox.text = SENTENCE
clickSaveAsClient()
local gcall = lastRPC("setShipGoalText")
check("④ 保存走 setShipGoalText（船名 + 原文）",
    gcall ~= nil and gcall.args[1] == "Miner-00001" and gcall.args[2] == SENTENCE,
    tostring(gcall and gcall.args[1]))
Panel.setShipGoalText(gcall.args[1], gcall.args[2])      -- 服务端真的执行一次 ✓
check("④ 真目标 text = 玩家写的那句话", Goal.get(player, "Miner-00001").text == SENTENCE,
    Goal.get(player, "Miner-00001").text)
check("④ 那一行同步显示这句话（超宽截断 ✓）",
    tostring(list:getEntry(3, rowOf["Miner-00001"])):find("去西北方", 1, true) ~= nil,
    tostring(list:getEntry(3, rowOf["Miner-00001"])))
check("④ 名单没被目标操作改动（仍 4 艘）", #designated() == 4, tostring(#designated()))

-- ★ 再次点行 → 输入框里装的是刚写的那句（而不是空 ✓）
list.selected = rowOf["Miner-00001"]
Panel.onShipSelected()
check("④ 再点该行：输入框回显那句话", tostring(Panel.goalEditBox.text) == SENTENCE,
    tostring(Panel.goalEditBox.text))

-- ★ 清空 = 回到「自动」
Panel.goalEditBox.text = ""
clickSaveAsClient()
gcall = lastRPC("setShipGoalText")
Panel.setShipGoalText(gcall.args[1], gcall.args[2])
check("④ 清空 → 真目标回到空（自动 ✓）", Goal.get(player, "Miner-00001").text == "",
    Goal.get(player, "Miner-00001").text)
check("④ 清空 → 那一行显示 Auto",
    tostring(list:getEntry(3, rowOf["Miner-00001"])) == "Auto",
    tostring(list:getEntry(3, rowOf["Miner-00001"])))

-- ★ 动作白名单（RPC 设的）**已退役**：任务列只显示真目标/「自动」，不再拼「限定 …」✗✓
--   （面板里的白名单 UI 已在 14d2141 删掉；旧断言还在这里要 "Limited" → 那是**陈旧断言** ✗✓）
Goal.setOptions(player, "Salvager-00002", { "Mine", "Sell" })
Panel.refreshShipList()
check("④ 动作白名单已退役：任务列不再显示「限定 …」",
    tostring(list:getEntry(3, rowOf["Salvager-00002"])):find("Limited", 1, true) == nil,
    tostring(list:getEntry(3, rowOf["Salvager-00002"])))
list:toggle(0, rowOf["Scout-00001"])
Panel.onShipToggled()
applyLastSetAutoShips()
local multi = Goal.get(player, "Salvager-00002").options
check("④ 碰勾不会覆盖 RPC 写的动作白名单", #multi == 2 and multi[1] == "Mine" and multi[2] == "Sell",
    table.concat(multi, ","))
-- 收尾：把 Scout 的勾改回去（保持 4 艘）
list:toggle(0, rowOf["Scout-00001"])
Panel.onShipToggled()
applyLastSetAutoShips()

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
-- ⑥ RPC 面板开关：`query {what="panel", action=open|close|toggle}`
--    （主人 2026-10-19 决定：不做快捷键，做接口 ✓）
--    服务端只写 seq + cmd；客户端 pollPanelCommand() 执行；再用 seq 防重复 ✓
-- ---------------------------------------------------------------------------
print("== ⑥ RPC 面板开关（服务端原子 + 客户端轮询）==")

-- link_in.lua 是命名空间脚本，加载时只定义函数 + 末尾注册（框架替身给空实现 ✓）
CopilotRpc = {
    trace = function() end,
    handle = function() end,
    caps = function() return {} end,
}
CopilotNet = { emit = function() end }
CopilotOut = { VER = 1 }
local LinkIn = dofile("data/scripts/net/link_in.lua")

-- 先把面板关掉，模拟"客户端当前不可见"（且它此前已经上报过一次 ✓）
Panel.window.visible = false
VALUES["copilot_panel_visible"] = "closed"

local ok1, res1 = LinkIn.onQuery({ what = "panel", action = "open" })
check("⑥ open 被接受", ok1 == true and res1.ok == true, tostring(res1))
check("⑥ open 写了 cmd=open", tostring(VALUES["copilot_panel_cmd"]) == "open", tostring(VALUES["copilot_panel_cmd"]))
check("⑥ open 的 seq = 1", tonumber(VALUES["copilot_panel_seq"]) == 1, tostring(VALUES["copilot_panel_seq"]))
check("⑥ 回执里的 lastKnownVisible 是客户端回报（此刻 closed）",
    tostring(res1.lastKnownVisible) == "closed", tostring(res1.lastKnownVisible))

-- 客户端每拍读一次 → 面板打开
Panel.pollPanelCommand()
check("⑥ 客户端执行后面板 = 打开", Panel.window.visible == true, tostring(Panel.window.visible))
check("⑥ 客户端已上报可见性 = open", tostring(VALUES["copilot_panel_visible"]) == "open",
    tostring(VALUES["copilot_panel_visible"]))

-- ★ 客户端→服务端那一跳必须走 callable（player value 只能服务端写 ✓）
do
    local saved = onClient
    onClient = function() return true end
    local before = #RPC
    Panel.reportPanelVisible(true)
    onClient = saved
    local rpc = RPC[#RPC]
    check("⑥ 客户端上报走的是 invokeServerFunction(reportPanelVisible)",
        #RPC == before + 1 and rpc.name == "reportPanelVisible", tostring(rpc and rpc.name))
end

-- ★ 同一拍再轮询一次：seq 没变 → 不许重复执行（否则 open 会被反复 toggle ✓）
local stillOpen = Panel.window.visible
Panel.pollPanelCommand()
check("⑥ 同一 seq 轮询两次不会重复执行", Panel.window.visible == stillOpen, tostring(Panel.window.visible))

-- 关
local ok2, res2 = LinkIn.onQuery({ what = "panel", action = "close" })
check("⑥ close 被接受且 seq = 2", ok2 == true and tonumber(VALUES["copilot_panel_seq"]) == 2,
    tostring(VALUES["copilot_panel_seq"]))
check("⑥ close 的 lastKnownVisible = open（上一拍客户端报的 ✓）",
    tostring(res2.lastKnownVisible) == "open", tostring(res2.lastKnownVisible))
Panel.pollPanelCommand()
check("⑥ 客户端执行后面板 = 关闭", Panel.window.visible == false, tostring(Panel.window.visible))

-- toggle
LinkIn.onQuery({ what = "panel", action = "toggle" })
Panel.pollPanelCommand()
check("⑥ toggle → 打开", Panel.window.visible == true, tostring(Panel.window.visible))
LinkIn.onQuery({ what = "panel" })          -- 缺省 = toggle ✓
Panel.pollPanelCommand()
check("⑥ 缺省 action = toggle（→ 关闭）", Panel.window.visible == false, tostring(Panel.window.visible))

-- 非法动作
local badOk, badCode, badWhy = LinkIn.onQuery({ what = "panel", action = "explode" })
check("⑥ 非法 action 被拒（BAD_REQUEST）", badOk == false and badCode == "BAD_REQUEST",
    tostring(badCode) .. " / " .. tostring(badWhy))
check("⑥ 被拒时不推进 seq", tonumber(VALUES["copilot_panel_seq"]) == 4,
    tostring(VALUES["copilot_panel_seq"]))

-- caps 自我声明里有 panel
local _, caps = LinkIn.onQuery({ what = "caps" })
local hasPanel = false
for _, w in ipairs(caps.what or {}) do if w == "panel" then hasPanel = true end end
check("⑥ caps.what 里声明了 panel", hasPanel, "")

-- ---------------------------------------------------------------------------
-- ⑦ ESC 关窗（2026-10-19，主人原话：「这个界面不吃 ESC…要做成 HOOK 住 ESC 键」）
--
-- ★ 先纠正一个**错误前提**：Avorion 的窗口类**没有** `onCloseFunction`
--   （`Documentation/Window.html` 全文 0 处、全原版脚本 0 处引用 ✗✓）。
--   ESC 关窗的真实开关是 **`Window.closeableWithEscape`**（`Window.html:363-365`），
--   原版用法：`player/ui/diplomacy.lua:1012` / `entity/merchants/researchstation.lua:141`。
--
-- ★ 离线能验的一半：属性挂上 ✓ + 关窗路径（引擎 hide）幂等 ✓ + 关后 visible=false ✓
--   + 可见性补报 ✓。ESC 按键本身由引擎处理，替身模拟不了 → 真机结论在报告里 ✓
-- ---------------------------------------------------------------------------
print("== ⑦ ESC 关窗（closeableWithEscape + 幂等关闭路径 + 补报）==")
check("⑦ 主面板窗口 closeableWithEscape = true（根因就是缺它）",
    Panel.window.closeableWithEscape == true, tostring(Panel.window.closeableWithEscape))

-- 引擎处理 ESC 的动作 = window:hide()（和 X 按钮同一条路径 ✓，不会销毁窗口）
-- 故意把回报值留成旧值 "open" → 证明补报会纠正它 ✓
Panel.lastVisibleReport = true
VALUES["copilot_panel_visible"] = "open"

local savedClient = onClient
onClient = function() return true end

local before = #RPC
local okFirst = pcall(function()
    Panel.window:hide()                 -- ← 引擎的 ESC 行为
    Panel.watchPanelVisibility()
end)
local afterFirst = #RPC
local escCall = lastRPC("reportPanelVisible")

local okSecond = pcall(function()
    Panel.window:hide()                 -- ← 再按一次 ESC（窗口本来就关着）
    Panel.watchPanelVisibility()
end)
local afterSecond = #RPC

onClient = savedClient

check("⑦ ESC 关窗（hide）后 isVisible = false", Panel.window.visible == false,
    tostring(Panel.window.visible))
check("⑦ 连按两次 ESC 都不报错（幂等）", okFirst and okSecond,
    tostring(okFirst) .. " / " .. tostring(okSecond))
check("⑦ 第一次 ESC 补报 reportPanelVisible(false)",
    escCall ~= nil and escCall.args[1] == false,
    tostring(escCall and escCall.args[1]))
check("⑦ 第二次 ESC 不重复发 RPC（只在可见性变化时报 ✓）", afterSecond == afterFirst,
    tostring(afterFirst) .. " -> " .. tostring(afterSecond))

-- 服务端真的执行一次（玩家 value 只能服务端写 ✓）
Panel.reportPanelVisible(false)
check("⑦ 服务端回报值 = closed（RPC 回执不再说假话 ✓）",
    tostring(VALUES["copilot_panel_visible"]) == "closed",
    tostring(VALUES["copilot_panel_visible"]))

-- 关了还能再开，再关仍不报错（关闭路径可重复走 ✓）
Panel.togglePanel()
check("⑦ 重新打开后 isVisible = true", Panel.window.visible == true,
    tostring(Panel.window.visible))
Panel.window:hide()
Panel.watchPanelVisibility()
check("⑦ 再次关闭仍不报错且 isVisible = false", Panel.window.visible == false,
    tostring(Panel.window.visible))

-- ★ 子窗口（炮塔底座材料）也要吃 ESC，否则 ESC 会跳过它去关下面的主面板 ✗
Panel.buildMountsWindow()
check("⑦ 炮塔底座子窗口 closeableWithEscape = true",
    Panel.mountsWindow ~= nil and Panel.mountsWindow.closeableWithEscape == true,
    tostring(Panel.mountsWindow and Panel.mountsWindow.closeableWithEscape))
Panel.mountsWindow:hide()

-- ---------------------------------------------------------------------------
-- ⑧ ★★ 面板**关着**时不做面板数据轮询（2026-10-22 加 —— 服务端模拟掉帧排查 ✓）
--
-- 任务书 §4 最想省的那一刀：「面板没打开时不做面板数据轮询」✗→✓
--   · `updateClient` 每 1 秒被引擎调一次（`getUpdateInterval` = 1 ✓）；
--   · 面板数据（Autopilot 开关/状态、名单自检行）只有**看得见**时才有意义 ✓；
--   · 但 RPC 面板开关**必须一直跑**（它正是用来把面板打开的 ✗→✓）——
--     所以本节的断言是「**数据刷新**归零」，不是「整个 updateClient 归零」✓✓
--
-- 真机意义：面板关着时，服务端这边不该因为面板而多花任何一次读 ✓
-- ---------------------------------------------------------------------------
print("== ⑧ 面板关着时不刷新面板数据（面板开关的 RPC 仍然照跑 ✓）==")
do
    -- 防止 pollPanelCommand 读到"命令序号"而顺手开关窗（替身里没有这个 value ✓）
    Panel.panelCmdSeq = 999999

    local refreshCount, rosterCount, mountsCount = 0, 0, 0
    local realRefresh, realRoster, realMounts =
        Panel.refresh, Panel.refreshRosterReport, Panel.refreshMounts
    Panel.refresh = function(...) refreshCount = refreshCount + 1; return realRefresh(...) end
    Panel.refreshRosterReport = function(...) rosterCount = rosterCount + 1; return realRoster(...) end
    if realMounts ~= nil then
        Panel.refreshMounts = function(...) mountsCount = mountsCount + 1; return realMounts(...) end
    end

    Panel.window:hide()
    if Panel.mountsWindow ~= nil then Panel.mountsWindow:hide() end
    local okClosed = pcall(function()
        for _ = 1, 5 do Panel.updateClient(0.016) end
    end)
    check("⑧ 面板关着：5 拍不报错", okClosed, tostring(okClosed))
    check("⑧ 面板关着：refresh 调用 **0** 次", refreshCount == 0, tostring(refreshCount))
    check("⑧ 面板关着：refreshRosterReport 调用 **0** 次", rosterCount == 0, tostring(rosterCount))
    check("⑧ 面板关着：refreshMounts 调用 **0** 次", mountsCount == 0, tostring(mountsCount))
    check("⑧ 面板关着：窗口没有被 updateClient 打开（它无权开关 ✓）",
        Panel.window.visible == false, tostring(Panel.window.visible))

    Panel.window:show()
    local okOpen = pcall(function()
        for _ = 1, 3 do Panel.updateClient(0.016) end
    end)
    check("⑧ 面板打开：3 拍不报错", okOpen, tostring(okOpen))
    check("⑧ 面板打开：refresh 每拍 1 次（3 拍 = 3 次）", refreshCount == 3, tostring(refreshCount))
    check("⑧ 面板打开：refreshRosterReport 每拍 1 次（3 拍 = 3 次）",
        rosterCount == 3, tostring(rosterCount))

    -- 关掉之后**下一拍**就该停（不是等几秒 ✓）
    Panel.window:hide()
    local frozen = refreshCount
    Panel.updateClient(0.016)
    check("⑧ 关窗后下一拍立刻停止刷新", refreshCount == frozen, tostring(refreshCount))

    Panel.refresh, Panel.refreshRosterReport, Panel.refreshMounts =
        realRefresh, realRoster, realMounts
end

-- ---------------------------------------------------------------------------
print("")
if failures == 0 then
    print(string.format("OK: %d checks, 0 failure(s)", checks))
else
    print(string.format("FAILED: %d checks, %d failure(s)", checks, failures))
    os.exit(1)
end
