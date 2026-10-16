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
self.REDECIDE_COOLDOWN = 300  -- ★ 同一轮空闲期内，最多每 5 分钟重新决策一次 ✓
                              --   （决策失败或答 None 时船仍空闲；没有冷却就会每 10 秒烧一次模型 ✗）
self.ORDER_TIMEOUT = 30

self.lastScanAt = self.lastScanAt or 0
self.inFlight = self.inFlight or {}     -- 船名 -> { at }（正在等决策/下单 ✓）
self.decided = self.decided or {}       -- 船名 -> 时刻（**本轮空闲期**已决策过 ✓）
self.idleSeen = self.idleSeen or {}     -- 船名 -> true（上一轮扫描时它是否空闲 ✓）
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

    local Card = include("copilot/card")
    local Goal = include("copilot/goal")

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
            -- ★★ 没设目标也决策 ✓✓（主人 2026-10-16 要求）
            --
            --   原话：「在玩家未设置明确说明的时候，也可以试着根据船的装备/命名，
            --          来决定给船派什么指令」
            --   → 所以这里不再要求 hasGoal ✓；没目标时把 goal.hasGoal=false 传给 DSH ✓，
            --     由 DSH 侧的 prompt 告诉模型"玩家没给目标，请按船名与装备自行判断" ✓✓
            --     （prompt 里早就写了这个分支 ✓，只需放行 ✓）
            do
                local busy, avail = Card.isBusy(player, name)
                if busy == false then
                    -- ★ 只在**本轮空闲期**发起一次决策 ✓✓
                    --
                    -- 起因（2026-10-15 实测）：原来每次扫描（每 10 秒）都对空闲船发 decide ✗，
                    -- 于是模型被无限调用（trace 里看到 10 秒一次的连续请求 ✗）。
                    -- 玩家的原意是「船空闲后自动重发」✓ —— 那指的是**每次变成空闲时** ✓，
                    -- 而不是"只要闲着就一直重发" ✗。
                    --
                    -- 规则：
                    --   * 上一轮是忙的、这一轮空闲了 → **是新的一轮空闲 → 发起** ✓✓
                    --   * 上一轮就空闲、且已决策过 → 除非冷却到期，否则不发 ✓
                    local wasIdle = self.idleSeen[name] == true
                    local lastAt = self.decided[name]
                    local cooldown = (lastAt == nil) or (now - lastAt > self.REDECIDE_COOLDOWN)

                    if (not wasIdle) or cooldown then
                        self.idleSeen[name] = true
                        self.decided[name] = now
                        self.inFlight[name] = { at = now }
                        CopilotRpc.trace("fleet: 空闲 → 发起 decide ship=" .. tostring(name)
                            .. (wasIdle and "（冷却到期重发 ✓）" or "（新的一轮空闲 ✓）"))
                        CopilotFleet.askDecide(name, goal)
                    end
                elseif busy == true then
                    -- 忙了 → 下一轮空闲就是"新的一轮" ✓
                    self.idleSeen[name] = false
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
        self.decided[ship] = nil          -- 发都没发出去 → 不算决策过 ✓（下轮可重试 ✓）
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

    -- ★★ 这里**不再**由游戏侧发 order ✗→✓（2026-10-16 改）
    --
    -- 旧设计：游戏发 decide → DSH 回 {action, params} → **游戏再调 DSH 的 order** ✗
    -- 新设计：**DSH 收到 decide 后自己拉数据、自己决策、自己调游戏的 order** ✓✓
    --   （主人的架构：「DSH 这侧接管 DECIDE」✓）
    -- 所以这条回调用现在是**多余**的 ✓，而且每次都会报
    --   "this side has no handler for 'order'" ✗（实测日志里刷了一堆 ✓）。
    -- 这里只做一件事：**放开 inFlight** ✓ —— 船若真忙起来了，下轮扫描自然不会重发 ✓。
    self.inFlight[ship] = nil
    self.stats.ordered = self.stats.ordered + 1
    CopilotRpc.trace("fleet: 决策已交给 DSH 执行（游戏侧不再发 order ✓）ship="
        .. tostring(ship) .. " action=" .. tostring(action))
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
