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
--   选项  —— 结构化候选（`Mine` / `Salvage` / `Trade` / `Travel` ✓）
-- 两者**可以同时存在** ✓：文案给意图、选项给边界 ✓✓
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

-- 四条后台命令，见 LLM-OPS.md / TODO.md ✓
M.KNOWN_ACTIONS = { "Mine", "Salvage", "Trade", "Travel", "None" }

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

function M.describe(player, ship)
    local g = M.get(player, ship)
    local good, bad = M.sanitizeOptions(g.options)
    return {
        ship = ship,
        text = g.text,              -- 文字意图（可能为空串 ✓）
        options = good,             -- 规范化后的候选动作 ✓
        unknown = bad,              -- 玩家写错的选项（原样回传，便于 DSH 提示 ✓）
        hasGoal = g.hasGoal,
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
