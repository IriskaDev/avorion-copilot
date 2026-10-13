
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
local STATE_TEXT =
{
    idle    = "Idle"%_t,
    combat  = "Engaging hostiles"%_t,
    mine    = "Mining asteroids"%_t,
    salvage = "Salvaging wreckage"%_t,
    full    = "Cargo full, parked"%_t,
    explore = "Jumping to a new sector"%_t,
    empty   = "Sector cleared, waiting"%_t,
}

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
local TARGETS = {
    { key = "",        label = "No task assigned"%_t },
    { key = "mine",    label = "Mine"%_t },
    { key = "salvage", label = "Salvage"%_t },
    { key = "trade",   label = "Trade"%_t },
    { key = "travel",  label = "Travel"%_t },
}

local function targetLabel(key)
    for _, t in ipairs(TARGETS) do
        if t.key == key then return t.label end
    end
    return TARGETS[1].label
end

local function nextTargetKey(key)
    for i, t in ipairs(TARGETS) do
        if t.key == key then
            return TARGETS[(i % #TARGETS) + 1].key
        end
    end
    return TARGETS[1].key
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
    for _, t in ipairs(TARGETS) do
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

    for i = 0, self.shipList.rows - 1 do
        local name = self.shipList:getEntry(1, i)
        if name ~= nil and name ~= "" then
            order[#order + 1] = name

            if self.shipList:getEntry(0, i) ~= "" then
                set[name] = true
            end

            local shown = self.shipList:getEntry(3, i)
            local target = ""
            for _, t in ipairs(TARGETS) do
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
            text = STATE_TEXT[self.state] or tostring(self.state)
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
