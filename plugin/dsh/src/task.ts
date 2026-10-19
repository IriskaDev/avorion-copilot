/**
 * task.ts —— 投递进投递目标会话的**任务块**，与它的**答案契约**（Phase A ✓）
 *
 * 这是「插件 ⇄ 会话」之间唯一的接口 ✗✓ —— 协议在这里、校验也在这里 ✓，
 * 这样"任务长什么样"和"什么算合格答案"永远不会各改各的 ✓（原型
 * `test/commander-dispatch-proto.mjs` 的 shape 原样搬过来 ✓）。
 *
 * ## 为什么答案里必须回显 `task=<id>`（**这条不能省**）
 *
 * 投递目标会话是**一条活着的、主人也在用的普通会话** ✓✓。所以同一轮里可能出现：
 *   · 主人在聊天，她的回复与任务交错 ✓
 *   · 主人一次性投了几艘船 → 会话里连着几条任务 ✓
 * 于是"最后一条 assistant/message 就是结论"**不总成立** ✗。
 * 契约要求她回显 `task=<id>` ✓；对不上就判 `TASK_MISMATCH` 并走阶梯 ✓ ——
 * **绝不把别的船的答案用在这艘船上** ✗✓。
 *
 * （★ 诚实说明：她**不回显**时我们**不判失败** ✗ —— 只降级成"无回显"✓。
 *  理由是主人要的是"能聊天、能现修"的会话，不是必须背格式的机器人 ✓；
 *  而**回显了但写错**才是真危险（说明她在答别的船 ✓）→ 那才判 MISMATCH ✓。）
 */

/**
 * 一次任务请求（插件 → 会话）的**全部**内容 ✓。
 *
 * ★★★ 2026-10-17 主人批准的改动：**agent 路径只投递"通知"** ✓✓
 *
 * 主人的原话：
 *   「你应该仅投递决策请求，就仅仅是告知会话，有东西需要决策就行了，
 *     然后会话再根据插件提供的工具自行查询，有什么东西需要决策。」
 *
 * → 所以投进会话的块里**只有**：船名 ✓、任务号 ✓、期限提示 ✓、
 *   一行"它空闲了、要一个决策" ✓、**工具指针**（哪个查询查什么 ✓）、
 *   答案行契约 ✓、`task=` 回显要求 ✓。
 * → 而**数据一律不给** ✗✓：船卡、计划 JSON、渲染好的候选表**都不进这个块** ✓。
 *
 * 为什么 ✗→✓（实测血案，别忘）：这个块曾经是"预取的全部数据"——
 *   船卡两遍 ✓、每个计划的原始 JSON ✓、再叠一层渲染好的候选表 ✓、再加一段散文 ✓，
 *   于是一份 8.7 MB 的 Scout 计划把整条任务文本撑到 **8,761,847 字符** ✓，
 *   被会话层截断 ✓、模型侧直接超上下文 ✓（requested 3,068,511 tokens > 1,048,576 ✓）。
 *   ★ 根因不是"少了一个上限" ✗，而是**推**（push）而不是**通知 + 自拉**（notify + pull）✓✓。
 *
 * ★ 那两条字段（`card` / `planText`）**保留在类型里**是为了**向后兼容** ✓：
 *   老的调用方仍然可以传（TS 不报错 ✓），但 `renderTaskBlock` **不再读它们** ✗✓ ——
 *   也就是说"就算有人传了 8 MB，这个块也不会变大" ✓✓（这条有测试钉住 ✓）。
 */
export interface TaskRequest {
  /** 任务 id：回显契约的锚点 ✓（形如 `t-1a2b3c4d`） */
  taskId: string
  ship: string
  goalText: string
  goalOptions: string[]
  /**
   * @deprecated agent 路径**不再投递数据** ✗（2026-10-17 ✓）。
   *   类型上留着只为向后兼容；`renderTaskBlock` 忽略它 ✓。
   *   单发那条路的档案在 `dossier.ts`（预取 + 裁剪 + 字节预算 ✓）。
   */
  card?: unknown
  /**
   * @deprecated 同上：agent 路径不再投递渲染好的计划 ✗（那正是 8.7 MB 的来源 ✓）。
   *   会话要用计划就**自己查**（`fleet_query` 的 `*Plan`，缺省 compact ✓）。
   */
  planText?: string
  /** 建议预算（秒）；写进任务头，告知会话层硬期限 ✓ */
  deadlineHintSec: number
  /**
   * ★★ B：**上一轮没答到的船数**（2026-10-18 主人点名要的"可见" ✓✓）。
   *
   * 为什么必须写进块里 ✗→✓：漏答以前是**静默**的 ✓ —— 决策者根本不知道
   * 上一轮有船没被答到（`fallbackNone` 只落在插件自己的日志里 ✗）。
   * 现在它渲染成块**末尾一行**「上次未答：X 艘」✓，她每一轮都看得见 ✓✓。
   */
  unansweredBefore?: number
  /**
   * ★ 上一单结果（2026-10-17 补 ✓）：渲染时附在块末尾的「你上一单的结果」一行 ✓。
   *   用途两个（同一字段 ✓）：
   *     · 正常轮：决策者下一轮就能看到"上次成没成"（不触发回投也看得见 ✓）；
   *     · 失败回投：带上一单的失败原因 + "请重新决策" ✓。
   *   ★ 体积预算 ~200 字节：超了就当没加上 ✗✓（renderTaskBlock 会跳过 ✓）。
   */
  prevResult?: string
}

/** 校验结论 */
export type AnswerCode =
  | 'EMPTY_REPLY'      // 这一轮一个字都没有 ✓
  | 'NO_ACTION_LINE'   // 没有 action= 行 ✓
  | 'ASKED_OWNER'      // ★ 没有 action，但在问主人 → **不算失败** ✓（显式延期 ✓）
  | 'TASK_MISMATCH'    // 回显的 task 不是本任务 ✓（**绝不采纳** ✗）
  | 'BAD_ACTION'       // action 不在允许集合内 ✓

/** 解析出来的答案（与 `DecideAnswer` 同形 ✓ —— 下单那条路径一个字都不用改 ✓） */
export interface TaskAnswer {
  action: string
  params: Record<string, unknown>
  reason?: string
  /** 原文（审计用 ✓） */
  raw?: string
}

export type AnswerVerdict =
  | { ok: true; answer: TaskAnswer; /** 有没有回显 task（false = 她没写，仍然采纳 ✓） */ echoed: boolean }
  | { ok: false; code: AnswerCode; message?: string; question?: string }

/** 表示"没有"的几种写法，别当成值 ✓（与 index.ts 的 NONE_WORDS 同源 ✓） */
const NONE_WORDS = new Set(['', '-', 'none', 'null', 'n/a', 'na', '无', '没有', '否'])

/**
 * 逐行取 `key=value`（与 `index.ts` 的 `field()` 同一套容错 ✓）：
 * 容忍 `key: value`、`**key=value**`、全角冒号、行首 `- `/`* `、行尾星号 ✓。
 * ★ 与 index.ts 那份**故意保持同形** ✓ —— 两边读同一份"她的回答"必须得出一致的结论 ✓。
 */
export function field(text: string, key: string): string | undefined {
  const match = new RegExp(`^\\s*[*-]?\\s*\\**\\s*${key}\\s*[:=：]\\s*(.*)$`, 'im').exec(text)
  if (match === null) return undefined
  return match[1].replace(/\*+$/, '').replace(/[`*"']/g, '').trim()
}

/** 数字字段（容忍 `-406` / `x = -406` / `(-406,73)` 取第一段 ✓） */
function numField(text: string, key: string): number | undefined {
  const raw = field(text, key)
  if (raw === undefined) return undefined
  const m = /-?\d+(?:\.\d+)?/.exec(raw)
  if (m === null) return undefined
  const v = Number(m[0])
  return Number.isFinite(v) ? v : undefined
}

/** 布尔字段（容忍 true/false、yes/no、1/0、是/否 ✓ —— 与 index.ts 同款 ✓） */
function boolField(text: string, key: string): boolean | undefined {
  const raw = field(text, key)
  if (raw === undefined) return undefined
  const w = raw.trim().toLowerCase()
  if (['true', 'yes', 'y', '1', '是', '开', 'on'].includes(w)) return true
  if (['false', 'no', 'n', '0', '否', '关', 'off'].includes(w)) return false
  return undefined
}

/** ★ 「你上一单的结果」一行的字节预算（~200 ✓；超了就当没加 ✗✓） */
export const PREV_RESULT_BUDGET_BYTES = 200

/** 船名清单字段（`Miner-1, Miner-2`；"无" 之类的词丢掉 ✓ —— 与 index.ts 同款 ✓） */
function listField(text: string, key: string): string[] {
  const raw = field(text, key)
  if (raw === undefined) return []
  return raw.split(/[,，、]/).map((s) => s.trim())
    .filter((s) => s !== '' && !NONE_WORDS.has(s.toLowerCase()))
}

/**
 * ★★★ 渲染任务块 —— **只告知，不灌数据** ✓✓（2026-10-17 主人批准的改动）
 *
 * 这个函数是"agent 路径"的**唯一**渲染点 ✓。它的输出目标是 **远小于 2 KB** ✓，
 * 且**与计划有多大无关** ✗✓ —— 因为计划一个字节都不进来 ✓。
 *
 * ## 它为什么长这样（每条都有实测理由 ✓）
 *
 * | 要素 | 为什么不能省 |
 * |---|---|
 * | `<fleet_task …>` / 结尾标记 | 投递目标是主人**正在聊天的那条会话** ✓ —— 她必须一眼看出"这是舰队的活儿，不是主人在说话" ✗✓ |
 * | 船名 | 不写船名，她连该查哪艘都不知道 ✓ |
 * | `task=<id>` 回显 | **唯一**能认出"哪条回复是这一单"的锚点 ✓（见文件头 ✓）；对不上就判 MISMATCH 并走阶梯 ✓ |
 * | 一行"它空闲了、要一个决策" | 这就是**全部**的请求内容 ✓（主人原话 ✓） |
 * | 工具指针 | 让"自拉"变得**不用猜** ✓ —— 哪个 `what` 查什么、哪个参数要小答案 ✓（这是这次改动的**关键**：光说"你自己查"而不给路由，等于把体积问题换成瞎猜问题 ✗✓） |
 * | 期限提示 | 会话层有硬闸 ✓（超了 `cancel({kind:'hook'})` 并落单发 ✓）—— 写进任务头告知硬期限 ✓ |
 * | 答案行契约（**放最后**，且要"放最前"） | 实机事故：正文被 maxTokens 截断、一个动作行都没吐 ✓ → 契约必须显眼 ✓ |
 *
 * ★ 为什么结论行要求**放最前** ✗✓：`plugin/dsh/prompt/system.md` 与 `src/index.ts` 的重试路径
 *   都记录了同一个事故 ✓ —— 把契约写清楚，最坏情况丢的是散文，不是结论 ✓。
 *
 * ★ 为什么**没有**"参考计划"段 ✗✓：那一段以前是 `planText`（`buildPrompt()` 的全文 ✓）——
 *   也就是 8.7 MB 的入口 ✓。现在她要计划就**自己查** ✓（`fleet_query`，缺省 compact ✓）。
 */
/** 主人写的自然语言目标最多带 240 字节进提示词（超了截断加省略号 ✓ —— 块体积有契约 ✓） */
const GOAL_TEXT_BUDGET_BYTES = 240

function clipGoalText(text: string): string {
  const t = text.trim()
  if (Buffer.byteLength(t, 'utf8') <= GOAL_TEXT_BUDGET_BYTES) return t
  let cut = t
  while (cut !== '' && Buffer.byteLength(cut, 'utf8') > GOAL_TEXT_BUDGET_BYTES) {
    cut = cut.slice(0, -1)
  }
  return cut + '…'
}

export function renderTaskBlock(req: TaskRequest): string {
  const L: string[] = []
  L.push(`<fleet_task id="${req.taskId}" ship="${req.ship}" deadline_hint="${req.deadlineHintSec}s">`)
  L.push('★ 插件投递的舰队决策请求（不是主人在说话 ✗）。')
  L.push(`  ${req.ship} 现在**空闲**了，需要一个决策。`)
  L.push('  ★ 只告知、不带数据 ✗ —— 需要什么**自己查** ✓（路由如下）。')
  L.push('')
  L.push('查证工具（先 list 再查）：')
  L.push('  · {what:"list"} → 船名单（名字/忙闲/船长/星区）')
  L.push(`  · {what:"ship", ship:"${req.ship}", brief:true} → 这艘船现状`)
  L.push(`  · {what:"systemsFacts", ship:"${req.ship}"} → 槽位/模块/处理能力（只读）`)
  L.push(`  · {what:"goal", ship:"${req.ship}"} → 目标边界`)
  L.push('  · {what:"sectorFacts", x, y} → 星区事实')
  L.push('  · {what:"tradeRoutes"} → 框内路线；{what:"tradeEvaluate", boxes, deposits} → 多框×商品×本金（净利/小时降序 + rejected）')
  L.push('  · {what:"predict", ship, action, x, y, sizeX, sizeY, …} → 一框一动作预测')
  L.push('  · 材料升级：mountQuote/shipQuote/blockQuote → 只读报价；' +
    'mountUpgrade/blockUpgrade/shipUpgrade → 需 confirm:true（★ 先报价 ✓）')
  L.push('  · 侦察：predict{Scout, 21x21} → 未知/已知/总数 + revealsNothingNew')
  L.push('  · legacy 计划(扫67框+排序)：tradePlan|minePlan|salvagePlan|sellPlan|scoutPlan')
  // ★★ 2026-10-19：主人的**自然语言目标**终于进提示词了 ✗→✓
  //   链路：`query{what:"goal"}.text` → index.ts 的 facts.goalText → 这里 ✓
  //   （旧版只渲染 goalOptions，文字目标**一句都没进提示词** ✗✓ —— 于是"在面板里写一句话"
  //     这个用法在决策侧等于不存在；`test/commander-dispatch-proto.mjs:49` 的原型本来是有的 ✓）
  if (typeof req.goalText === 'string' && req.goalText.trim() !== '') {
    L.push(`  · 主人给这艘船的目标：${clipGoalText(req.goalText)}（当**边界**用，不是命令 ✓）`)
  } else {
    L.push('  · 这艘船没写文字目标 → 按它的**分类 / 装备**自己定（主人不逐条指派 ✓）')
  }
  // ★★ 2026-10-19 退役「玩家限定动作」✗→✓：`goalOptions` 现在是**按船自动推导**的白名单
  //   （游戏侧 `lib/copilot/card.lua` 的 `M.deriveActions` ✓，`query{what:"goal"}.options` ✓）。
  //   白名单**语义不变**（仍然"只有这些 + None"✓），只是不再由主人/模型填 ✓✓。
  if (req.goalOptions.length > 0) {
    L.push(`  · 可选动作（按船自动）：${req.goalOptions.join(', ')}（只有这些 + None）`)
  }
  L.push(`  · fleet_decisions {ship:"${req.ship}"} → 历史决策`)
  L.push('  ★ fleet_query；legacy 用 compact/top。')
  L.push('')
  L.push('答复格式（★ **第一行**请直接写结论行 action=…，之后写理由）：')
  L.push('  第 1 行 action=<Mine | Salvage | Trade | Sell | Scout | Travel | Refine | None>')
  L.push(`  第 2 行 task=${req.taskId}  ← ★必须回显（回显即唯一凭据）；`)
  L.push('    写错 → 判无效（别船答案不许混用 ✗）。')
  L.push('  之后按需要：x= y= sizeX= sizeY= duration= goodName= deposit= safeMode= escorts= goodsToSell= reason=')
  L.push('  需要主人拍板就写出来（不写 action 行 = 等主人裁决）。')
  L.push('  任务行后照常**跟主人聊天 ✓（舰队只看上面几行）。')
  // ★ 上一单结果（2026-10-17 补 ✓）：决策者下一轮就能看到"上次成没成"，失败回投时也能看到"为什么失败" ✓。
  //   体积预算 ~200 字节：超了就当没加 ✗✓（调用方 index.ts 会先截断并在流水里说明 ✓）。
  if (typeof req.prevResult === 'string' && req.prevResult.trim() !== '') {
    // ★ 2026-10-17：措辞"上一单"（不是"你上一单"✗）—— 上一单可能是单发/兜底定的，
    //   来源由调用方 index.ts 的 renderPrevResult 用 `[decider]` 标签标明 ✓（不冒名 ✗✓）。
    const line = `★ 上一单的结果：${req.prevResult.trim()}`
    if (Buffer.byteLength(line, 'utf8') <= PREV_RESULT_BUDGET_BYTES) L.push(line)
  }
  // ★★ B（2026-10-18）：漏答**必须可见** ✓ —— 上一轮没答到的船数写进块末尾一行 ✓✓
  if (typeof req.unansweredBefore === 'number' && req.unansweredBefore > 0) {
    L.push(`★ 上次未答：${req.unansweredBefore} 艘（它们会**稍后重投** ✓ —— 请把每条任务都答到 ✓）`)
  }
  L.push('</fleet_task>')
  return L.join('\n')
}

// ---------------------------------------------------------------------------
// ★★ A：**合并一块**投递（2026-10-18，主人原话：「我感觉你总是会漏，
//     尤其是多个决策同时来的时候」✓✓）
//
// 病根（有真机日志 ✓）：多艘船同时空闲 → 插件**各投递一个** fleet_task ✗，
//   而决策者一轮只答得了一个 ✓ → 没答到的被判 `fallbackNone` ✗ 然后进
//   **20 分钟待命冷却** ✗✓ → 那艘船静默 20 分钟 ✓。
//
// 治法：多艘同时要决策时**合并成一个块** ✓（块里只列 船名 + 任务号，
//   **不带数据** —— 与现有 2 KB 契约一致 ✓），并允许**一次回多组**答案 ✓
//   （每组 `action=` 与 `task=` 成对，解析器按 task id 匹配 ✓）。
//
// ★ 1 艘时 `renderTaskBatchBlock` **逐字退回** `renderTaskBlock` ✓ ——
//   单船路径一个字节都不变（向后兼容 ✓，`delivery-size.mjs` 钉住 ✓）。
// ---------------------------------------------------------------------------

/** 一条待决策任务（合并块里的一个条目 ✓ —— 只有船名 + 任务号 + 动作边界 ✓） */
export interface TaskBatchRequest {
  items: TaskRequest[]
  /** ★ B：这一轮是「上一轮没答到」的重投（措辞不同、可见 ✓） */
  retryRound?: boolean
}

/**
 * 渲染一个**合并**任务块 ✓（1 条 = 与 `renderTaskBlock` 逐字相同 ✓）。
 *
 * 体积：工具指针段在合并块里**只写一遍**（generic，不带船名 ✓），
 * 每艘船只占一行 ✓ —— 所以 3 艘也在 2 KB 目标内 ✓（`batch-merge.mjs` 钉住 ✓）。
 */
export function renderTaskBatchBlock(batch: TaskBatchRequest): string {
  const items = batch.items ?? []
  if (items.length === 0) return ''
  // ★ 1 条 = **逐字**走单船渲染器 ✓（向后兼容；不需要第二套措辞 ✓）
  if (items.length === 1) return renderTaskBlock(items[0])

  const ids = items.map((i) => i.taskId)
  const names = items.map((i) => i.ship)
  const deadline = Math.max(...items.map((i) => i.deadlineHintSec))
  const L: string[] = []
  L.push(`<fleet_task id="${ids[0]}" count="${items.length}" ships="${names.join(',')}" deadline_hint="${deadline}s">`)
  L.push(`★ 插件投递的舰队决策请求（不是主人在说话 ✗）—— **本轮 ${items.length} 艘船同时空闲** ✓。`)
  L.push('  ★ 只告知、不带数据 ✗ —— 需要什么**自己查** ✓（路由见下）。')
  L.push(`待决策 ${items.length} 条（每条 = 船名 + 任务号 ✓）：`)
  for (const it of items) {
    // ★ 可选动作 = **按船自动推导**（2026-10-19 起 ✗✓，不再是玩家填的）
    const lim = it.goalOptions.length > 0 ? `  可选动作(按船自动): ${it.goalOptions.join(', ')}` : ''
    // ★ 自然语言目标也要带上（主人 2026-10-19 的用法 ✓）；空 = 自动，不写 ✓
    const gt = typeof it.goalText === 'string' ? clipGoalText(it.goalText) : ''
    const goal = gt !== '' ? `  主人目标: ${gt}` : ''
    L.push(`  · ${it.ship}   task=${it.taskId}${lim}${goal}`)
  }
  L.push('查证工具（先 list 再查；下面 `ship` 一律填**对应船名** ✓）：')
  L.push('  · {what:"list"} → 船名单；{what:"ship", ship, brief:true} → 船现状')
  L.push('  · {what:"systemsFacts", ship} → 槽位/模块；{what:"goal", ship} → 目标边界')
  L.push('  · {what:"sectorFacts", x, y} → 星区事实；{what:"predict", ship, action, x, y, sizeX, sizeY} → 一框一动作')
  L.push('  · {what:"tradeRoutes"} / {what:"tradeEvaluate", boxes, deposits} → 路线 / 多框矩阵')
  L.push('  · 材料升级：mountQuote/shipQuote/blockQuote 只读；*Upgrade 需 confirm:true（★ 先报价 ✓）')
  L.push('  · 侦察：predict{Scout, 21x21}；legacy 计划(扫67框)：tradePlan|minePlan|salvagePlan|sellPlan|scoutPlan（compact/top）')
  L.push('答复格式（★ **每艘一组**，可以一次回**多组** ✓ —— 靠 task= 对上号）：')
  L.push('  每组：第 1 行 action=<Mine | Salvage | Trade | Sell | Scout | Travel | Refine | None>，第 2 行 task=<该船的任务号>')
  L.push('  例：action=Mine / task=' + ids[0] + ' / x=… y=… size=15')
  L.push('  ★ 不判的那艘**就别写它的组** ✓（它会被稍后重投 ✓）；task= 写错 = 那组作废 ✗')
  L.push('  之后照常**跟主人聊天 ✓（舰队只看上面这些组）。')
  if (typeof items[0].prevResult === 'string' && items[0].prevResult.trim() !== '') {
    const line = `★ 上一单的结果：${items[0].prevResult.trim()}`
    if (Buffer.byteLength(line, 'utf8') <= PREV_RESULT_BUDGET_BYTES) L.push(line)
  }
  // ★ 注意是 **max**，不是求和 ✗：每条 item 带的是**同一份**队列快照（同一个数 ✓），
  //   求和会把"N 艘没答到"说成 N×N ✗✓。
  const unanswered = items.reduce((n, it) => Math.max(n, typeof it.unansweredBefore === 'number' ? it.unansweredBefore : 0), 0)
  if (batch.retryRound === true || unanswered > 0) {
    L.push(`★ 上次未答：${Math.max(1, unanswered)} 艘（本轮是**重投** ✓ —— 请把每条都答到 ✓）`)
  }
  L.push('</fleet_task>')
  return L.join('\n')
}

// ---------------------------------------------------------------------------
// ★★ A：**多组答案**的解析器（2026-10-18 ✓）
//
// 契约：可以一次回多组，每组 = `action=` 行 + `task=<该船任务号>` 行 ✓。
//   · **按 task id 匹配** ✓（组顺序随意 ✓）；
//   · 组里没写 task=（没回显）→ 只有"组数 == 还没配上的船数"时才**按顺序**配 ✓
//     （否则**不猜** ✗ —— 猜错就是把别船的答案用在这艘船上 ✓）；
//   · 一条组都没写（没动作行）→ 每艘船各得一份同样的结论（ASKED_OWNER / NO_ACTION_LINE ✓）。
// ★ N == 1 时**直接委托** `validateAnswer` ✓ —— 单船语义逐字不变（向后兼容 ✓）。
// ---------------------------------------------------------------------------

export interface AnswerGroupSpec {
  taskId: string
  ship?: string
  allowedActions: string[]
}

export interface MultiAnswerVerdict {
  /** 每条船自己的结论 ✓（**没有这个 key = 本轮没答到** ✓） */
  verdicts: Map<string, AnswerVerdict>
  /** 这一轮里看到的 `action=` 组数 ✓ */
  groups: number
  /** 靠 `task=` 回显对上的组数 ✓ */
  echoedGroups: number
  /** 回了、但 task= 不属于本批的（别船的答案，**绝不采纳** ✗） */
  stray: string[]
}

/** 把一段文本按 `action=` 行切成组 ✓（每组从 action= 行起到下一组前 ✓） */
export function splitAnswerGroups(text: string): string[] {
  const src = typeof text === 'string' ? text : ''
  const re = /^[ \t]*[*-]?[ \t]*\**[ \t]*action[ \t]*[:=：]/gim
  const idx: number[] = []
  for (let m = re.exec(src); m !== null; m = re.exec(src)) idx.push(m.index)
  if (idx.length === 0) return []
  const out: string[] = []
  for (let i = 0; i < idx.length; i++) {
    const end = i + 1 < idx.length ? idx[i + 1] : src.length
    out.push(src.slice(idx[i], end))
  }
  return out
}

/**
 * 校验**一次回多条**的答案 ✓（N == 1 时等价于 `validateAnswer` ✓）。
 */
export function validateAnswers(text: string, items: AnswerGroupSpec[]): MultiAnswerVerdict {
  const verdicts = new Map<string, AnswerVerdict>()
  const stray: string[] = []
  const groups = splitAnswerGroups(text)
  if (items.length === 0) return { verdicts, groups: groups.length, echoedGroups: 0, stray }

  // ★ 向后兼容：一条船 → 完全走原来的单条校验器 ✓
  if (items.length === 1) {
    const only = items[0]
    verdicts.set(only.taskId, validateAnswer(text, only.taskId, only.allowedActions))
    return { verdicts, groups: groups.length, echoedGroups: 0, stray }
  }

  if (groups.length === 0) {
    // 一个动作行都没有 → 每艘船都得到同一份结论（她在问主人 / 她没写动作行 ✓）
    const single = validateAnswer(text, items[0].taskId, items[0].allowedActions)
    for (const it of items) {
      verdicts.set(it.taskId, !single.ok && single.code === 'ASKED_OWNER'
        ? { ok: false, code: 'ASKED_OWNER', question: single.question }
        : single)
    }
    return { verdicts, groups: 0, echoedGroups: 0, stray }
  }

  // ① 按回显配对 ✓
  const unclaimed = [...items]
  const noEcho: string[] = []
  let echoedGroups = 0
  for (const g of groups) {
    const echo = field(g, 'task')
    if (echo === undefined || echo === '') { noEcho.push(g); continue }
    const at = unclaimed.findIndex((it) => it.taskId === echo)
    if (at < 0) { stray.push(echo); continue }
    const it = unclaimed.splice(at, 1)[0]
    verdicts.set(it.taskId, validateAnswer(g, it.taskId, it.allowedActions))
    echoedGroups += 1
  }
  // ② 没回显的组：**组数与剩下的船数严格相等**才按顺序配（否则不猜 ✗）
  if (noEcho.length > 0 && noEcho.length === unclaimed.length) {
    for (let i = 0; i < noEcho.length; i++) {
      const it = unclaimed[i]
      verdicts.set(it.taskId, validateAnswer(noEcho[i], it.taskId, it.allowedActions))
    }
  }
  return { verdicts, groups: groups.length, echoedGroups, stray }
}

/**
 * 校验会话的答案 ✓（**机器可检** —— 人格多花哨都不影响 ✓）。
 *
 * @param text           这一轮里**最后一条** assistant 文本 ✓
 * @param taskId         本任务 id ✓
 * @param allowedActions 允许的动作集合 ✓（含 'None' 与否都行；'None' 永远合法 ✓）
 */
export function validateAnswer(text: string, taskId: string, allowedActions: string[]): AnswerVerdict {
  if (typeof text !== 'string' || text.trim() === '') {
    return { ok: false, code: 'EMPTY_REPLY', message: '这一轮没有任何文本' }
  }

  const q = field(text, 'question')
  const rawAction = field(text, 'action')

  // ★ 人在环里是**特性** ✓，但绝不许实现成"悬着的 promise"✗ —— 这里只判"她在问" ✓，
  //   延期动作由 dispatch 层做 ✓（它会写清"投递会话在问主人：…"并**不派单** ✓）。
  if (rawAction === undefined && (q !== undefined && q !== ''
      || /[?？]\s*$/.test(text.trim()))) {
    return {
      ok: false,
      code: 'ASKED_OWNER',
      question: q !== undefined && q !== '' ? q : text.trim(),
    }
  }

  if (rawAction === undefined) {
    return {
      ok: false,
      code: 'NO_ACTION_LINE',
      // 与 index.ts 同一句话：把"她看到了什么"一起报出来，省得靠猜 ✓
      message: `reply has no action line (${text.length} chars)`,
    }
  }

  // ★★ 回显对不上 → **绝不采纳** ✗✓（她答的是别的船 / 别的任务 ✓）
  const echoedRaw = field(text, 'task')
  const echoed = echoedRaw !== undefined && echoedRaw !== ''
  if (echoed && echoedRaw !== taskId) {
    return {
      ok: false,
      code: 'TASK_MISMATCH',
      message: `回显的 task=${echoedRaw} 不是本任务 ${taskId} —— 绝不采纳 ✗`,
    }
  }

  const word = rawAction.replace(/[`*"'。，,]/g, '').trim()
  const action = word.toLowerCase() === 'none' ? 'None' : word
  if (action !== 'None' && !allowedActions.includes(action)) {
    return {
      ok: false,
      code: 'BAD_ACTION',
      message: `action ${action} 不在允许集合内（${allowedActions.join(', ')}，以及 None）`,
    }
  }

  const params: Record<string, unknown> = {}
  const goodName = field(text, 'goodName')
  if (goodName !== undefined && goodName !== '' && !NONE_WORDS.has(goodName.toLowerCase())) {
    params.goodName = goodName
  }
  const x = numField(text, 'x'); if (x !== undefined) params.x = x
  const y = numField(text, 'y'); if (y !== undefined) params.y = y
  // ★ Trade 的框形状：29x11 / 11x29 **不是正方形** ✗ → 两个边长分别取 ✓
  const shape = field(text, 'shape')
  if (shape !== undefined) {
    const m = /(\d+)\s*[x×*]\s*(\d+)/i.exec(shape)
    if (m !== null) { params.sizeX = Number(m[1]); params.sizeY = Number(m[2]) }
  }
  const sizeX = numField(text, 'sizeX'); if (sizeX !== undefined && sizeX > 0) params.sizeX = sizeX
  const sizeY = numField(text, 'sizeY'); if (sizeY !== undefined && sizeY > 0) params.sizeY = sizeY
  const size = numField(text, 'size'); if (size !== undefined && size > 0) params.size = size
  const deposit = numField(text, 'deposit'); if (deposit !== undefined && deposit > 0) params.deposit = deposit
  const duration = numField(text, 'duration'); if (duration !== undefined) params.duration = duration
  const safeMode = boolField(text, 'safeMode'); if (safeMode !== undefined) params.safeMode = safeMode
  // ★ Sell 的选货：`all` **不回传** ✗（游戏侧不给它就是"默认全卖" ✓ —— 与 index.ts 同款 ✓）
  const goods = field(text, 'goodsToSell')
  if (goods !== undefined && goods !== '' && !/^all$/i.test(goods) && goods !== '全部' && goods !== '全卖') {
    const list: Array<{ goodName: string; amount: number }> = []
    for (const part of goods.split(/[,，;；]/)) {
      const m = part.trim().match(/^(.+?)\s*[:：=]\s*(\d+(?:\.\d+)?)$/)
      if (m !== null) list.push({ goodName: m[1].trim(), amount: Number(m[2]) })
    }
    if (list.length > 0) params.goodsToSell = list
  }
  const escorts = listField(text, 'escorts')
  if (escorts.length > 0) params.escorts = escorts

  const reason = field(text, 'reason')
  return {
    ok: true,
    echoed,
    answer: { action, params, reason: reason !== undefined && reason !== '' ? reason : undefined, raw: text },
  }
}

/**
 * 造一个任务 id ✓（**只用于人眼对号** —— 不参与任何逻辑判断 ✓）。
 * 形如 `t-1a2b3c4d`：前缀可读、后缀 8 位随机 ✓（同一轮多艘船不会撞 ✓）。
 */
export function makeTaskId(rand: () => number = Math.random): string {
  const hex = '0123456789abcdef'
  let s = ''
  for (let i = 0; i < 8; i++) s += hex[Math.floor(rand() * 16) % 16]
  return `t-${s}`
}
