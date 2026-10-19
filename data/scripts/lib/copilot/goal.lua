package.path = package.path .. ";data/scripts/lib/?.lua"
package.path = package.path .. ";data/scripts/?.lua"
-- copilotgoal —— **每艘船的"目标"存取**（主人 2026-10-14 定的核心概念）。
--
-- 主人的原话：
--   「每艘被激活的船，我应该需要能设定一个目标，可以是直接文字描述，也可以是一些选项。
--     然后这艘船一空闲，就应该由游戏那边发起请求，DSH 收到相应请求后，
--     调用 RPC 调集游戏内数据，做具体决策。」
--
-- 于是「目标」是**只存在游戏侧的 per-ship 数据** ✓：
--   * 游戏侧只负责**存**它 + **空闲时把船名发出去** ✓
--   * **DSH 用 `query {what="goal", ship=...}` 主动来取** ✓✓（不推 ✗）
--
-- 存储用 player value ✓（跨脚本/跨 VM 唯一可靠通道 ✓，AGENTS.md 的实测结论 ✓）。
-- **per-ship 用独立 key** ✓ —— 免得解析多行字符串时被船名里的字符搞坏 ✓。
--
-- 两种目标：
--   文字  —— 玩家自由描述（"去西北方探索，遇到敌人就跑" ✓）
--   选项  —— ★ **2026-10-19 退役** ✗✓：以前是玩家/工具手填的动作白名单 ✓
--            （真事故：`Trader-00001` 被设成 `[Travel]` ✗ → 它**永远不能跑商** ✗✓）。
--            现在白名单**按船自动推导** ✓（`lib/copilot/card.lua` 的 `M.deriveActions` ✓），
--            本文件只剩**文字目标**这一种可写目标 ✓✓
-- 两者**可以同时存在** ✓：文案给意图、选项给边界 ✓✓
--
-- ★ `copilot_goal_kind_<船名>` 这份**旧存档数据不删** ✓（不破坏存档 ✓）——
--   但**读的时候忽略** ✗：`M.describe` 把它回传成 `ignoredOptions`（审计用 ✓），
--   `options` 字段一律换成**推导值** ✓✓。
--
-- 本文件是 lib：只能 return 命名空间表，不许定义全局生命周期回调 ✓。
--
-- 本文件是 lib：不挂载、不定义生命周期回调，所以**不写 name-space 声明** ✓
-- ⚠️ 千万别写成 -- name-space xxx 开头 ✗ —— 引擎会解析那行，且 name-space 名里不许有空格/中文 ✓

local M = {}

-- key 前缀。用 `copilot_goal_` 开头，和 mod 的其它 value 不冲突 ✓
local PREFIX = "copilot_goal_"
local KIND_PREFIX = "copilot_goal_kind_"     -- "text" | "options" | "both"

-- ---------------------------------------------------------------------------
-- 基础读写
-- ---------------------------------------------------------------------------

local function textKey(ship) return PREFIX .. ship end
local function kindKey(ship) return KIND_PREFIX .. ship end

-- 设文字目标。传 nil 或空串 = 清掉 ✓
function M.setText(player, ship, text)
    if player == nil or type(ship) ~= "string" or ship == "" then return false end
    if text == nil or tostring(text) == "" then
        player:setValue(textKey(ship), "")
    else
        player:setValue(textKey(ship), tostring(text))
    end
    return true
end

-- 设选项目标。`options` 是字符串数组（例如 {"Mine", "Salvage"} ✓）。
-- 传 nil / 空表 = 清掉 ✓
-- ★ 2026-10-19：这个写入口**已退役** ✗（没有调用方了 ✓ —— `link_in.onSetGoal` 忽略 `data.options` ✓，
--   面板也不再提供选择 ✓）。函数**保留**只为两件事：① 旧存档里的数据要能读（`M.get` ✓）；
--   ② `M.clear` 清目标时顺手清掉这份旧键 ✓。**别再加新的调用方** ✗✓。
function M.setOptions(player, ship, options)
    if player == nil or type(ship) ~= "string" or ship == "" then return false end
    if type(options) ~= "table" or #options == 0 then
        player:setValue(kindKey(ship), "")
        return true
    end
    -- 用换行分隔（选项名里不会有换行 ✓）
    local out = {}
    for _, o in ipairs(options) do
        local s = tostring(o):gsub("[\r\n]", " ")
        if s ~= "" then out[#out + 1] = s end
    end
    player:setValue(kindKey(ship), table.concat(out, "\n"))
    return true
end

-- 读一艘船的完整目标：{ text = "...", options = {...} }
function M.get(player, ship)
    local goal = { ship = ship, text = "", options = {} }
    if player == nil or type(ship) ~= "string" then return goal end

    local t = tostring(player:getValue(textKey(ship)) or "")
    if t ~= "" then goal.text = t end

    local o = tostring(player:getValue(kindKey(ship)) or "")
    if o ~= "" then
        for line in o:gmatch("[^\n]+") do
            goal.options[#goal.options + 1] = line
        end
    end

    goal.hasGoal = (goal.text ~= "" or #goal.options > 0)
    return goal
end

-- 清掉一艘船的目标
function M.clear(player, ship)
    M.setText(player, ship, nil)
    M.setOptions(player, ship, nil)
    return true
end

-- ---------------------------------------------------------------------------
-- 选项目标的语义（游戏侧只做**合法性**校验 ✓，不做决策 ✓）
-- ---------------------------------------------------------------------------

-- 六条后台命令（+ None），与 `link_in.lua` 的 COMMAND_TYPES **必须一致** ✓
-- （2026-10-17 补全 ✗→✓：旧表漏了 Sell / Scout / Refine ✗ → 玩家写 `options Sell` 会被判 unknown ✗✓，
--   于是"满舱先卖"这种正当约束反而把自己卡死 ✓。新增动作时**这张表与 cli 提示一起改** ✓。）
M.KNOWN_ACTIONS = { "Mine", "Salvage", "Trade", "Travel", "Sell", "Scout", "Refine", "None" }

-- 把选项名规范化（大小写容错：`mine` / `MINE` / `Mine` 都认 ✓）
function M.normalizeAction(name)
    if type(name) ~= "string" then return nil end
    local lower = name:lower()
    for _, a in ipairs(M.KNOWN_ACTIONS) do
        if a:lower() == lower then return a end
    end
    return nil
end

-- 把玩家的选项过滤成已知动作 ✓（返回规范名数组 + 被丢弃的名字）
function M.sanitizeOptions(options)
    local good, bad = {}, {}
    for _, o in ipairs(options or {}) do
        local n = M.normalizeAction(o)
        if n ~= nil then good[#good + 1] = n else bad[#bad + 1] = tostring(o) end
    end
    return good, bad
end

-- ---------------------------------------------------------------------------
-- 给 DSH 用的形状（`query {what="goal"}` 的 data ✓）
-- ---------------------------------------------------------------------------
--
-- ★★★ 2026-10-19 退役「玩家限定动作」后的**唯一语义出口** ✓✓
--
--   `options` 现在**不是** player value 里的那份 ✗ —— 而是 `Card.allowedActions` 按船推导的 ✓
--   （推导判据与"为什么"见 `lib/copilot/card.lua` 的 `M.deriveActions` ✓）。
--   旧存档里存的那份**原样回传**成 `ignoredOptions` ✓（**不删数据** ✓ 但**不生效** ✗✓）——
--   于是"旧 options 被忽略"这件事在回执里**看得见** ✓，不是靠猜 ✓✓。
--
--   ★ 推导失败（include 报错之类）→ 退回**最小集合 `{Travel}`** ✓ + `optionsDerived=false` ✓：
--     宁少不多 ✗✓（多给会让它去下单必然失败的动作 ✓）。
function M.describe(player, ship)
    local g = M.get(player, ship)
    local ignored, bad = M.sanitizeOptions(g.options)

    local derived, why, note, ok = nil, {}, nil, false
    do
        local okCall, actions, whyOut, noteOut = pcall(function()
            local Card = include("copilot/card")
            local acts, whyIn, _facts, _notes, noteIn = Card.allowedActions(player, ship)
            return acts, whyIn, noteIn
        end)
        if okCall and type(actions) == "table" and #actions > 0 then
            derived = actions
            if type(whyOut) == "table" then why = whyOut end
            note = noteOut
            ok = true
        end
    end
    if derived == nil then
        derived = { "Travel" }
        note = "推导失败 ✗ → 退回最小集合 {Travel}（不猜别的动作 ✓）；请查 rpc_trace.log ✓"
    end

    return {
        ship = ship,
        text = g.text,               -- 文字意图（可能为空串 ✓）—— **现在唯一可写的目标** ✓
        options = derived,           -- ★ 按船自动推导的可选动作 ✓（仍是白名单语义 ✓）
        optionsDerived = ok,         -- true = 推导成功 ✓；false = 退回最小集合 ✗
        optionsSource = "auto: card.lua deriveActions()（不再是玩家填的 ✗✓）",
        optionsWhy = why,            -- 每条动作的依据 ✓（审计/面板用 ✓）
        optionsNote = note,          -- 未知/不足说明 ✓
        ignoredOptions = ignored,    -- ★ 旧存档里的白名单：**已忽略** ✗✓（非空 = 那艘船曾被人手填过 ✓）
        unknown = bad,               -- 旧数据里写错的选项（原样回传 ✓）
        hasGoal = (g.text ~= ""),    -- ★ 只有文字目标才算"指派过" ✓（旧白名单不再算 ✗）
    }
end

-- 列出**有目标**的船（诊断/排查用 ✓）
function M.list(player, ships)
    local out = {}
    for _, s in ipairs(ships or {}) do
        local d = M.describe(player, s)
        if d.hasGoal then out[#out + 1] = d end
    end
    return out
end

return M
