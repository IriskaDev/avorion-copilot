
package.path = package.path .. ";data/scripts/lib/?.lua"

include("callable")

-- Copilot UI
--
-- The round robot button in the top right corner opens a panel. The panel holds
--
--   * the autopilot switches for the ship you are flying (copilot_enabled / copilot_explore)
--   * the list of ships the AI is allowed to operate on its own
--
-- The ship list is the important part: only ships ticked there are ever handed to the AI
-- layer; everything else is left alone.
--
-- Don't remove or alter the following comment, it tells the game the namespace this script lives in. If you remove it, the script will break.
-- namespace CopilotUI
CopilotUI = CopilotUI or {}

-- 热重载友好：绝不写成 CopilotUI = {}，否则重载会把控件引用和 builtOnce 一起清掉。
local self = CopilotUI

-- Draw a self-made round button in the top right corner, aligned with the vanilla icon row.
-- The vanilla row is drawn by the engine and cannot be extended from Lua (verified: both
-- PlayerWindow():createTab and ShipWindow():createTab return a valid tab without adding an
-- icon to the strip), so the button is drawn by hand at the measured geometry of that row.
local SHOW_HUD_BUTTON = true

-- Make the button follow the vanilla row's visibility. The row is an on-demand bar: outside
-- direct flight it is always on screen, while flying it only shows up while SHIFT is held or
-- one of the game's windows is open.
local FOLLOW_VANILLA_VISIBILITY = true

-- Startup logging to the client/server log (diagnostic).
local DEBUG = false

-- ★★ 面板开关 = **RPC 原子**（2026-10-19，主人决定，不做快捷键 ✗）
--   `query {what="panel", action="open"|"close"|"toggle"}` → net/link_in.lua 写 player value
--   → 客户端 `CopilotUI.pollPanelCommand()` 执行 ✓（说明见那个函数上方）

-- Panel geometry (pixels). The content is laid out with a UIVerticalLister, so the height
-- has to fit every row below with room to spare.
local PANEL_WIDTH = 440
-- ★ 2026-10-19：列头行 + 名单自检行 + 说明行(4 行) + **目标输入框行** → 500 → 590 → 606 → 658
local PANEL_HEIGHT = 658

-- Human readable version of Copilot.state (published by the server side brain).
-- Translated through the game's own language setting: %_t looks the string up in
-- data/localization/<language>.po, and this mod ships its own zh.po for that.
-- ★ 为什么是函数而不是顶层表：顶层写 `"Idle"%_t` 时，`/copilot reload` 用 load() 重执行
--   文件体会把它当**取模运算** → "attempt to perform arithmetic on a string value" ✗
--   （2026-10-17 实测：panel.lua 每次 reload 都挂在这一行）。
--   移进函数体后，文件体可以安全重执行；真脚本 VM 里由引擎把 %_t 变成本地化字面量 ✓。
local function stateTextTable()
    return {
        idle    = "Idle"%_t,
        combat  = "Engaging hostiles"%_t,
        mine    = "Mining asteroids"%_t,
        salvage = "Salvaging wreckage"%_t,
        full    = "Cargo full, parked"%_t,
        explore = "Jumping to a new sector"%_t,
        empty   = "Sector cleared, waiting"%_t,
    }
end

self.window = nil
self.statusLabel = nil
self.stateLabel = nil
self.toggleButton = nil
self.exploreCheckBox = nil
self.shipList = nil
self.rosterLabel = nil          -- ★ 名单自检行（面板 N / 服务端 M）✓
self.shipRows = nil             -- ★ 每行缓存：{ name, auto, goal, goalOptions } ✓
self.mirrorGuard = false        -- ★ 勾→文字镜像 的防重入标志 ✓
self.panelCmdSeq = 0            -- ★ 已执行到哪一条 RPC 面板命令（单调序号 ✓）
self.goalEditShip = nil         -- ★ 目标输入框当前编辑的船名（点行设置 ✓）
self.goalEditRow = nil          -- ★ 那一行的下标（保存后回写显示 ✓）
self.goalEditText = nil         -- ★ 输入框里的文字（读出来给缓存 ✓）
self.hintLabel = nil

self.hudContainer = nil
self.hudButton = nil
self.hudVisible = nil

-- Registering the window with Hud():addMouseShowingWindow is what releases the mouse for UI
-- interaction; without it the game keeps steering the ship and the player has to hold SHIFT
-- to use the panel. Only done once, right after the window is first shown.
self.mouseRegistered = false

self.enabled = false
self.explore = false
self.state = nil

-- The switches are changed on the server, so a click only becomes visible in the player
-- values one round trip later. Until the server confirms, keep showing what the player just
-- clicked instead of snapping back to the stale value.
self.enabledPending = false
self.explorePending = false

-- ---------------------------------------------------------------------------
-- the list of AI operated ships is stored as a newline separated string in a player value.
-- A string is used on purpose: player:setValue is only proven for simple values, and no
-- vanilla script stores a table in one.
-- ---------------------------------------------------------------------------

local function decodeShipSet(text)
    local set = {}
    if not text then return set end
    for name in tostring(text):gmatch("[^\n]+") do
        if name ~= "" then set[name] = true end
    end
    return set
end

local function encodeShipSet(set)
    local names = {}
    for name in pairs(set) do
        table.insert(names, name)
    end
    table.sort(names)
    return table.concat(names, "\n")
end

-- Client -------------------------------------------------------------------

function CopilotUI.initialize()
    if onClient() then
        -- 热重载守卫：下面三件事各自只能做一次。
        --
        -- UIElement 没有销毁 API（只有 show/hide），重复执行会多出一个面板、一个 HUD 按钮，
        -- 还会重复注册每帧回调。所以只在首次执行。
        --
        -- 但界面**不必**重建也能用上新代码：引擎是按名字查表调用
        -- （CopilotUI.buildPanel 等），而 /copilot reload 会重新执行本文件、
        -- 把表里的函数实现整体换掉。
        --
        -- 前提是本文件开头写成 CopilotUI = CopilotUI or {}，不能清空表，
        -- 否则控件引用与这个标志会一起丢掉，守卫就失效了。
        if not CopilotUI.builtOnce then
            CopilotUI.builtOnce = true

            -- Called once per rendered frame. The vanilla icon row appears the instant SHIFT
            -- goes down, so a once-per-second poll would always look laggy; this keeps our
            -- button in step with it.
            Player():registerCallback("onPreRenderHud", "onPreRenderHud")

            CopilotUI.buildPanel()
            CopilotUI.buildHudButton()
        end

        CopilotUI.refresh()
    end
end

function CopilotUI.onPreRenderHud(state)
    CopilotUI.updateHudButtonVisibility()
end

-- ---------------------------------------------------------------------------
-- ★★ 面板开关由 **RPC 原子** 控制（2026-10-19，主人决定：不做快捷键）✓✓
--
-- 通道：服务端 `query {what="panel", action="open"|"close"|"toggle"}`（见 net/link_in.lua）→
--   写两个 player value → 客户端在这里每拍读一次并执行 ✓
--   · `copilot_panel_seq`  单调序号（同一条命令重复发也能再触发 ✓ —— 用序号而不是状态位，
--     否则"关了再 open"会被误判成"已经是 open 了" ✗✓）
--   · `copilot_panel_cmd`  动作名（open / close / toggle）
--   · `copilot_panel_visible` 是**客户端回报**给服务端的实际可见性（RPC 回执里能看到 ✓）
--
-- 为什么客户端只轮询不反向调用：面板是玩家脚本，服务端原子只需写值 ✓；
-- 反过来（客户端→服务端）用 invokeServerFunction 上报可见性 ✓（和 reportRoster 同一套）。
-- 1 Hz（getUpdateInterval）足够 —— 这是界面开关，不是实时输入 ✓。
-- ---------------------------------------------------------------------------
function CopilotUI.pollPanelCommand()
    local player = Player()
    if not player then return end

    local seq = tonumber(player:getValue("copilot_panel_seq") or 0) or 0
    if seq <= (self.panelCmdSeq or 0) then return end
    self.panelCmdSeq = seq

    local action = tostring(player:getValue("copilot_panel_cmd") or "")
    local visible = self.window ~= nil and self.window.visible == true

    if action == "open" then
        if not visible then CopilotUI.togglePanel() end
    elseif action == "close" then
        if visible then CopilotUI.togglePanel() end
    else
        CopilotUI.togglePanel()      -- toggle（含未知值：按 toggle 处理，绝不静默吞掉 ✓）
    end
end

function CopilotUI.getUpdateInterval()
    return 1
end

function CopilotUI.updateClient(timeStep)
    -- ★ RPC 面板开关：**面板关着时也要跑** ✓（它正是用来把面板打开的 ✗→✓）
    CopilotUI.pollPanelCommand()

    -- the labels only need updating while the panel is open; the ship list is rebuilt when
    -- the panel is opened so it never fights with the player's clicks
    if self.window and self.window.visible then
        CopilotUI.refresh()
        -- ★ 只刷新底部那行「面板 N / 服务端 M」自检（不重建列表，免得和玩家的点击打架）✓
        CopilotUI.refreshRosterReport()
    end

    -- 炮塔底座面板：只在它开着时同步服务端给的报价/结果（服务端只在按钮/选船时算 ✓）
    if self.mountsWindow and self.mountsWindow.visible then
        CopilotUI.refreshMounts()
    end

    CopilotUI.updateHudButtonVisibility()
end

-- ---------------------------------------------------------------------------
-- panel
-- ---------------------------------------------------------------------------

-- 列布局（宽度之和必须 = PANEL_WIDTH - 20，即 lister 的左右各 10px）✓
-- ★ 必须定义在 buildPanel **之前**：local 的作用域从声明处开始，放后面会被当成 nil 全局 ✗✓
-- （2026-10-19 harness 抓到的真 bug：`attempt to call global 'shipColumns' (a nil value)`）
local function shipColumns()
    return {
        { width = 26,  header = "OK"%_t,
          tooltip = "Tick here = hand this ship to the AI. This is the roster the plugin reads."%_t },
        { width = 84,  header = "Take-over"%_t,
          tooltip = "Read-only mirror of column 1, spelled out (the tick itself renders as a filled box)."%_t },
        { width = 140, header = "Ship"%_t },
        { width = 60,  header = "Auto/P"%_t,
          tooltip = "The ship's own autopilot flag (copilot_auto_cfg). Stored only - the decision layer does not read it yet."%_t },
        { width = 110, header = "Task"%_t,
          tooltip = "The ship's real goal. Default = Auto (nothing assigned: the AI decides from the ship's class and equipment). To assign, click a row and type a sentence below (stored as copilot_goal_<ship>). A read-only action whitelist set over RPC shows as 'Limited'."%_t },
    }
end

function CopilotUI.buildPanel()
    local res = getResolution()
    local size = vec2(PANEL_WIDTH, PANEL_HEIGHT)
    local lower = vec2(res.x * 0.5 - size.x * 0.5, res.y * 0.5 - size.y * 0.5)

    local window = Hud():createWindow(Rect(lower, lower + size))
    self.window = window
    window.caption = "Copilot"%_t
    window.moveable = true
    window.showCloseButton = true

    local lister = UIVerticalLister(Rect(vec2(10, 10), vec2(size.x - 10, size.y - 10)), 6, 0)

    self.statusLabel = window:createLabel(lister:nextRect(24), "", 16)
    self.statusLabel:setCenterAligned()

    self.stateLabel = window:createLabel(lister:nextRect(22), "", 14)
    self.stateLabel:setCenterAligned()

    self.toggleButton = window:createButton(lister:nextRect(32), "Enable"%_t, "onTogglePressed")
    self.toggleButton.tooltip = "Hand the ship you are currently flying over to the AI."%_t

    self.exploreCheckBox = window:createCheckBox(lister:nextRect(28), "Auto-explore after clearing a sector"%_t, "onExploreChecked")
    self.exploreCheckBox.tooltip = "Allow the AI to jump into neighbouring sectors once the current one is empty."%_t

    lister:nextRect(8)

    window:createLabel(lister:nextRect(22), "Ships operated by the AI"%_t, 16)

    -- ★★ 2026-10-19 重做列布局（主人真机反馈：「这列一个勾都没有」）✗→✓
    --
    -- 现场查明（真机截图 + RPC，不是推测）：
    --   · ListBoxEx 的 CheckBox 把**已勾**画成「实心方块」、未勾画成「空框」——
    --     面板里没有 ✓ 号，于是主人把那 4 个实心方块读成了「一个都没勾」✗✓
    --   · 那 4 个实心方块恰好是 Miner-00001 / Miner-00002 / Salvager-00001 / Trader-00001，
    --     与 `fleet_query {what:list}` 的 `designated: 4` **完全一致** ✓✓（同源 ✓）
    --   · 旧的「四列」里有**两个**勾选框（第 0 列名单、第 2 列 c.auto）→ 谁也说不清哪个生效 ✗
    --
    -- 所以现在是五列，**只有一个可写的勾**：
    --   [0] ✓      = 生效名单（`copilot_auto_ships`，插件 `designated` 数的就是它）✓ 唯一开关 ✓
    --   [1] 接管状态 = 上面那个勾的**文字镜像**（✓ 已接管 / — 未接管），肉眼可读 ✓
    --   [2] 舰船
    --   [3] 本船自驾 = `copilot_auto_cfg` 的 auto 字段，**只读**（全仓库无消费方 ✗ → 标"未接入"）
    --   [4] 任务     = 真目标 `copilot_goal_kind_<船名>`（goal.lua）✓，点该行循环 ✓
    local headerRect = lister:nextRect(18)
    local listRect = lister:nextRect(220)

    local columns = shipColumns()          -- 宽度之和 = PANEL_WIDTH - 20（lister 左右各 10）✓

    local list = window:createListBoxEx(listRect)
    self.shipList = list
    list.columns = #columns
    do
        local x = 0
        for i, col in ipairs(columns) do
            list:setColumnWidth(i - 1, col.width)
            local label = window:createLabel(
                Rect(vec2(headerRect.lower.x + x, headerRect.lower.y),
                     vec2(headerRect.lower.x + x + col.width, headerRect.upper.y)),
                col.header, 11)
            label.tooltip = col.tooltip
            x = x + col.width
        end
    end
    list.rowHeight = 22
    list.entriesSelectable = true
    list.onSelectFunction = "onShipSelected"

    -- ★★ 目标输入框（主人要的"自然语言"）—— 先点一艘船的行，再在这里写一句话 ✓
    self.goalEditCaption = window:createLabel(lister:nextRect(16), "", 11)
    self.goalEditCaption.caption = "Goal text: click a ship row first (empty = Auto)"%_t

    do
        local editRect = lister:nextRect(26)
        local width = editRect.upper.x - editRect.lower.x
        local boxWidth = width - 116
        self.goalEditBox = window:createTextBox(
            Rect(vec2(editRect.lower.x, editRect.lower.y),
                 vec2(editRect.lower.x + boxWidth, editRect.upper.y)),
            "onGoalSavePressed")
        self.goalEditBox.maxCharacters = 200
        self.goalSaveButton = window:createButton(
            Rect(vec2(editRect.lower.x + boxWidth + 8, editRect.lower.y),
                 vec2(editRect.upper.x, editRect.upper.y)),
            "Save goal"%_t, "onGoalSavePressed")
    end

    -- 只读自检：面板看到的名单 vs 服务端（= 插件同源）看到的名单 ✓
    self.rosterLabel = window:createLabel(lister:nextRect(18), "", 11)

    self.hintLabel = window:createLabel(lister:nextRect(74), "", 11)
    self.hintLabel.caption = "Column 1 is the ONLY switch: it is the roster the AI really uses (a tick renders as a FILLED box, column 2 spells it out).\nColumn 3 is read-only: the per-ship autopilot is stored but not wired into the decision layer yet.\nColumn 4 = Task. Default is Auto: nothing assigned, the AI decides from the ship's class and equipment. To assign, click a ship row and type a sentence in the goal box below (empty = Auto again).\nThis window can also be opened/closed over RPC: query {what=\"panel\", action=\"open\"|\"close\"|\"toggle\"}."%_t

    -- ★ 炮塔底座材料升级（2026-10-17）—— 只在**玩家点击**后才动，绝不自动 ✓
    self.mountsButton = window:createButton(lister:nextRect(30), "Turret base materials..."%_t,
        "onMountsPressed")
    self.mountsButton.tooltip = "Upgrade the material of turret bases on a ship you pick. Costs resources and credits."%_t

    -- force layout once, then hide (same order the vanilla sector overview uses)
    window:show()
    window:hide()
end

function CopilotUI.togglePanel()
    if not self.window then return end

    if self.window.visible then
        self.window:hide()
    else
        CopilotUI.refreshShipList()
        CopilotUI.refresh()
        self.window:show()

        -- Tells the HUD to keep the mouse released while this window is on screen. Without
        -- it the game keeps flying the ship and the player has to hold SHIFT to click
        -- anything. Vanilla does the same thing in
        -- data/scripts/player/missions/receivecaptainmission.lua:318.
        -- Register on EVERY open, not once.
        --
        -- A one-shot flag proved fragile: /copilot reload re-executes this file, and after a
        -- HUD rebuild the engine-side registration can be gone while the flag still says
        -- "already registered" - the panel then opens with the mouse still captured by the
        -- cockpit (no cursor, view locked) and the flag never lets us re-register.
        -- Vanilla also registers per window: data/scripts/player/missions/receivecaptainmission.lua:318
        Hud():addMouseShowingWindow(self.window)
    end

    -- ★ 上报真实可见性（服务端只读、只用于 RPC 回执里回一句"现在到底是开还是关" ✓；
    --   ★ 客户端不能直接 setValue（player value 是服务端→客户端的同步 ✓），所以走 callable ✓）
    CopilotUI.reportPanelVisible(self.window.visible and true or false)
end

-- ---------------------------------------------------------------------------
-- ship list
-- ---------------------------------------------------------------------------

-- ★★ 任务列 = **自然语言目标**（2026-10-19 主人第二次修正 ✓✓）
--
-- 主人原话：
--   「很大程度上我是让决策者根据船的分类、装备决定船做什么，我自己并不会去设定它」
--   「不是空目标叫自动，而是**默认就是自动、不指派**；如果需要能够指派，
--     最好是留个框，让玩家输入**自然语言**，而不是只给几个选项」✓✓
--
-- 所以：
--   · 默认 = **自动 / 不指派**：`copilot_goal_<船名>` 和 `copilot_goal_kind_<船名>` 都空 ✓
--     —— 决策层按船的分类 + 装备自己拍 ✓（`task.ts` 的空目标分支会明确这么告诉它 ✓）
--   · 要指派 → 面板下方**一个输入框**，写自然语言（"去西北方挖矿，遇敌就跑"）→
--     存进 `copilot_goal_<船名>`（`lib/copilot/goal.lua:41-49` 的 `M.setText` ✓）
--   · 这一列显示：有文字目标就显示它（截断）> 有动作白名单就显示「限定 …」> 否则「自动」
--   · 动作白名单（`copilot_goal_kind_`）仍然**只读显示**、只能由 RPC 设 —— 主人不要预设按钮 ✗
local function actionLabel(action)
    local known = {
        Mine = "Mine"%_t, Salvage = "Salvage"%_t, Trade = "Trade"%_t,
        Travel = "Travel"%_t, Sell = "Sell"%_t, Scout = "Scout"%_t,
        Refine = "Refine"%_t,
    }
    return known[action] or tostring(action)
end

-- ★ 目标列的**真身**是 goal.lua 的两个 per-ship player value：
--   `copilot_goal_<船名>`（自然语言 ✓）+ `copilot_goal_kind_<船名>`（换行分隔的动作白名单 ✓）
--   —— 见 `lib/copilot/goal.lua:30-38 / 41-67` ✓
--   旧代码点这一列写的是 `copilot_auto_cfg` 的 target 字段 ✗ —— 那个字段**全仓库零消费方**
--   （grep `shipConfig`：`card.lua:134` / `ops.lua:85` 两处定义，零处调用）→ 点了什么也不会发生 ✗✓
local GOAL_KIND_PREFIX = "copilot_goal_kind_"
local GOAL_TEXT_PREFIX = "copilot_goal_"

local function readShipGoalOptions(player, name)
    local raw = tostring(player:getValue(GOAL_KIND_PREFIX .. name) or "")
    local options = {}
    for line in raw:gmatch("[^\n]+") do
        options[#options + 1] = line
    end
    return options
end

local function readShipGoalText(player, name)
    return tostring(player:getValue(GOAL_TEXT_PREFIX .. name) or "")
end

-- ★ UTF-8 安全截断（Lua 的 # 数的是**字节** ✗ —— 直接 sub 会把汉字切一半 ✓修）
--   任务列只有 110px 宽，font 11 大概放得下 8 个汉字 ≈ 24 字节 ✓
local function truncateUtf8(text, limitBytes)
    local s = tostring(text or "")
    if #s <= limitBytes then return s end

    local cut = s:sub(1, limitBytes)

    -- 去掉末尾的 UTF-8 续字节（0x80..0xBF）与孤立的多字节首字节（0xC0..0xFF）
    while #cut > 0 do
        local b = cut:byte(#cut)
        if b ~= nil and (b >= 0x80 and b <= 0xBF) then
            cut = cut:sub(1, #cut - 1)
        else
            break
        end
    end
    local b = cut:byte(#cut)
    if b ~= nil and b >= 0xC0 then cut = cut:sub(1, #cut - 1) end

    return cut .. "…"
end

-- 任务列显示的优先级：**自然语言目标** > 动作白名单 > 自动 ✓
local function goalDisplay(text, options)
    local t = tostring(text or "")
    if t ~= "" then
        local shown = t:gsub("[ \t\r\n]+", " ")
        return truncateUtf8(shown, 24)
    end

    if #options > 0 then
        local labels = {}
        for _, o in ipairs(options) do labels[#labels + 1] = actionLabel(o) end
        return truncateUtf8("Limited: "%_t .. table.concat(labels, "/"), 24)
    end

    return "Auto"%_t          -- ★ 默认就是它：不指派、让决策层按分类/装备自己定 ✓
end

-- 每船配置存成 "船名|autopilot|目标" 每行一条，和名单一样是纯字符串
-- （player:setValue 对表支持未验证，见 AGENTS.md）。
-- ★ auto 现在只做**只读展示**（没人读它 ✗）；target 与真目标保持一致（rename.lua 会迁移这两份 ✓）
local function decodeShipCfg(text)
    local cfg = {}
    for line in tostring(text or ""):gmatch("[^\n]+") do
        local name, auto, target = line:match("^([^|]+)|([^|]*)|([^|]*)$")
        if name ~= nil then
            cfg[name] = { auto = (auto == "1"), target = target }
        end
    end
    return cfg
end

local function encodeShipCfg(cfg, order)
    local lines = {}
    for _, name in ipairs(order) do
        local c = cfg[name]
        if c ~= nil then
            lines[#lines + 1] = name .. "|" .. (c.auto and "1" or "0") .. "|" .. (c.target or "")
        end
    end
    return table.concat(lines, "\n")
end

-- 名单里几艘（同一个 key，用于自检行 ✓）
local function countSet(set)
    local n = 0
    for _ in pairs(set) do n = n + 1 end
    return n
end

function CopilotUI.refreshShipList()
    if not self.shipList then return end

    local player = Player()
    if not player then return end

    local auto = decodeShipSet(player:getValue("copilot_auto_ships"))
    local cfg = decodeShipCfg(player:getValue("copilot_auto_cfg"))

    -- suppress the callbacks while the list is being written
    self.shipList.onChangedFunction = ""
    self.shipList:clear()

    local names = { player:getShipNames() }
    table.sort(names)

    self.shipOrder = names
    -- 每行的缓存：勾选框状态以**列表里的勾**为准（保存时重新读），这里只存只读列与目标 ✓
    self.shipRows = {}

    for _, name in ipairs(names) do
        self.shipList:addRow()
        local row = self.shipList.rows - 1
        local c = cfg[name] or {}
        local goalOptions = readShipGoalOptions(player, name)
        local goalText = readShipGoalText(player, name)

        self.shipRows[row + 1] = {
            name = name,
            auto = c.auto and true or false,
            goalOptions = goalOptions,
            goalText = goalText,
        }

        local taken = auto[name] and true or false

        -- [0] 生效名单的勾（唯一可写）
        self.shipList:setEntry(0, row, taken and "checked" or "", false, false, ColorRGB(1, 1, 1))
        self.shipList:setEntryType(0, row, ListBoxEntryType.CheckBox)

        -- [1] 上面那个勾的文字镜像 —— 引擎把"已勾"画成实心方块、没有 ✓ 号，
        --     所以这里再写一遍，肉眼才读得出来 ✓✓
        self.shipList:setEntry(1, row, CopilotUI.takeoverText(taken), false, false,
            taken and ColorRGB(0.55, 1.0, 0.6) or ColorRGB(0.62, 0.62, 0.62))
        self.shipList:setEntryType(1, row, ListBoxEntryType.Text)

        -- [2] 船名
        self.shipList:setEntry(2, row, tostring(name), false, false, ColorRGB(0.9, 0.9, 0.9))
        self.shipList:setEntryType(2, row, ListBoxEntryType.Text)

        -- [3] 该船自己的 Autopilot：只读（决策层没接它）✗
        self.shipList:setEntry(3, row, self.shipRows[row + 1].auto and "ON"%_t or "OFF"%_t,
            false, false, ColorRGB(0.72, 0.72, 0.72))
        self.shipList:setEntryType(3, row, ListBoxEntryType.Text)

        -- [4] 任务（自然语言目标优先，其次动作白名单，否则「自动」）
        self.shipList:setEntry(4, row, goalDisplay(goalText, goalOptions), false, false,
            ColorRGB(0.7, 0.9, 1.0))
        self.shipList:setEntryType(4, row, ListBoxEntryType.Text)
    end

    self.shipList.onChangedFunction = "onShipToggled"

    -- 自检行：面板这份名单 vs 服务端（插件同源）那份 ✓
    CopilotUI.refreshRosterReport()
    invokeServerFunction("reportRoster")
end

-- 第 1 列的文字（翻译走 zh.po）
function CopilotUI.takeoverText(taken)
    if taken then return "✓ " .. "Taken over"%_t end
    return "— " .. "Not taken over"%_t
end

-- 把第 0 列的勾同步到第 1 列的文字镜像。
-- ★ 写在 onChanged 回调里，所以要防重入（写 entry 可能再次触发 changed）✓
function CopilotUI.syncRowMirrors()
    if not self.shipList or self.mirrorGuard then return end
    self.mirrorGuard = true
    for i = 0, self.shipList.rows - 1 do
        local taken = (self.shipList:getEntry(0, i) or "") ~= ""
        self.shipList:setEntry(1, i, CopilotUI.takeoverText(taken), false, false,
            taken and ColorRGB(0.55, 1.0, 0.6) or ColorRGB(0.62, 0.62, 0.62))
        self.shipList:setEntryType(1, i, ListBoxEntryType.Text)
    end
    self.mirrorGuard = false
end

-- 自检行：面板读到的名单 vs 服务端（`CopilotUI.reportRoster`，与插件同一个解析器）✓
-- 两边不一致 = 真出问题（客户端那份滞后），会显式打 ✗ 而不是让人误会 ✓✓
function CopilotUI.refreshRosterReport()
    if not self.rosterLabel then return end

    local player = Player()
    if not player then return end

    local panelCount = countSet(decodeShipSet(player:getValue("copilot_auto_ships")))
    local prefix = "Roster (panel / server): "%_t

    local report = tostring(player:getValue("copilot_roster_report") or "")
    local serverCount = report:match("^(%d+)|")
    if serverCount == nil then
        self.rosterLabel.caption = prefix .. panelCount .. " / ?"
        return
    end

    serverCount = tonumber(serverCount)
    local mark = (serverCount == panelCount) and "✓" or "✗ MISMATCH"
    self.rosterLabel.caption = prefix .. panelCount .. " / " .. tostring(serverCount) .. "  " .. mark
end

function CopilotUI.onShipToggled()
    -- ★ 先更新文字镜像（勾本身已经在列表里了），再落盘 ✓
    CopilotUI.syncRowMirrors()
    CopilotUI.saveShipList()
end

-- 点击某一行 = **选中这艘船**，把它的目标文字读进下面的输入框 ✓
-- （★ 不再"点一下换一档"：主人要的是**自己写一句话**，不是从几个选项里挑 ✗✓）
function CopilotUI.onShipSelected()
    if not self.shipList then return end

    local row = self.shipList.selected
    if row == nil or row < 0 or row >= self.shipList.rows then return end

    local cached = self.shipRows and self.shipRows[row + 1]
    if cached == nil then return end

    CopilotUI.editGoalFor(cached, row)
end

-- 把某艘船的目标装进输入框（玩家直接改文字 ✓）；row 用来保存后回写那一行显示 ✓
function CopilotUI.editGoalFor(cached, row)
    self.goalEditShip = cached.name
    self.goalEditRow = row
    self.goalEditText = cached.goalText or ""

    if self.goalEditBox then
        self.goalEditBox.text = self.goalEditText
    end
    if self.goalEditCaption then
        self.goalEditCaption.caption = ("Goal text for "%_t) .. tostring(cached.name)
    end
end

-- 「保存目标」：把这艘船的自然语言目标写进 `copilot_goal_<船名>`（空 = 清掉 → 回到自动 ✓）
function CopilotUI.onGoalSavePressed(button)
    if not onClient() then return end

    local ship = self.goalEditShip
    if ship == nil or ship == "" then return end

    local text = ""
    if self.goalEditBox and self.goalEditBox.text ~= nil then
        text = tostring(self.goalEditBox.text)
    end
    text = text:gsub("[\r\n]+", " ")

    invokeServerFunction("setShipGoalText", ship, text)

    -- 乐观回写那一行（服务端下一拍确认；值本来就是同一份字符串 ✓）
    local cached = self.shipRows and self.goalEditRow and self.shipRows[self.goalEditRow + 1]
    if cached ~= nil then
        cached.goalText = text
        if self.shipList and self.goalEditRow ~= nil then
            self.shipList:setEntry(4, self.goalEditRow, goalDisplay(cached.goalText, cached.goalOptions or {}),
                false, false, ColorRGB(0.7, 0.9, 1.0))
            self.shipList:setEntryType(4, self.goalEditRow, ListBoxEntryType.Text)
        end
    end
end

-- 把整张表读回来落盘：**只剩生效名单的勾** ✓
-- ★ 2026-10-19：目标不再从这里写（它有专门的输入框 + `setShipGoalText` ✓）——
--   以前靠"点行换预设"写目标，会顺手把 RPC 设的动作白名单覆盖掉 ✗✓
function CopilotUI.saveShipList()
    if not self.shipList then return end

    local set = {}
    local cfg = {}
    local order = {}
    local rows = self.shipRows or {}

    for i = 0, self.shipList.rows - 1 do
        local name = self.shipList:getEntry(2, i)
        if name ~= nil and name ~= "" then
            order[#order + 1] = name

            if self.shipList:getEntry(0, i) ~= "" then
                set[name] = true
            end

            local cached = rows[i + 1] or {}
            -- `copilot_auto_cfg` 只做兼容（rename.lua 会迁移它 ✓）；target 字段没人读 ✗
            cfg[name] = { auto = cached.auto and true or false, target = cached.goalText or "" }
        end
    end

    invokeServerFunction("setAutoShips", encodeShipSet(set), encodeShipCfg(cfg, order), "")

    -- 写回之后立刻刷新自检行（服务端的回报晚一拍到，updateClient 会补上）✓
    CopilotUI.refreshRosterReport()
    invokeServerFunction("reportRoster")
end

-- ---------------------------------------------------------------------------
-- top right button
-- ---------------------------------------------------------------------------

function CopilotUI.buildHudButton()
    local ok, err = pcall(function()
        local res = getResolution()
        local size = 34
        local centreY = 40
        local centreX = res.x - 342   -- one slot left of the vanilla row's leftmost button
        local rect = Rect(vec2(centreX - size * 0.5, centreY - size * 0.5),
                          vec2(centreX + size * 0.5, centreY + size * 0.5))

        local container = Hud():createContainer(rect)
        self.hudContainer = container
        self.hudButton = container:createRoundButton(Rect(vec2(0, 0), vec2(size, size)),
                                                     "data/textures/icons/robot.png", "onHudButtonPressed")
        self.hudButton.tooltip = "Copilot (open it over RPC too: query {what=\"panel\", action=\"open\"})"%_t
    end)
    if DEBUG then print("[copilot] hud button: ok=" .. tostring(ok) .. " err=" .. tostring(err)) end

    CopilotUI.updateHudButtonVisibility()
end

function CopilotUI.onHudButtonPressed(button)
    if onClient() then
        CopilotUI.togglePanel()
    end
end

-- Is the vanilla icon row on screen right now?
--
-- Measured behaviour:
--   * outside direct flight (PlayerStateType.Fly) the row is always on screen
--   * while flying it auto-hides, and is only revealed by holding SHIFT or by having one of
--     the game's windows open
--
-- Hud().notificationsVisible is deliberately NOT consulted: it is true almost permanently
-- (it reports that the notification area exists, not that something needs attention), which
-- made the button impossible to hide.
function CopilotUI.vanillaRowVisible()
    local player = Player()
    if not player then return false end

    if player.state ~= PlayerStateType.Fly then
        return true
    end

    local keyboard = Keyboard()
    if keyboard and keyboard.shiftPressed then return true end

    local hud = Hud()
    if not hud then return false end
    if hud.playerWindowVisible then return true end
    if hud.shipWindowVisible then return true end
    if hud.mailWindowVisible then return true end
    if hud.playerTradeWindowVisible then return true end
    if hud.buildingUIVisible then return true end

    return false
end

function CopilotUI.updateHudButtonVisibility()
    if not self.hudContainer then return end

    local want = true
    if FOLLOW_VANILLA_VISIBILITY then
        want = CopilotUI.vanillaRowVisible()
    end
    if not SHOW_HUD_BUTTON then want = false end

    -- ★ 2026-10-19：这里原来是 `if want == self.hudVisible then return end` ✗
    --   典型的「一次性守卫」定时炸弹（见 docs/dev/lua-vfs-and-engine.md 的两条硬规矩）：
    --   HUD 重建 / 面板开关之后，引擎侧可能已经把按钮藏了，而本标志还记着"已经是显示的"
    --   → 于是**永远不再补显示** → 真机上就是"找不到 Copilot 按钮" ✗✓
    --   改成每帧幂等地下发（两次 show() 调用，代价可以忽略 ✓）；标志只留给调试看。
    self.hudVisible = want

    -- Visibility does NOT propagate from a container to its children in Avorion (vanilla
    -- hides every child individually, cf. data/scripts/entity/bulletinboard.lua), so the
    -- button itself has to be shown/hidden as well.
    local function apply(element)
        if not element then return end
        if want then
            element:show()
        else
            element:hide()
        end
    end

    apply(self.hudContainer)
    apply(self.hudButton)
end

-- ---------------------------------------------------------------------------
-- autopilot switches
-- ---------------------------------------------------------------------------

function CopilotUI.refresh()
    local player = Player()
    if not player then return end

    local serverEnabled = player:getValue("copilot_enabled") and true or false
    local serverExplore = player:getValue("copilot_explore") and true or false
    self.state = player:getValue("copilot_state")

    if self.enabledPending then
        if serverEnabled == self.enabled then self.enabledPending = false end
    else
        self.enabled = serverEnabled
    end

    if self.explorePending then
        if serverExplore == self.explore then self.explorePending = false end
    else
        self.explore = serverExplore
    end

    if self.statusLabel then
        if self.enabled then
            self.statusLabel.caption = "Autopilot: ON"%_t
        else
            self.statusLabel.caption = "Autopilot: OFF"%_t
        end
    end

    if self.stateLabel then
        local text = "-"
        if self.enabled and self.state then
            text = stateTextTable()[self.state] or tostring(self.state)
        end
        self.stateLabel.caption = text
    end

    if self.toggleButton then
        if self.enabled then
            self.toggleButton.caption = "Disable"%_t
        else
            self.toggleButton.caption = "Enable"%_t
        end
    end

    if self.exploreCheckBox then
        self.exploreCheckBox.checked = self.explore
    end
end

function CopilotUI.onTogglePressed(button)
    if onClient() then
        self.enabled = not self.enabled
        self.enabledPending = true
        invokeServerFunction("setEnabled", self.enabled)
        return
    end
end

function CopilotUI.onExploreChecked(checkbox)
    if onClient() then
        local checked = self.exploreCheckBox and self.exploreCheckBox.checked and true or false
        self.explore = checked
        self.explorePending = true
        invokeServerFunction("setExplore", checked)
        return
    end
end

-- Server -------------------------------------------------------------------

function CopilotUI.setEnabled(enabled)
    if onClient() then
        invokeServerFunction("setEnabled", enabled)
        return
    end

    local player = Player(callingPlayer)
    if not player then return end

    player:setValue("copilot_enabled", enabled and true or false)

    if enabled then
        -- mount the brain; it releases the ship again once the value goes false
        player:addScriptOnce("data/scripts/player/ai/autopilot.lua")
    end
end
callable(CopilotUI, "setEnabled")

function CopilotUI.setExplore(explore)
    if onClient() then
        invokeServerFunction("setExplore", explore)
        return
    end

    local player = Player(callingPlayer)
    if not player then return end

    player:setValue("copilot_explore", explore and true or false)
end
callable(CopilotUI, "setExplore")

-- Stores the list of ships the AI is allowed to operate on. Kept as a newline separated
-- string: player:setValue is only proven for simple values.
-- Stores the list of ships the AI is allowed to operate on, plus per-ship settings.
-- 两份都是纯字符串（换行/竖线分隔）：player:setValue 对表支持未验证，见 AGENTS.md。
--
-- ★ 2026-10-19：第三个参数 goalsText（每行 `船名|动作`）把面板第 4 列写进**真目标**
--   `copilot_goal_kind_<船名>`（`lib/copilot/goal.lua:53-67` 的 setOptions ✓，它会做
--   动作名校验/规范化 ✓）。旧参数 cfgText 里的 target 字段**没有任何消费方** ✗，
--   保留它只为兼容 `lib/copilot/rename.lua:316-331` 的改名迁移 ✓。
function CopilotUI.setAutoShips(serialized, cfgText, goalsText)
    if onClient() then
        invokeServerFunction("setAutoShips", serialized, cfgText, goalsText)
        return
    end

    local player = Player(callingPlayer)
    if not player then return end

    player:setValue("copilot_auto_ships", tostring(serialized or ""))
    player:setValue("copilot_auto_cfg", tostring(cfgText or ""))

    local goals = tostring(goalsText or "")
    if goals ~= "" then
        local ok, err = pcall(function()
            local Goal = include("copilot/goal")
            for line in goals:gmatch("[^\n]+") do
                -- ★ 每行 `船名|动作` 或 `船名|动作1,动作2`（空 = 自动，清掉限制 ✓）
                local name, list = line:match("^([^|]+)|(.*)$")
                if name ~= nil and name ~= "" then
                    local options = {}
                    for action in tostring(list or ""):gmatch("[^,]+") do
                        local a = action:match("^%s*(.-)%s*$")
                        if a ~= "" then options[#options + 1] = a end
                    end
                    Goal.setOptions(player, name, (#options > 0) and options or nil)
                end
            end
        end)
        if not ok and DEBUG then
            print("[copilot] setAutoShips goals failed: " .. tostring(err))
        end
    end
end
callable(CopilotUI, "setAutoShips")

-- ★★ 任务的**自然语言写入面**（主人 2026-10-19 原话：「留个框，让玩家输入自然语言」✓✓）
--   写进 `copilot_goal_<船名>`（`lib/copilot/goal.lua:41-49` 的 `M.setText` ✓）。
--   ★ 空串 = 清掉 → 回到「自动 / 不指派」（决策层按分类 + 装备自己定 ✓）。
--   ★ 决策侧终于会读到它了：`task.ts` 的 `renderTaskBlock` 现在把
--     `req.goalText` 渲染成「主人给这艘船的目标：…（当边界用，不是命令）」✓✓
--     （2026-10-19 之前那句话**根本没进提示词** ✗ —— 光有输入框也不会生效 ✓）
function CopilotUI.setShipGoalText(ship, text)
    if onClient() then
        invokeServerFunction("setShipGoalText", ship, text)
        return
    end

    local player = Player(callingPlayer)
    if not player then return end
    if type(ship) ~= "string" or ship == "" then return end

    local Goal = include("copilot/goal")
    Goal.setText(player, ship, tostring(text or ""))
end
callable(CopilotUI, "setShipGoalText")

-- ★★ 2026-10-19 只读自检：把**服务端（= 插件同源）**看到的名单回报给面板 ✓✓
--
-- 为什么需要它：面板第 0 列读的是 player value `copilot_auto_ships` 的**客户端副本**，
-- 而插件 `fleet_query {what:list}` 的 `designated` 是**服务端**用同一个解析器数出来的
-- （`lib/copilot/card.lua:124-131` 的 `M.designated`）。两者本来同源，但客户端副本理论上
-- 可能滞后 → 面板底部那行「面板 N / 服务端 M」就是拿它在对账，不一致会打 ✗ ✓
function CopilotUI.reportRoster()
    if onClient() then
        invokeServerFunction("reportRoster")
        return
    end

    local player = Player(callingPlayer)
    if not player then return end

    -- 优先用**插件侧同一个解析器**（card.lua 的 M.designated），失败才退回本地解析 ✓
    local names = nil
    local source = "card"
    local ok, result = pcall(function()
        local Card = include("copilot/card")
        return Card.designated(player)
    end)
    if ok and type(result) == "table" then
        names = result
    else
        source = "fallback"
        names = {}
        for n in tostring(player:getValue("copilot_auto_ships") or ""):gmatch("[^\n]+") do
            if n ~= "" then names[#names + 1] = n end
        end
        table.sort(names)
        if DEBUG then print("[copilot] reportRoster fallback: " .. tostring(result)) end
    end

    player:setValue("copilot_roster_report",
        tostring(#names) .. "|" .. source .. "|" .. table.concat(names, ", "))
end
callable(CopilotUI, "reportRoster")

-- ★ RPC 面板开关的**回执面**：客户端把真实可见性报回来（只读事实 ✓）——
--   `query {what="panel"}` 的回执里带 `lastKnownVisible`，这样"命令发出去后到底开没开"
--   有据可查 ✓，而不是让调用方猜 ✗。
--   ★ 它就是**上报**，绝不反过来改面板状态 ✓（单向：RPC 写值 → 客户端执行 → 回报 ✓）。
function CopilotUI.reportPanelVisible(visible)
    if onClient() then
        invokeServerFunction("reportPanelVisible", visible)
        return
    end

    local player = Player(callingPlayer)
    if not player then return end

    player:setValue("copilot_panel_visible", (visible == true) and "open" or "closed")
end
callable(CopilotUI, "reportPanelVisible")

-- ===========================================================================
-- ★ 炮塔底座材料升级（2026-10-17）
--
-- 主人的规格（逐字）：材料由玩家选 / 收费 / 执行条件照抄原版修船坞 /
-- **绝不自动升级**（只有玩家点按钮才动）/ 所有炮塔底座（含空底座）/ 面板按钮。
--
-- 数据路径：见 data/scripts/lib/copilot/mounts.lua 的 rebuildPlan ——
--   ⚠ 路径 A（block.material = …）2026-10-17 真机实测是空操作 ✗，
--     所以走**整船重建 plan + setMovePlan**（原版 plangenerator.lua:429-431 的复制方式）。
--
-- 不自动：本段代码只由按钮回调 / invokeServerFunction 触发；**没有** hooks 进
-- updateServer/updateClient 的自动逻辑，也没有任何 tick 扫描 ✓。
-- ===========================================================================

local MOUNTS_WIDTH = 560
local MOUNTS_HEIGHT = 560

-- 材料名（MaterialType 0..6，Enums.html:1408-1417）—— 只用于显示，命令层用英文/数字
local MATERIAL_LABELS = {
    "Iron", "Titanium", "Naonite", "Trinium", "Xanion", "Ogonite", "Avorion",
}

CopilotUI.mountsWindow = nil
CopilotUI.mountsStateText = nil
CopilotUI.mountsConfirmPending = false

local function mountsValue(player, key)
    return tostring(player:getValue(key) or "")
end

-- 状态字符串的格式（server -> player value -> 这里解析）：
--   SHIP|name|bases|turrets|maxMaterial
--   SEL|name        MAT|int        COST|int|resourceUnits|credits|text     REPORT|text
function CopilotUI.parseMountsState(text)
    local state = { ships = {}, costs = {}, report = "", selectedShip = "", selectedMaterial = 0 }
    for line in tostring(text or ""):gmatch("[^\n]+") do
        local kind, rest = line:match("^([A-Z]+)|(.*)$")
        if kind == "SHIP" then
            local name, bases, turrets, maxMaterial =
                rest:match("^(.-)|(%-?%d+)|(%-?%d+)|(%-?%d+)$")
            if name ~= nil then
                state.ships[#state.ships + 1] = {
                    name = name, bases = tonumber(bases),
                    turrets = tonumber(turrets), maxMaterial = tonumber(maxMaterial),
                }
            end
        elseif kind == "SEL" then
            state.selectedShip = rest
        elseif kind == "MAT" then
            state.selectedMaterial = tonumber(rest) or 0
        elseif kind == "COST" then
            local value, units, credits, text =
                rest:match("^(%-?%d+)|(%-?%d+)|(%-?%d+)|(.*)$")
            if value ~= nil then
                state.costs[tonumber(value)] = {
                    units = tonumber(units), credits = tonumber(credits), text = text,
                }
            end
        elseif kind == "REPORT" then
            state.report = rest
        end
    end
    return state
end

function CopilotUI.buildMountsWindow()
    if self.mountsWindow then return end

    local res = getResolution()
    local size = vec2(MOUNTS_WIDTH, MOUNTS_HEIGHT)
    local lower = vec2(res.x * 0.5 - size.x * 0.5, res.y * 0.5 - size.y * 0.5)

    local window = Hud():createWindow(Rect(lower, lower + size))
    self.mountsWindow = window
    window.caption = "Turret base materials"%_t
    window.moveable = true
    window.showCloseButton = true

    local lister = UIVerticalLister(Rect(vec2(10, 10), vec2(size.x - 10, size.y - 10)), 6, 0)

    self.mountsReportLabel = window:createLabel(lister:nextRect(56), "", 13)
    self.mountsReportLabel.caption = ""

    self.mountsSelectedLabel = window:createLabel(lister:nextRect(20), "", 14)
    self.mountsSelectedLabel.caption = ""

    window:createLabel(lister:nextRect(20), "Ships in this sector"%_t, 14)

    local shipList = window:createListBoxEx(lister:nextRect(120))
    self.mountsShipList = shipList
    shipList.columns = 2
    shipList:setColumnWidth(0, 260)
    shipList:setColumnWidth(1, MOUNTS_WIDTH - 260 - 40)
    shipList.rowHeight = 22
    shipList.entriesSelectable = true
    shipList.onSelectFunction = "onMountsShipSelected"

    window:createLabel(lister:nextRect(20), "Target material (cost)"%_t, 14)

    local materialList = window:createListBoxEx(lister:nextRect(196))
    self.mountsMaterialList = materialList
    materialList.columns = 3
    materialList:setColumnWidth(0, 140)
    materialList:setColumnWidth(1, 200)
    materialList:setColumnWidth(2, MOUNTS_WIDTH - 140 - 200 - 40)
    materialList.rowHeight = 22
    materialList.entriesSelectable = true
    materialList.onSelectFunction = "onMountsMaterialSelected"

    self.mountsApplyButton = window:createButton(lister:nextRect(30), "Apply upgrade"%_t,
        "onMountsApplyPressed")
    self.mountsApplyButton.tooltip = "First click shows the price again. Second click charges and applies."%_t

    self.mountsRefreshButton = window:createButton(lister:nextRect(28), "Refresh"%_t,
        "onMountsRefreshPressed")

    window:show()
    window:hide()
end

function CopilotUI.openMounts()
    CopilotUI.buildMountsWindow()
    if not self.mountsWindow then return end

    self.mountsConfirmPending = false
    if self.mountsApplyButton then
        self.mountsApplyButton.caption = "Apply upgrade"%_t
    end

    -- 打开时向服务端要一次真实状态（报价在服务端算，客户端只显示 ✓）
    invokeServerFunction("mountsRefresh")
    self.mountsWindow:show()
    Hud():addMouseShowingWindow(self.mountsWindow)
end

function CopilotUI.onMountsPressed(button)
    if onClient() then
        CopilotUI.openMounts()
    end
end

function CopilotUI.refreshMounts()
    if not self.mountsWindow or not self.mountsWindow.visible then return end
    local player = Player()
    if not player then return end

    local text = tostring(player:getValue("copilot_mounts_state") or "")
    if text == self.mountsStateText then return end
    self.mountsStateText = text

    local state = CopilotUI.parseMountsState(text)

    if self.mountsReportLabel then
        self.mountsReportLabel.caption = tostring(state.report):gsub(" /// ", "\n")
    end

    local selectedName = tostring(state.selectedShip or "")
    if self.mountsSelectedLabel then
        self.mountsSelectedLabel.caption = "Selected: " .. selectedName
            .. "   target: " .. (MATERIAL_LABELS[state.selectedMaterial] or "?")
    end

    -- ships
    local shipList = self.mountsShipList
    if shipList then
        shipList.onChangedFunction = ""
        shipList.onSelectFunction = ""
        shipList:clear()
        for _, item in ipairs(state.ships) do
            shipList:addRow()
            local row = shipList.rows - 1
            shipList:setEntry(0, row, item.name, false, false, ColorRGB(0.9, 0.9, 0.9))
            shipList:setEntryType(0, row, ListBoxEntryType.Text)
            shipList:setEntry(1, row,
                tostring(item.bases) .. " bases / " .. tostring(item.turrets) .. " turrets",
                false, false, ColorRGB(0.7, 0.85, 1.0))
            shipList:setEntryType(1, row, ListBoxEntryType.Text)
        end
        shipList.onSelectFunction = "onMountsShipSelected"
    end

    -- materials: always 7 rows (0..6), cost only where the server could price it
    local materialList = self.mountsMaterialList
    if materialList then
        materialList.onSelectFunction = ""
        materialList:clear()
        for value = 0, 6 do
            materialList:addRow()
            local row = materialList.rows - 1
            local label = MATERIAL_LABELS[value] or tostring(value)
            if value == state.selectedMaterial then label = "> " .. label .. " <" end
            materialList:setEntry(0, row, label, false, false, ColorRGB(0.9, 0.9, 0.9))
            materialList:setEntryType(0, row, ListBoxEntryType.Text)

            local cost = state.costs[value]
            local resources = "-"
            local credits = "-"
            if cost ~= nil then
                resources = tostring(cost.text)
                credits = tostring(cost.credits)
            end
            materialList:setEntry(1, row, resources, false, false, ColorRGB(0.8, 0.95, 0.8))
            materialList:setEntryType(1, row, ListBoxEntryType.Text)
            materialList:setEntry(2, row, credits, false, false, ColorRGB(0.8, 0.9, 1.0))
            materialList:setEntryType(2, row, ListBoxEntryType.Text)
        end
        materialList.onSelectFunction = "onMountsMaterialSelected"
    end
end

function CopilotUI.onMountsShipSelected()
    if not self.mountsShipList then return end
    local row = self.mountsShipList.selected
    if row == nil or row < 0 or row >= self.mountsShipList.rows then return end
    local name = self.mountsShipList:getEntry(0, row)
    if name == nil or name == "" then return end
    self.mountsConfirmPending = false
    invokeServerFunction("mountsSelectShip", name)
end

function CopilotUI.onMountsMaterialSelected()
    if not self.mountsMaterialList then return end
    local row = self.mountsMaterialList.selected
    if row == nil or row < 0 or row >= self.mountsMaterialList.rows then return end
    self.mountsConfirmPending = false
    invokeServerFunction("mountsSelectMaterial", row)
end

function CopilotUI.onMountsApplyPressed(button)
    if not onClient() then return end
    if self.mountsConfirmPending then
        self.mountsConfirmPending = false
        if self.mountsApplyButton then self.mountsApplyButton.caption = "Apply upgrade"%_t end
        invokeServerFunction("mountsApply", true)
    else
        self.mountsConfirmPending = true
        if self.mountsApplyButton then self.mountsApplyButton.caption = "Click again to confirm"%_t end
        invokeServerFunction("mountsApply", false)
    end
end

function CopilotUI.onMountsRefreshPressed(button)
    if onClient() then
        invokeServerFunction("mountsRefresh")
    end
end

-- ---- server side ----------------------------------------------------------

local function mountsCli()
    local ok, Cli = pcall(include, "copilot/cli")
    if ok and type(Cli) == "table" then return Cli end
    return nil
end

function CopilotUI.mountsPushState(player, reportOverride)
    local Cli = mountsCli()
    if Cli == nil then return end
    local ship = tostring(player:getValue("copilot_mounts_ship") or "")
    local material = tonumber(player:getValue("copilot_mounts_mat")) or 1
    player:setValue("copilot_mounts_state",
        Cli.mountsPanelState(player, ship, material, reportOverride))
end

function CopilotUI.mountsRefresh()
    if onClient() then
        invokeServerFunction("mountsRefresh")
        return
    end
    local player = Player(callingPlayer)
    if not player then return end
    CopilotUI.mountsPushState(player)
end
callable(CopilotUI, "mountsRefresh")

function CopilotUI.mountsSelectShip(name)
    if onClient() then
        invokeServerFunction("mountsSelectShip", name)
        return
    end
    local player = Player(callingPlayer)
    if not player then return end
    player:setValue("copilot_mounts_ship", tostring(name or ""))
    CopilotUI.mountsPushState(player)
end
callable(CopilotUI, "mountsSelectShip")

function CopilotUI.mountsSelectMaterial(value)
    if onClient() then
        invokeServerFunction("mountsSelectMaterial", value)
        return
    end
    local player = Player(callingPlayer)
    if not player then return end
    player:setValue("copilot_mounts_mat", tonumber(value) or 1)
    CopilotUI.mountsPushState(player)
end
callable(CopilotUI, "mountsSelectMaterial")

-- ★ confirmed=false：只报价（服务端会重建副本算价，然后**一个字节都不写** ✓）
-- ★ confirmed=true ：真正扣钱 + setMovePlan + 补炮塔样式/耐久/档案（玩家点了两次才到这里 ✓）
function CopilotUI.mountsApply(confirmed)
    if onClient() then
        invokeServerFunction("mountsApply", confirmed)
        return
    end
    local player = Player(callingPlayer)
    if not player then return end

    local Cli = mountsCli()
    if Cli == nil then return end

    local ship = tostring(player:getValue("copilot_mounts_ship") or "")
    local material = tonumber(player:getValue("copilot_mounts_mat")) or 1
    local result = Cli.mountsUpgrade(player, ship, material, confirmed and true or false)
    CopilotUI.mountsPushState(player, table.concat(result.lines or {}, " /// "))
end
callable(CopilotUI, "mountsApply")
