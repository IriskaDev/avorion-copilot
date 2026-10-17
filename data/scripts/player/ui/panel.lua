
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

-- Panel geometry (pixels). The content is laid out with a UIVerticalLister, so the height
-- has to fit every row below with room to spare.
local PANEL_WIDTH = 440
local PANEL_HEIGHT = 500

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

function CopilotUI.getUpdateInterval()
    return 1
end

function CopilotUI.updateClient(timeStep)
    -- the labels only need updating while the panel is open; the ship list is rebuilt when
    -- the panel is opened so it never fights with the player's clicks
    if self.window and self.window.visible then
        CopilotUI.refresh()
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

    -- 四列：名单勾选 | 船名 | 该船的 Autopilot | 目标
    --
    -- ListBoxEx 的行里放不下下拉框（列类型只有 Icon/Text/CheckBox/PixelIcon/Texture），
    -- 所以「目标」是文本列，靠**点击该行**在选项之间循环。
    --
    -- 重要：这一列的开关只管**非玩家船**。玩家自己正在开的那条船由上面的主开关
    -- （Autopilot: ON/OFF）负责，两者互不影响。
    local list = window:createListBoxEx(lister:nextRect(210))
    self.shipList = list
    list.columns = 4
    list:setColumnWidth(0, 26)
    list:setColumnWidth(1, size.x - 26 - 84 - 130 - 40)
    list:setColumnWidth(2, 84)
    list:setColumnWidth(3, 130)
    list.rowHeight = 22
    list.entriesSelectable = true
    list.onSelectFunction = "onShipSelected"

    self.hintLabel = window:createLabel(lister:nextRect(44), "", 12)
    self.hintLabel.caption = "Only ticked ships are ever touched. Everything else is left alone.\nThe decision layer itself is not wired up yet - this only stores your selection."%_t

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
end

-- ---------------------------------------------------------------------------
-- ship list
-- ---------------------------------------------------------------------------

-- 每艘船的目标选项（第一期）。键是稳定标识，显示名走翻译。
-- ListBoxEx 放不下下拉框，所以「点击该行」就往后循环一个。
-- 同上：顶层带 %_t 的表会让 /copilot reload 失败 → 放进函数体，用到时再建 ✓
local function targetsTable()
    return {
        { key = "",        label = "No task assigned"%_t },
        { key = "mine",    label = "Mine"%_t },
        { key = "salvage", label = "Salvage"%_t },
        { key = "trade",   label = "Trade"%_t },
        { key = "travel",  label = "Travel"%_t },
        -- ★ 2026-10-17 补全 ✗→✓：面板与 `copilot/goal` 的已知动作必须一致 ✓
        --   （旧表只有 Mine/Salvage/Trade/Travel 4 条 → Sell/Scout/Refine 在这个循环里根本选不到 ✗）
        { key = "sell",    label = "Sell"%_t },
        { key = "scout",   label = "Scout"%_t },
        { key = "refine",  label = "Refine"%_t },
    }
end

local function targetLabel(key)
    local targets = targetsTable()
    for _, t in ipairs(targets) do
        if t.key == key then return t.label end
    end
    return targets[1].label
end

local function nextTargetKey(key)
    local targets = targetsTable()
    for i, t in ipairs(targets) do
        if t.key == key then
            return targets[(i % #targets) + 1].key
        end
    end
    return targets[1].key
end

-- 每船配置存成 "船名|autopilot|目标" 每行一条，和名单一样是纯字符串
-- （player:setValue 对表支持未验证，见 AGENTS.md）。
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

    for _, name in ipairs(names) do
        self.shipList:addRow()
        local row = self.shipList.rows - 1
        local c = cfg[name] or {}

        -- A ticked box is expressed as a non-empty entry text, which is exactly how the
        -- vanilla sell command toggles its checkboxes.
        self.shipList:setEntry(0, row, auto[name] and "checked" or "", false, false, ColorRGB(1, 1, 1))
        self.shipList:setEntryType(0, row, ListBoxEntryType.CheckBox)

        self.shipList:setEntry(1, row, tostring(name), false, false, ColorRGB(0.9, 0.9, 0.9))
        self.shipList:setEntryType(1, row, ListBoxEntryType.Text)

        -- 这艘船自己的 Autopilot（只管非玩家船；玩家自己的船看上面的主开关）
        self.shipList:setEntry(2, row, c.auto and "checked" or "", false, false, ColorRGB(1, 1, 1))
        self.shipList:setEntryType(2, row, ListBoxEntryType.CheckBox)

        -- 目标列：点击该行循环切换
        self.shipList:setEntry(3, row, targetLabel(c.target), false, false, ColorRGB(0.7, 0.9, 1.0))
        self.shipList:setEntryType(3, row, ListBoxEntryType.Text)
    end

    self.shipList.onChangedFunction = "onShipToggled"
end

function CopilotUI.onShipToggled()
    CopilotUI.saveShipList()
end

-- 点击某一行 = 把这艘船的目标往后循环一个。
-- ListBoxEx 的行里放不下下拉框，所以用「点行切换」代替；这也顺便让目标可改。
function CopilotUI.onShipSelected()
    if not self.shipList then return end

    local row = self.shipList.selected
    if row == nil or row < 0 or row >= self.shipList.rows then return end

    local shown = self.shipList:getEntry(3, row)
    local current = ""
    -- ★ 修（2026-10-17）：这里原来读的是**未定义**的全局 `TARGETS` ✗（本文件已改成 `targetsTable()` 工厂 ✓），
    --   真机点一下船行就会 "bad argument #1 to 'ipairs' (table expected, got nil)" ✗✓。
    for _, t in ipairs(targetsTable()) do
        if t.label == shown then
            current = t.key
            break
        end
    end

    self.shipList:setEntry(3, row, targetLabel(nextTargetKey(current)), false, false, ColorRGB(0.7, 0.9, 1.0))
    self.shipList:setEntryType(3, row, ListBoxEntryType.Text)

    CopilotUI.saveShipList()
end

-- 把整张表读回来落盘：两列勾选 + 当前目标。
-- 只读「显示名」再反查键，避免依赖入口文本的其他语义。
function CopilotUI.saveShipList()
    if not self.shipList then return end

    local set = {}
    local cfg = {}
    local order = {}
    local targets = targetsTable()      -- ★ 同上：别再读未定义的全局 TARGETS ✗✓

    for i = 0, self.shipList.rows - 1 do
        local name = self.shipList:getEntry(1, i)
        if name ~= nil and name ~= "" then
            order[#order + 1] = name

            if self.shipList:getEntry(0, i) ~= "" then
                set[name] = true
            end

            local shown = self.shipList:getEntry(3, i)
            local target = ""
            for _, t in ipairs(targets) do
                if t.label == shown then
                    target = t.key
                    break
                end
            end

            cfg[name] = { auto = (self.shipList:getEntry(2, i) ~= ""), target = target }
        end
    end

    invokeServerFunction("setAutoShips", encodeShipSet(set), encodeShipCfg(cfg, order))
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
        self.hudButton.tooltip = "Copilot"%_t
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

    if want == self.hudVisible then return end
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
function CopilotUI.setAutoShips(serialized, cfgText)
    if onClient() then
        invokeServerFunction("setAutoShips", serialized, cfgText)
        return
    end

    local player = Player(callingPlayer)
    if not player then return end

    player:setValue("copilot_auto_ships", tostring(serialized or ""))
    player:setValue("copilot_auto_cfg", tostring(cfgText or ""))
end
callable(CopilotUI, "setAutoShips")

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
