/**
 * task.ts —— 投递进指挥官会话的**任务块**，与它的**答案契约**（Phase A ✓）
 *
 * 这是「插件 ⇄ 会话」之间唯一的接口 ✗✓ —— 协议在这里、校验也在这里 ✓，
 * 这样"任务长什么样"和"什么算合格答案"永远不会各改各的 ✓（原型
 * `test/commander-dispatch-proto.mjs` 的 shape 原样搬过来 ✓）。
 *
 * ## 为什么答案里必须回显 `task=<id>`（**这条不能省**）
 *
 * 指挥官会话是**一条活着的、主人也在用的普通会话** ✓✓。所以同一轮里可能出现：
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
 * 事实仍由插件**预取**（见 AGENT-DESIGN.md §2.2：让会话反复查 `minePlan` 会反复占住
 * 游戏主循环 ✗）；会话想自己核实可以用 `fleet_query` ✓。
 */
export interface TaskRequest {
  /** 任务 id：回显契约的锚点 ✓（形如 `t-1a2b3c4d`） */
  taskId: string
  ship: string
  goalText: string
  goalOptions: string[]
  /** 能力卡（原样 JSON ✓） */
  card: unknown
  /** 给模型看的计划文本（与单发路径同一份 ✓）；可缺省 ✓ */
  planText?: string
  /** 建议预算（秒）；写进任务头，让她知道"别慢慢查" ✓ */
  deadlineHintSec: number
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

/** 船名清单字段（`Miner-1, Miner-2`；"无" 之类的词丢掉 ✓ —— 与 index.ts 同款 ✓） */
function listField(text: string, key: string): string[] {
  const raw = field(text, key)
  if (raw === undefined) return []
  return raw.split(/[,，、]/).map((s) => s.trim())
    .filter((s) => s !== '' && !NONE_WORDS.has(s.toLowerCase()))
}

/**
 * 渲染任务块 ✓ —— **与单发路径的 `buildPrompt()` 同源**（同一批事实、同一套读法 ✓）。
 *
 * 为什么结论行要求**放最前** ✗✓：`plugin/prompt/system.md` 与
 * `src/index.ts` 的重试路径都记录了实机事故 ——「她想太久、正文被 maxTokens 截断，
 * 一个动作行都没吐」✓。把契约放最前，最坏情况丢的是散文，不是结论 ✓。
 */
export function renderTaskBlock(req: TaskRequest): string {
  const L: string[] = []
  L.push(`<fleet_task id="${req.taskId}" ship="${req.ship}" deadline_hint="${req.deadlineHintSec}s">`)
  L.push('这是舰队运营的一个决策请求（不是闲聊）。你可以先调用工具自己查证，再给结论。')
  L.push('')
  L.push(`船：${req.ship}`)
  L.push('玩家给这艘船设定的运营目标：')
  L.push(req.goalText !== '' ? req.goalText : '(玩家没有写文字目标，只给了下面的动作边界)')
  L.push('')
  L.push('允许的动作：')
  L.push(req.goalOptions.length > 0
    ? req.goalOptions.join(', ')
    : '(玩家没有限制 —— 你可以从 Mine / Salvage / Trade / Sell / Travel / Scout 里选)')
  L.push('')
  L.push('这艘船的现状（能力卡）：')
  L.push(JSON.stringify(req.card ?? {}, null, 2))
  L.push('')
  if (req.planText !== undefined && req.planText !== '') {
    L.push('游戏侧算好的计划（reference，不是必须照抄 ✓）：')
    L.push(req.planText)
    L.push('')
  }
  L.push('★ 请**先**给出结论行（**第一行就写 action=**），再写理由；理由写进 reason= 或写在后面都行 ✓。')
  L.push('★ 结论里**必须回显** task=' + req.taskId + '（这样即使你同一轮里还答了别的船，也能对上号 ✓）。')
  L.push('★ 如果你需要主人拍板（例如"要不要先派护航"），就**直接问他** ✓ ——')
  L.push('  不写 action 行、把问题写出来即可 ✓；本轮会明确记为"等主人裁决"，**不会**替你编一个动作 ✗。')
  L.push('')
  L.push('action=<动作>')
  L.push('task=' + req.taskId)
  L.push('x=<框心 x>  y=<框心 y>  size=<边长>  duration=<小时>  reason=<一句话>')
  L.push('</fleet_task>')
  return L.join('\n')
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
  //   延期动作由 dispatch 层做 ✓（它会写清"指挥官在问主人：…"并**不派单** ✓）。
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
