package.path = package.path .. ";data/scripts/lib/?.lua"
package.path = package.path .. ";data/scripts/?.lua"
-- CopilotFleet —— **空闲检测 + 自动发起决策请求**（游戏侧的"探头"）。
--
-- 主人 2026-10-14 定的设计：
--   「每艘被激活的船…设定一个目标…**这艘船一空闲，就应该由游戏那边发起请求**，
--     DSH 收到相应请求后，**调用 RPC 调集游戏内数据**，做具体决策。」
--
--   「**当我不修改时，这个目标就在船空闲后自动重发**」✓✓
--
-- 于是本文件的职责**极薄** ✓：
--   1. 扫面板名单，挑出「**有目标** + **空闲** + **没在处理中**」的船 ✓
--   2. 发一条 `decide { ship = 船名 }` ✓ —— **只带船名** ✗ 不带数据 ✓
--      （数据由 DSH 自己 `query` 来拿 ✓ —— 这是主人的架构 ✓✓）
--   3. 拿到答复后，把命令**转成 `order`** 发回游戏侧执行 ✓
--   4. 船重新变忙 → 清掉处理标记 ✓ → 干完又空闲 → **自动再发一次** ✓✓
--
-- **不做任何决策** ✗、**不读不必要的数据** ✗ —— 决策是 DSH 的事 ✓。
--
-- 必须被 net.lua **include**（和泵同一个 VM ✓，否则用不到 Rpc ✓）。
--
-- 命名空间脚本：表不能清空
-- namespace CopilotFleet
CopilotFleet = CopilotFleet or {}

local self = CopilotFleet

-- 扫描间隔（秒）与"决策中"的超时（秒）
self.SCAN_INTERVAL = 10
self.DECIDE_TIMEOUT = 90      -- 等模型，给足 ✓（协议 §11：绝不阻塞 ✓）
self.ORDER_TIMEOUT = 30

self.lastScanAt = self.lastScanAt or 0
self.inFlight = self.inFlight or {}     -- 船名 -> { at = os.clock() }（正在等决策/下单 ✓）
self.stats = self.stats or { scanned = 0, decided = 0, ordered = 0, failed = 0 }

-- ---------------------------------------------------------------------------
-- 名单（与 panel / ops 同一份 player value ✓）
-- ---------------------------------------------------------------------------

local function designated(player)
    local names = {}
    for n in tostring(player:getValue("copilot_auto_ships") or ""):gmatch("[^\n]+") do
        if n ~= "" then names[#names + 1] = n end
    end
    return names
end

-- ---------------------------------------------------------------------------
-- 一次扫描
-- ---------------------------------------------------------------------------

function CopilotFleet.scan()
    local player = Player()
    if player == nil then return end
    if not CopilotNet.isConnected() then return end      -- 没连上就不发 ✓（省得白等超时）

    local Card = include("copilotcard")
    local Goal = include("copilotgoal")

    -- 玩家自己开的那条船**永不**参与 ✓（主人明确要求过 ✓）
    local piloted = player.craft
    local pilotedName = (piloted ~= nil and valid(piloted)) and piloted.name or nil

    local now = os.clock()
    -- 先把已经离开"空闲"的船清出 inFlight ✓（说明命令真跑起来了 ✓）
    for name, rec in pairs(self.inFlight) do
        if name == pilotedName then
            self.inFlight[name] = nil
        else
            local busy = Card.isBusy(player, name)
            if busy == true or (now - rec.at) > (self.DECIDE_TIMEOUT + self.ORDER_TIMEOUT + 60) then
                self.inFlight[name] = nil
            end
        end
    end

    self.stats.scanned = self.stats.scanned + 1

    for _, name in ipairs(designated(player)) do
        if name == pilotedName or self.inFlight[name] ~= nil then
            -- 跳过：玩家在开 / 已经在处理 ✓
        else
            local goal = Goal.describe(player, name)
            if goal.hasGoal then
                local busy, avail = Card.isBusy(player, name)
                if busy == false then
                    self.inFlight[name] = { at = now }
                    CopilotFleet.askDecide(name, goal)
                elseif busy == nil then
                    CopilotNet.emit("error", "fleet: cannot read availability of " .. name .. " (" .. tostring(avail) .. ")")
                end
            end
        end
    end
end

-- 由 tick 泵调用，自己控节奏 ✓
function CopilotFleet.maybeScan()
    local now = os.clock()
    if now - self.lastScanAt < self.SCAN_INTERVAL then return end
    self.lastScanAt = now
    local ok, err = pcall(CopilotFleet.scan)
    if not ok then
        CopilotNet.emit("error", "fleet scan failed: " .. tostring(err))
    end
end

-- ---------------------------------------------------------------------------
-- 发起：只带船名 ✓，数据让 DSH 自己来拿 ✓
-- ---------------------------------------------------------------------------

function CopilotFleet.askDecide(ship, goal)
    CopilotRpc.trace("fleet: 空闲 → 发起 decide ship=" .. tostring(ship))

    -- 目标**不完全由游戏侧推** ✓ —— 但把"玩家是否设了目标"这个事实带上，
    -- 让 DSH 少一次往返判断 ✓（数据主体仍由 DSH query 拿 ✓）
    local ok, err = CopilotRpc.call("decide", {
        ship = ship,
        hasGoal = true,
    }, function(ok2, data, why)
        if ok2 then
            CopilotFleet.onDecision(ship, data)
        else
            self.inFlight[ship] = nil         -- 失败就放开，下轮可以重试 ✓
            self.stats.failed = self.stats.failed + 1
            CopilotRpc.trace("fleet: decide 失败 ship=" .. tostring(ship) .. " why=" .. tostring(why))
        end
    end, self.DECIDE_TIMEOUT)

    if not ok then
        self.inFlight[ship] = nil
        CopilotNet.emit("error", "fleet: decide send failed: " .. tostring(err))
    end
end

-- ---------------------------------------------------------------------------
-- DSH 给了命令 → 转成 order 打回去执行 ✓
-- ---------------------------------------------------------------------------

function CopilotFleet.onDecision(ship, data)
    self.stats.decided = self.stats.decided + 1
    data = data or {}

    local action = data.action
    local params = data.params or {}
    CopilotRpc.trace("fleet: decide 回来 ship=" .. tostring(ship) .. " action=" .. tostring(action))

    if type(action) ~= "string" or action == "" or action == "None" then
        -- 模型说"这轮什么都不做" ✓ —— 正常结果，不是错误 ✓
        self.inFlight[ship] = nil
        return
    end

    -- order 的 data：{ship, action, ...params}（扁平 ✓，协议 §10 第 5 条 ✓）
    local req = { ship = ship, action = action }
    if type(params) == "table" then
        for k, v in pairs(params) do req[k] = v end
    end
    if data.reason ~= nil then req.reason = tostring(data.reason) end

    local ok, err = CopilotRpc.call("order", req, function(ok2, res, why)
        if ok2 then
            self.stats.ordered = self.stats.ordered + 1
            CopilotRpc.trace("fleet: order 成功 ship=" .. tostring(ship) .. " action=" .. tostring(action))
        else
            self.stats.failed = self.stats.failed + 1
            CopilotRpc.trace("fleet: order 失败 ship=" .. tostring(ship) .. " why=" .. tostring(why))
        end
        -- 无论成败都放开 ✓ —— 船若真忙起来了，下轮扫描不会再发 ✓
    end, self.ORDER_TIMEOUT)

    if not ok then
        self.inFlight[ship] = nil
        CopilotNet.emit("error", "fleet: order send failed: " .. tostring(err))
    end
end

-- ---------------------------------------------------------------------------
-- 状态
-- ---------------------------------------------------------------------------

function CopilotFleet.status()
    local n = 0
    for _ in pairs(self.inFlight) do n = n + 1 end
    return string.format("fleet: inflight=%d scanned=%d decided=%d ordered=%d failed=%d",
        n, self.stats.scanned, self.stats.decided, self.stats.ordered, self.stats.failed)
end

return CopilotFleet
