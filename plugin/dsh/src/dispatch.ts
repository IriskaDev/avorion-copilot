/**
 * dispatch.ts —— 「把决策任务投递给主人正在用的那个会话」的**阶梯**与**硬期限**（Phase A/B ✓）
 *
 * 设计书：`AGENT-DESIGN.md` §2.2/§3.4；离线原型：`test/commander-dispatch-proto.mjs`（7/7 ✓）。
 * 本文件是原型的**生产版**：把桩换成真依赖（`ctx.agents` / `ctx.on('session/event')`），
 * 把原型抓到的两个坑**原样避开** ✓✓：
 *
 *   1. **`whenIdle()` 的解析值就是 `undefined`** ✗（原型第一版 7 项挂 2 项的真凶 ✓）——
 *      所以"跑完了"和"超时了"**必须显式区分** ✓：本文件的 `settled` 结果是
 *      `{settled:true}` / `{settled:false}`，**绝不**用返回值判 ✓✓。
 *   2. **失败绝不重投** ✗（同一艘船同一轮只投一次 ✓ —— 重投会让同一艘船收到两条矛盾命令，
 *      正是 TAKEOVER.md 那条铁律要防的 ✗✓）。
 *
 * ## 三级阶梯（**永不卡住舰队** ✓）
 *
 * ```
 * ① 投递目标会话（若主人指定且活着）
 *    ★★ A（2026-10-18）：先进**合并队列**（`pumpRungQueue` ✓）—— 等 mergeWindowMs 把同一批收齐，
 *       1 条 → 老的单船路径（逐字不变 ✓）；N 条 → **一个块** + 一次投递 + 多组答案解析 ✓✓
 *       （病根：多艘船同时空闲时各投一个块 ✗，而一轮只答得了一个 → 其余的静默 None ✗）
 *      空闲          → followup(任务块) → 等这一轮结束 → 校验 → 采纳 ✓
 *      忙（主人在聊天）→ steerWhenBusy=false（默认）→ 不插队 → 下①.9 ✓
 *      超时          → cancel({kind:'hook'}) → 下①.9 ✓
 *      答不上来/答错船 → 下①'（若允许重试一次，**同一批事实**、只要求答案行 ✓）→ 下①.9 ✓
 *      在问主人       → **显式延期**（ASKED_OWNER：不派单、写清原因 ✓）—— 不是失败 ✓
 *      没答到这艘船   → `UNANSWERED`（★ 合并块的常见情形 ✓）→ 下①.9 ✓，并由 index.ts 的
 *                       B 项**短间隔重投** ✓（绝不 20 分钟静默 ✗）
 * ①.9 ★★ 兜底不许下单（live 模式）：会话**在线**却没答成 → 直接 None（fallbackNone）✓
 *       （只有「没有指挥官」或「会话明确离线/不在 registry」才允许下②单发 ✗）
 * ② 今天的单发事实调用（**保留**：没有指挥官 / 会话离线时才走 ★ 有**硬期限** ✓）
 * ③ 都没有 → action=None + 原因写清 ✓
 * ```
 *
 * ## 两种模式（**Phase A 与 B 的差别只在这里** ✓）
 *
 * | 模式 | 会话级的答案 | 谁真的决定了这一单 |
 * |---|---|---|
 * | `live`   | **采纳** ✓（校验通过就直接下单 ✓） | 会话（否则单发 ✓） |
 * | `shadow` | **只并排记下来** ✗✓（**零风险** ✓ —— 不改任何实际下单行为 ✓） | **永远是单发** ✓ |
 *
 * `shadow` 就是设计书推荐的"最重要的第一步" ✓：主人能提前看到她会怎么答、
 * 能对比"会话答案 vs 单发答案"、能测延迟与成本，而**实际下单一个字节都没变** ✓✓。
 *
 * ★ 舰队级串行（设计书 §3.4）：一个会话同一时刻**只能有一个 turn** ✓。
 *   所以用一个跨决策共享的 `lock`：取不到就**根本不投递** ✗ → 直接下② ✓
 *   （不排队、不等待 ✓ —— 排队等 20 秒只会让游戏侧的 decide 白等 ✓，而单发本来就是对的答案 ✓）。
 */

import type { AnswerGroupSpec, TaskAnswer, TaskRequest } from './task.js'
import { field, makeTaskId, renderTaskBatchBlock, renderTaskBlock, validateAnswer, validateAnswers } from './task.js'

// ---------------------------------------------------------------------------
// 时间预算（设计书 §3.4 的建议值 ✓）
// ---------------------------------------------------------------------------

export interface Budgets {
  /** 等投递目标会话的**硬闸**：超了就 `cancel()` 并放弃这一级 ✓ */
  sessionDeadlineMs: number
  /** 剩余预算不够这个数，就**不要开始投递** ✓（避免"刚投完就超时" ✓） */
  queueReserveMs: number
  /** 拿到答案后还要校验 + 发 order RPC，留一点余量 ✓ */
  commitReserveMs: number
  /** ★ 单发路径的**硬期限**（今天完全没有 ✗ —— 设计书点名的薄弱点 ✓） */
  singleShotTimeoutMs: number
  /** 会话第一次答不上来时，允许**再**投一次（同一批事实、只要求答案行 ✓）；0 = 不许重试 ✓ */
  retryOnceMs: number
  /**
   * ★★ A：**合并收集窗口**（毫秒 ✓，2026-10-18）。
   *
   * 游戏侧是**每艘船一条 decide**（`data/scripts/net/fleet.lua:119` ✓），
   * 同一个扫描里同时空闲的船会在**同一瞬间**各发一条 ✓。所以先等这么一小会儿
   * 把同一批的决定收进**一个块** ✓，再投递一次（否则就是"各投一个、她只答得了一个" ✗✓）。
   * `0` = 不合并（逐条投 ✓ —— 测试与旧行为都用它 ✓）。
   */
  mergeWindowMs: number
}

export const BUDGETS: Budgets = {
  sessionDeadlineMs: 20_000,
  queueReserveMs: 3_000,
  commitReserveMs: 1_000,
  singleShotTimeoutMs: 15_000,
  retryOnceMs: 8_000,
  mergeWindowMs: 800,
}

// ---------------------------------------------------------------------------
// 依赖（全部注入 → 可以完全离线测试 ✓✓）
// ---------------------------------------------------------------------------

/** 会话事件的**最小**结构（真事件比这富 ✓；我们只读这两个字段 ✓） */
export interface SessionEventLike {
  type: string
  turn?: number
  step?: number
  reason?: { kind?: string }
  message?: { role?: string; content?: Array<{ type?: string; text?: string }> }
  usage?: unknown
}

/**
 * 一个**活着的** Agent 的**最小**面（真面见 `dsh-agent/lib/types/runtime-types.d.ts` ✓）。
 * ★ 只声明我们真的用的方法 ✓（`status` / `followup` / `whenIdle` / `cancel` ✓），
 *   这样测试桩只需要实现这几个 ✓，而真 Agent 天然满足 ✓（结构类型 ✓）。
 */
export interface AgentLike {
  id?: string
  /** 'idle' | 'running' */
  status?: string
  followup(message: unknown): void
  whenIdle(): Promise<void>
  cancel(cause: unknown, options?: unknown): void
}

/** `ctx.agents` 的最小面 ✓ */
export interface RegistryLike {
  get(id: string): AgentLike | undefined
  list(): AgentLike[]
}

/** 订阅某个会话的事件；返回退订函数 ✓ */
export type Subscribe = (sessionId: string, fn: (event: SessionEventLike) => void) => () => void

/** 单发路径的一次调用（真实现 = `ctx.llm.stream` + 今天的解析/重试 ✓） */
export interface SingleShotResult {
  text: string
  failure?: string
  truncated?: boolean
  /** 'first' | 'retry' —— 让流水能说清"这是重试那次" ✓ */
  attempt?: string
  /**
   * ★★ 调用方要求**再问一次**（2026-10-17 修 ✓✓）。
   *
   * 为什么必须是它 ✗：单发那一级"该不该重试"只有**调用方**知道 ✓ ——
   *   提示词、事实、解析器都在 index.ts 里 ✓，dispatch 只看得到一段文本 ✓。
   *   原来的实现是 dispatch 自己拿正则找 `action=` ✓，可**"没有动作行"必须由真解析器判** ✓
   *   （`parseDecision` 容忍 `choice=`/加粗/全角冒号 ✓，一个正则判不准 ✗）。
   *   → 于是真正该重试的那种回复**永远重试不了** ✓（order-payload 的 g 用例就是这个 ✓）。
   * ★ 今天它是**必填**的：类型上漏了它 = 静默丢掉整条重试路径 ✗✓（这次就是这么被抓到的 ✓）。
   */
  retryHint?: string
}

/** 阶梯的结论来源（**进 DecisionRecord.source ✓**） */
export type DecisionSource =
  | 'session'        // 会话（本轮的投递目标）定的 ✓
  | 'single-shot'    // 单发定的 ✓
  | 'shadow'         // ★ 影子模式：会话答了、但采纳的是单发 ✓
  | 'asked-owner'    // 显式延期：投递会话在问主人 ✓
  | 'rendezvous'     // ★ 单发预取阶段直接定下（护航 rendezvous 派了 Travel ✓）
  | 'fallbackNone'   // ★★ 指挥官会话在线但本轮没答成 → 兜底 = None（**不许单发替它拍板** ✓）
  | 'none'           // 都没有 → action=None ✓

/** 会话这一级的结果（**影子模式也要报出来** ✓ —— 主人要看她答了什么 ✓） */
export interface SessionAttempt {
  /** 会话到底有没有给出可用答案 ✓ */
  answered: boolean
  /** 会话的答案（答了才有 ✓） */
  answer?: TaskAnswer
  /** 没用上/没用成的**原因码** ✓（TASK_MISMATCH / TIMEOUT / …） */
  code?: string
  message?: string
  /** 她问主人的问题（ASKED_OWNER ✓） */
  question?: string
  /** 这一轮她吐了几条 assistant 文本 ✓（>1 说明她用了工具 ✓） */
  steps: number
  /** 从投递到结束的真实耗时（ms ✓ —— 成本/延迟**实测**就靠它 ✓） */
  tookMs: number
  /** token 用量（事件带就给 ✓，没有就 undefined ✓ —— **不假造** ✗） */
  usage?: unknown
  /** 会话答案的原文（审计 ✓） */
  raw?: string
  /**
   * ★★ 这一轮**合并投递**里一共塞了几艘船 ✓（2026-10-18）。
   *   `1` = 单船（与以前逐字相同 ✓）；`>1` = 一个块里 N 艘 ✓（这是"合并"的**证据** ✓）。
   */
  batchSize?: number
}

export interface DispatchDeps {
  registry: RegistryLike
  /** 投递目标会话 id；undefined = 没指定 ✓（阶梯直接从②开始 ✓） */
  commanderId?: string
  /** 订阅会话事件（真实现 = `ctx.on('session/event', …)` 再按 sessionId 筛 ✓） */
  subscribe?: Subscribe
  /** 单发路径（**必给** ✓ —— 没有它阶梯就没有第二级 ✓）。`hint` 非空 = 那次"只要答案行"的重试 ✓ */
  singleShot: (hint?: string) => Promise<SingleShotResult>
  /**
   * ★ 单发路径的**重数据预取**（2026-10-17：会话路径不再预取计划 ✓✓）。
   *   它在阶梯①（会话）之后、阶梯②（单发）之前跑一次，**不受** singleShotTimeoutMs 限制
   *   （计划查询在游戏主线程同步算，tradePlan 实测 20s+ ✓）。返回非 null = 预取期间
   *   **已经定了这一单**（例如护航 rendezvous 派了 Travel ✓）→ 直接采纳并跳过单发模型 ✓。
   */
  prefetch?: () => Promise<PrefetchDecision | null>
  /**
   * ★ 真正把任务块**投进会话** ✓（真实现 = `agent.followup(createUserMessage({...}))` ✓）。
   *   单列成一个注入点，是为了让本模块**不 import `dsh-llm`** ✓ ——
   *   于是整个阶梯可以在 Node 里**完全离线**测（`test/commander-dispatch.mjs` ✓✓）。
   */
  followup: (agent: AgentLike, block: string, req: TaskRequest) => void
  /** 每艘船此刻允许的动作 ✓（校验用 ✓）—— ★ 但它是**投递时**的快照 ✗（见 `allowedActionsFor` ✓） */
  allowedActions: string[]
  /**
   * ★★ 2026-10-20 真机丢单的修：**校验前当场重查**这艘船的动作边界 ✓✓。
   *
   * 病根（`decisions.live.log` 2026-10-20 14:32:19 逐字 ✓）：
   *   `[session] ✘ 校验没过：BAD_ACTION（action Mine 不在允许集合内（Travel, Sell, Scout，以及 None））`
   *   —— 船刚加载完、**炮塔还没恢复**时取的 `facts.goalOptions` 快照 = [Travel, Sell, Scout] ✗；
   *   十几秒后她答 `action=Mine`（那时 `fleet_query{what:'ship'}` 已显示 Mining:4 ✓）→
   *   被**过期快照**当非法动作**整组丢掉** → `fallbackNone` → 船空转 ✗✗。
   *
   * → 校验**以当前事实为准** ✓；块里的清单只当提示 ✓。
   *   返回 `undefined`（或空数组）= 拿不到当前事实 → **退回快照** ✓（绝不因为查不到就丢单 ✗）。
   */
  allowedActionsFor?: (ship: string) => Promise<string[] | undefined>
  /** 'live' = 会话答案算数 ✓；'shadow' = 只观察、单发算数 ✓（默认 'live' ✓） */
  mode?: 'live' | 'shadow'
  /** 忙会话要不要插队（默认 **false** ✓ —— 设计书：不插队，直接落单发 ✓） */
  steerWhenBusy?: boolean
  /** 舰队级串行：取不到就直接下② ✓（**不排队** ✗ —— 见文件头注释 ✓） */
  lock?: { tryClaim(): (() => void) | undefined }
  /** 会话那一级**答不上来时**要不要再投一次（同一批事实、只要求答案行 ✓）；默认 false = 只投一次 ✓ */
  retrySessionOnce?: boolean
  /** ★ 单发那一级**没有动作行**时要不要重试一次（与今天 index.ts 的重试同源 ✓）；默认 true ✓ */
  retrySingleShotOnce?: boolean
  budgets?: Partial<Budgets>
  log?: (line: string) => void
  /** 收答案时的**旁路**：每收到一条 assistant 文本就回调一次 ✓（主人能边看边说 ✓） */
  onAssistantText?: (step: number, text: string) => void
}

/** 阶梯的完整结论 ✓ */
export interface DispatchOutcome {
  /** 最终要执行的动作（'None' = 不下单 ✓） */
  action: string
  params: Record<string, unknown>
  reason?: string
  /** ★ 这一单是**谁**定的 ✓（进 DecisionRecord.source ✓） */
  source: DecisionSource
  /** 单发那一路的原文（审计/落盘 ✓） */
  text?: string
  truncated?: boolean
  /** 会话那一路的观察结果（影子模式也有 ✓） */
  session?: SessionAttempt
  /** 会话答案 vs 单发答案**是否一致**（影子模式下最有用的一个数 ✓；会话没答 = undefined ✓） */
  agreement?: boolean
}

/**
 * ★ 单发预取阶段**直接定下**的一单（2026-10-17 ✓）：
 *   例如护航 rendezvous —— 预取时发现缺护航、本星系又没有候选，就派一艘 Travel 过去、
 *   本轮 action=None（**不跑模型** ✓）。它跳过单发模型调用，但**不**跳过记录/审计 ✓。
 */
export interface PrefetchDecision {
  action: string
  params: Record<string, unknown>
  reason?: string
}

const nowMs = (): number => Date.now()

/** 合并默认预算与调用方覆盖 ✓（一处算法，三处用 ✓） */
function budgetOf(override?: Partial<Budgets>): Budgets {
  return { ...BUDGETS, ...(override ?? {}) }
}

// ---------------------------------------------------------------------------
// ★★ 校验用的动作边界：**当场重查**（2026-10-20 ✓）
//
// 真机事故（`decisions.live.log` 2026-10-20 14:32:19 ✓）：
//   投递块里印的可选动作 = [Travel, Sell, Scout] ✗（船刚加载完、炮塔还没恢复时取的快照）；
//   十几秒后她答 `action=Mine`（那时船卡已经是 Mining:4 ✓）→
//   校验拿**快照**当白名单 → `BAD_ACTION` → 整组丢掉 → `fallbackNone` → 船空转 ✗✗，
//   而同一时刻用 `fleet_order` 直下**一次就成** ✓（说明她答的动作是对的 ✓）。
//
// 治法（主人指定的首选 ✓）：校验以**当前事实**为准 ——
//   · 有 `allowedActionsFor` 且查到了 → 用它 ✓（并把她看到过的那份快照记下来 ✓）；
//   · 查不到 / 抛错 / 空 → 退回投递时快照 ✓（**绝不**因为查不到就丢单 ✗）。
// ---------------------------------------------------------------------------

/** 两组动作是否**同集合**（顺序无关 ✓；比较用，不影响行为 ✓） */
function sameActionSet(a: string[], b: string[]): boolean {
  if (a.length !== b.length) return false
  const sa = [...a].sort()
  const sb = [...b].sort()
  return sa.every((v, i) => v === sb[i])
}

/**
 * 校验前解析出**这一刻**的动作边界 ✓。
 * 返回值带上 `fresh`（是不是当场查到的 ✓）与 `snapshot`/`freshList`，好让拒绝理由能原样写清楚 ✓。
 */
async function allowListFor(
  deps: DispatchDeps,
  ship: string | undefined,
  snapshot: string[],
  say: (line: string) => void,
): Promise<{ actions: string[]; fresh: boolean }> {
  const name = typeof ship === 'string' ? ship : ''
  const refresh = deps.allowedActionsFor
  if (name === '' || typeof refresh !== 'function') return { actions: snapshot, fresh: false }
  try {
    const live = await refresh(name)
    if (Array.isArray(live) && live.length > 0) {
      const fresh = live.filter((a): a is string => typeof a === 'string' && a !== '')
      if (fresh.length === 0) return { actions: snapshot, fresh: false }
      if (!sameActionSet(fresh, snapshot)) {
        // ★ 这条就是"块里的清单过期了"的**证据** ✓（进 decisions.live.log ✓）
        say(`  [session] 动作边界当场重查：${name} 投递时 [${snapshot.join(',')}] → 当前 [${fresh.join(',')}]（**以当前为准** ✓）`)
      }
      return { actions: fresh, fresh: true }
    }
    say(`  [session] 动作边界当场重查没拿到（${name}）→ 退回投递时快照 [${snapshot.join(',')}] ✓`)
    return { actions: snapshot, fresh: false }
  } catch (error) {
    say(`  [session] 动作边界当场重查异常（${name}：${String(error)}）→ 退回投递时快照 [${snapshot.join(',')}] ✓`)
    return { actions: snapshot, fresh: false }
  }
}

/**
 * ★ 原型抓到的坑 ①：`whenIdle()` **没有返回值** ✗ → "跑完了"与"超时了"必须**显式区分** ✓。
 * 返回 `{settled:true, value?}` / `{settled:false}`；**绝不**用 `value === undefined` 判超时 ✗✓。
 */
export function withTimeout<T>(
  promise: Promise<T>,
  ms: number,
): Promise<{ settled: boolean; value?: T; error?: unknown }> {
  return new Promise((resolve) => {
    let done = false
    const timer = setTimeout(() => {
      if (done) return
      done = true
      resolve({ settled: false })
    }, Math.max(0, ms))
    promise.then(
      (value) => { if (!done) { done = true; clearTimeout(timer); resolve({ settled: true, value }) } },
      (error) => { if (!done) { done = true; clearTimeout(timer); resolve({ settled: false, error }) } },
    )
  })
}

/** 两个答案的"实质是否一致"（只比 action + 关键参数 ✓ —— 不比理由文字 ✗） */
function sameDecision(a: TaskAnswer | undefined, b: { action: string; params: Record<string, unknown> } | undefined): boolean | undefined {
  if (a === undefined || b === undefined) return undefined
  if (a.action !== b.action) return false
  const keys = new Set([...Object.keys(a.params), ...Object.keys(b.params)])
  for (const k of keys) {
    const x = a.params[k]
    const y = b.params[k]
    if (typeof x === 'number' && typeof y === 'number') {
      if (Math.abs(x - y) > 1e-6) return false
      continue
    }
    if (JSON.stringify(x) !== JSON.stringify(y)) return false
  }
  return true
}

/**
 * ★★ 主入口：为**一艘船**要一个决策 ✓。
 *
 * 保证（都在测试里断言过 ✓）：
 *   · **永不抛** ✓（任何异常都变成"下一级"或 `action=None` ✓）
 *   · **永不超总预算** ✓（会话硬闸 + 单发硬闸，各自独立 ✓）
 *   · 忙/挂死/在聊天的会话，**绝不会**让这一轮没有决策 ✓
 */
export async function dispatchDecision(deps: DispatchDeps, req: TaskRequest): Promise<DispatchOutcome> {
  const B: Budgets = budgetOf(deps.budgets)
  const say = deps.log ?? ((): void => {})
  const mode = deps.mode ?? 'live'
  const started = nowMs()
  const elapsed = (): number => nowMs() - started

  let sessionAttempt: SessionAttempt | undefined

  // ---- 阶梯①：投递目标会话 --------------------------------------------------
  const agent = deps.commanderId !== undefined ? deps.registry.get(deps.commanderId) : undefined
  if (deps.commanderId !== undefined && agent === undefined) {
    say(`  [ladder] 投递目标会话 ${deps.commanderId} **不在了** ✗（已关/已换）→ 下②单发 ✓`)
  }
  if (agent !== undefined) {
    const remaining = B.sessionDeadlineMs - elapsed()
    if (agent.status !== 'idle') {
      // 主人在聊天 / 这一轮在做别的事 ✓ —— 设计书的默认是**不插队** ✓（插队会把任务块插到
      // 别人的上下文里，正是"猜会话"那类风险的同源 ✓）。
      say(`  [ladder] 投递会话**正忙**（主人在聊 / 在别的任务上）`)
      if (deps.steerWhenBusy !== true) {
        say('  [ladder] steerWhenBusy=false（默认）→ 不插队，直接下②单发 ✓')
      } else if (remaining < B.queueReserveMs) {
        say(`  [ladder] 只剩 ${remaining}ms（< 保留 ${B.queueReserveMs}ms）→ 不投递，直接下②单发 ✓`)
      } else {
        // ★ A（2026-10-18）：**不直接投**，先进「合并收集窗口」✓
        sessionAttempt = await askSessionRung(deps, req, Math.max(0, remaining - B.commitReserveMs))
      }
    } else if (remaining < B.queueReserveMs) {
      say(`  [ladder] 剩余预算 ${remaining}ms < 保留 ${B.queueReserveMs}ms → 不投递，直接下②单发 ✓`)
    } else {
      sessionAttempt = await askSessionRung(deps, req, Math.max(0, remaining - B.commitReserveMs))
    }
  } else if (deps.commanderId === undefined) {
    say('  [ladder] 没有指定投递目标会话 → 直接走②单发（**与今天逐字相同** ✓）')
  }

  // 会话那一路的结论先落进结果里 ✓（影子模式也照样带着走 ✓）
  if (sessionAttempt !== undefined && mode === 'live') {
    if (sessionAttempt.answered && sessionAttempt.answer !== undefined) {
      say(`  [commit] 采用**投递目标会话**的答案：${sessionAttempt.answer.action} ${JSON.stringify(sessionAttempt.answer.params)}` +
        `（${sessionAttempt.steps} 步 / ${sessionAttempt.tookMs}ms ✓）`)
      return {
        action: sessionAttempt.answer.action,
        params: sessionAttempt.answer.params,
        reason: sessionAttempt.answer.reason,
        source: 'session',
        session: sessionAttempt,
      }
    }
    if (sessionAttempt.code === 'ASKED_OWNER') {
      // ★ 人在环里 = **显式延期** ✓（绝不是悬着的 promise ✗）
      const q = String(sessionAttempt.question ?? '').slice(0, 300)
      say(`  [commit] 投递会话**在问主人** ✓：${JSON.stringify(q.slice(0, 160))}`)
      say('  [commit] → 本轮**明确延期**（不派单 ✓）；主人回答后，下一轮投递自然带上新信息 ✓')
      return {
        action: 'None',
        params: {},
        reason: `投递会话在问主人：${q}（本轮明确延期，未派单 ✓）`,
        source: 'asked-owner',
        session: sessionAttempt,
      }
    }
    say(`  [ladder] 会话那一级没成：${sessionAttempt.code ?? '?'}（${sessionAttempt.message ?? ''}）`)
  }

  // ---- 阶梯①.9：★★ 兜底不许下单（2026-10-17 主人铁律）--------------------
  //   当投递目标会话**已指定且在线**（`agent` 还在 registry ✓）而这一轮它没给出可用
  //   答案（忙 / 超时 / 答错船 / 无动作行 / 锁被占 …）→ 本轮**绝不**让单发模型替它拍板 ✗
  //   → 直接 None（fallbackNone）。
  //
  //   ★ 判定"慢"与"不在"（这是唯一的判据，代码里就这一处 ✓）：
  //     · `deps.commanderId === undefined`          → **没有指挥官** → 允许单发 ✓；
  //     · `agent === undefined`（registry 里取不到） → 会话**明确离线/已关/不可用** → 允许单发 ✓；
  //     · 其余（agent 在、但忙/超时/没答成）          → **在线但慢** → 兜底 = None ✗（不许单发 ✓）。
  //   ★ shadow 模式不在这里 ✗：影子模式里单发**本来就是**决策者（会话只观测 ✓），
  //     不是"兜底替它拍板"，所以不受这条铁律约束 ✓（见下面阶梯②）。
  if (mode === 'live' && deps.commanderId !== undefined && agent !== undefined) {
    const why = sessionAttempt !== undefined
      ? (sessionAttempt.code ?? 'NO_ANSWER')
      : 'SESSION_BUSY'
    say(`  [ladder] ★ 指挥官会话在线但本轮没答成（${why}）→ 兜底 = None（fallbackNone），` +
      '**不许单发替它拍板** ✗')
    return {
      action: 'None',
      params: {},
      reason: `投递目标会话在线，但本轮没给出可用答案（${why}）—— 按主人规矩本轮**不下单**、` +
        '也不让单发模型替它决策 ✗；下一轮（状态变化或冷却到期）会再次征询',
      source: 'fallbackNone',
      session: sessionAttempt,
    }
  }

  // ---- 阶梯②：今天的单发事实调用（★ 现在有硬期限 ✓）-----------------------
  if (sessionAttempt !== undefined && mode === 'shadow') {
    if (sessionAttempt.answered && sessionAttempt.answer !== undefined) {
      say(`  [shadow] 投递目标会话答了：${sessionAttempt.answer.action} ${JSON.stringify(sessionAttempt.answer.params)}` +
        `（${sessionAttempt.steps} 步 / ${sessionAttempt.tookMs}ms ✓）—— ★ **本轮不采纳** ✓，仍由单发决定 ✓`)
    } else {
      say(`  [shadow] 投递目标会话没答成：${sessionAttempt.code ?? '?'}（${sessionAttempt.message ?? ''}）✓`)
    }
  }
  // ---- 阶梯①.5：单发路径的重数据预取（会话路径不预取 ✓）------------------
  //   ★ 2026-10-17：会话路径投递前只取 goal（毫秒级 ✓）—— 船卡/舰队/计划/记忆/rendezvous
  //     全在这里**惰性**预取，只在真正要跑单发时（没有会话 / 会话没答成 / 影子模式兜底）才跑 ✓。
  //   ★ 它**不受** singleShotTimeoutMs 限制（计划查询在游戏主线程同步算，tradePlan 20s+ ✓）。
  if (deps.prefetch !== undefined) {
    let early: PrefetchDecision | null = null
    try {
      early = await deps.prefetch()
    } catch (error) {
      say(`  [prefetch] 预取异常（${String(error)}）→ 继续走单发，档案可能缺计划 ✓`)
    }
    if (early !== null) {
      say(`  [prefetch] 预取期间已定这一单：${early.action}（${early.reason ?? ''}）→ 跳过单发模型调用 ✓`)
      return {
        action: early.action,
        params: early.params,
        reason: early.reason,
        source: 'rendezvous',
        session: sessionAttempt,
      }
    }
  }
  say(`  [ladder] → ② 单发模型调用（今天那条路 ✓；硬期限 ${B.singleShotTimeoutMs}ms ✓）`)

  const single = await runSingleShot(deps, B.retryOnceMs, say)
  if (!single.ok || single.action === undefined) {
    say(`  [ladder] 单发也没成：${single.why ?? 'unknown'} → ③ action=None ✓`)
    return {
      action: 'None',
      params: {},
      reason: `没有可用的决策（投递会话未指定/未答成；单发：${single.why ?? 'unknown'}）`,
      source: 'none',
      session: sessionAttempt,
    }
  }

  const sessionAnswer = sessionAttempt?.answer
  const agreement = sameDecision(sessionAnswer, { action: single.action, params: single.params })
  const viaSession = sessionAttempt?.answered === true
  return {
    action: single.action,
    params: single.params,
    reason: single.reason,
    // ★ 影子模式：会话答了**也不算它决定的** ✗ —— 这一单是单发定的 ✓（source 说真话 ✓）
    source: mode === 'shadow' && viaSession ? 'shadow' : 'single-shot',
    text: single.text,
    truncated: single.truncated,
    session: sessionAttempt,
    agreement,
  }
}

// ---------------------------------------------------------------------------
// 阶梯②的内部：单发 + 硬期限 + 一次"只要答案行"的重试
// ---------------------------------------------------------------------------

interface SingleShotOutcome {
  /** ★ 只有**真的拿到了可用答案**才是 true ✓（绝不靠 `text === undefined` 判成败 ✗——
   *  空字符串是"她一句话都没说"，是**失败** ✓，可它并不是 undefined ✓✓） */
  ok: boolean
  text?: string
  action?: string
  params: Record<string, unknown>
  reason?: string
  truncated?: boolean
  why?: string
}

/**
 * 跑单发路径，**带硬期限** ✓。
 *
 * ★ 为什么期限是"不管它了"而不是"掐掉" ✗：`ctx.llm.stream` 没有取消参数 ✗
 *   （今天就没法掐 ✓）。所以超时后我们**不再等它**、直接返回 ✓ —— 那条流会自己在后台
 *   收完（最多多跑一轮输出 ✓），但这**不影响舰队** ✓✓。
 *
 * ★ 重试一次（可选）：与今天 `index.ts` 里的重试同源 ✓ —— 同一批事实、只要求答案行、
 *   **只此一次** ✓、不重取数据 ✓。`hint` 交给调用方拼进提示词 ✓。
 */
async function runSingleShot(
  deps: DispatchDeps,
  retryBudgetMs: number,
  say: (l: string) => void,
): Promise<SingleShotOutcome> {
  const B: Budgets = budgetOf(deps.budgets)
  const attempt = async (hint?: string): Promise<{ settled: boolean; value?: SingleShotResult; error?: unknown }> =>
    withTimeout(deps.singleShot(hint), B.singleShotTimeoutMs)

  let first: { settled: boolean; value?: SingleShotResult; error?: unknown }
  try {
    first = await attempt()
  } catch (error) {
    return { ok: false, params: {}, why: `调用抛异常：${String(error)}` }
  }
  if (!first.settled) {
    return { ok: false, params: {}, why: `超过硬期限 ${B.singleShotTimeoutMs}ms 没返回（★ 今天没有这道闸 ✗）` }
  }
  if (first.value === undefined) {
    return { ok: false, params: {}, why: `调用抛异常：${String(first.error)}` }
  }
  if (first.value.failure !== undefined) {
    return { ok: false, params: {}, why: `模型失败 ${first.value.failure}` }
  }

  const parsed = parseSingleShotText(first.value.text)
  if (parsed.action !== undefined) {
    return { ok: true, ...parsed, text: first.value.text, truncated: first.value.truncated }
  }

  // ---- 只有"完全没有动作行"才重试 ✓（其它问题重试也救不回来 ✗）------------
  //   ★ 默认**允许**（= 今天 index.ts 里那条重试 ✓ —— 实机事故：正文一个动作行都没吐 ✓）；
  //     传 retrySingleShotOnce:false 可关掉 ✓。
  const allowed = deps.retrySingleShotOnce !== false
  const canRetry = allowed && retryBudgetMs > 0 && parsed.why === 'no action line'
  if (!canRetry) {
    return { ok: false, params: {}, why: parsed.why ?? '解析不出动作', text: first.value.text }
  }
  say('  [ladder] 单发首轮没有动作行 → 重试一次（同一批事实、**只要求答案行** ✓、只此一次 ✗）')
  const second = await attempt(
    '★ 你上一次没有输出任何 action 行 ✗。现在**只输出答案行** ✓：action 必须在**第一行** ✓；' +
    '不要写任何推理或解释 ✗；reason 可以留空 ✓。一行一个字段，从 action= 开始。',
  )
  if (!second.settled || second.value === undefined || second.value.failure !== undefined) {
    return {
      ok: false, params: {},
      why: `重试也没成（${!second.settled ? '超时' : String(second.value?.failure ?? second.error)}）`,
      text: first.value.text,
    }
  }
  const again = parseSingleShotText(second.value.text)
  if (again.action === undefined) {
    return { ok: false, params: {}, why: `重试后仍解析不出（${again.why ?? '?'}）`, text: second.value.text }
  }
  say('  [ladder] ✔ 单发重试成功（拿到动作行 ✓）')
  return { ok: true, ...again, text: second.value.text, truncated: second.value.truncated }
}

/**
 * 单发回复的**极小**解析：`action=` 那一行 + 那几个**跨路径共用**的字段 ✓。
 *
 * ★ 分工（避免两份规则漂移 ✗✓ —— 本仓库反复吃过这个亏）：
 *   · **合法性**（动作在不在允许集合内、escort 候选过滤、goodsToSell 形状…）仍由**今天那套**
 *     `parseDecision`/`toAnswer` 判 ✓（调用方在拿到 `text` 之后照样跑它 ✓）。
 *   · 这里只把**两边都要看得懂**的那几个字段取出来 ✓（`x/y/shape/size/sizeX/sizeY/deposit/
 *     duration/safeMode/goodName` ✓），好让"会话答案 vs 单发答案并排比较"（`agreement` ✓）
 *     与 DecisionRecord 里的记录**有意义** ✓。字段口径与 `task.ts` 的校验器**逐字一致** ✓。
 */
function parseSingleShotText(text: string): { action?: string; params: Record<string, unknown>; reason?: string; why?: string } {
  const raw = typeof text === 'string' ? text : ''
  const m = /^\s*[*-]?\s*\**\s*action\s*[:=：]\s*(.*)$/im.exec(raw)
  if (m === null) return { params: {}, why: 'no action line' }
  const word = m[1].replace(/[`*"'。，,]/g, '').trim()
  if (word === '') return { params: {}, why: 'no action line' }
  const v = validateAnswer(raw, field(raw, 'task') ?? '', [word, 'None'])
  const params = v.ok ? v.answer.params : {}
  const reason = v.ok ? v.answer.reason : field(raw, 'reason')
  return { action: word, params, reason, why: undefined }
}

// ---------------------------------------------------------------------------
// ★★ A：合并投递的**收集队列**（2026-10-18，主人原话：「我感觉你总是会漏，
//    尤其是多个决策同时来的时候」✓✓）
//
// 病根（真机日志 2026-10-18 08:50:58 ✓，逐字）：
//   ▶ 收到 decide  ship=Scout-00001      ← 同一秒
//   ▶ 收到 decide  ship=Trader-00001     ← 同一秒
//   [session] 投递任务 t-805bcccf → 会话   （第一条投出去了）
//   [ladder] 投递会话**正忙**（主人在聊 / 在别的任务上）
//   [ladder] ★ 指挥官会话在线但本轮没答成（SESSION_BUSY）→ 兜底 = None（fallbackNone）
//   ├ 待命裁定：Trader-00001 … 冷却 20 分钟   ← ★ 这艘船就静默 20 分钟 ✗✗
//
// 治法：所有"要投会话"的请求先进这个队列 ✓，由**一个** pump 串行处理 ✓：
//   ① 等 mergeWindowMs 把同一批收齐 ✓；
//   ② 取快照：1 条 → 走原来那条**逐字不变**的单船路径 ✓；
//              N 条 → **一个合并块** + 一次投递 + 多组答案解析 ✓；
//   ③ 每艘船只拿**自己那条**结论 ✓（没答到的 = `UNANSWERED`，交给 index.ts 的 B 去重投 ✓）。
// ★ 一轮在飞时新来的请求**不会丢** ✗：它们留在队列里，本轮结束后立刻开下一轮 ✓
//   （仍然一次只投一个块 ✓ —— TAKEOVER.md 的"同一刻只有一个决策者" ✓）。
// ---------------------------------------------------------------------------

interface RungWaiter {
  deps: DispatchDeps
  req: TaskRequest
  /** 自己这一单的预算 ✓（等别人那一轮的时间也算在内 ✓） */
  budgetMs: number
  atMs: number
  resolve: (a: SessionAttempt) => void
}

const rungWaiters: RungWaiter[] = []
let rungPumpRunning = false

/** 测试用：清空合并队列 ✓（一个进程里多次 apply 必须互不串味 ✓） */
export function resetBatchQueue(): void {
  while (rungWaiters.length > 0) rungWaiters.pop()
  rungPumpRunning = false
}

const sleep = (ms: number): Promise<void> => new Promise((r) => setTimeout(r, Math.max(0, ms)))

/** 把一个请求送进合并队列，等它自己那一份结论 ✓ */
function askSessionRung(deps: DispatchDeps, req: TaskRequest, budgetMs: number): Promise<SessionAttempt> {
  return new Promise<SessionAttempt>((resolve) => {
    rungWaiters.push({ deps, req, budgetMs, atMs: nowMs(), resolve })
    void pumpRungQueue()
  })
}

async function pumpRungQueue(): Promise<void> {
  if (rungPumpRunning) return
  rungPumpRunning = true
  try {
    while (rungWaiters.length > 0) {
      const head = rungWaiters[0]
      const say = head.deps.log ?? ((): void => {})
      const windowMs = budgetOf(head.deps.budgets).mergeWindowMs
      if (windowMs > 0) await sleep(windowMs)
      // ★ 收集窗口结束时把**这一刻**排队的全收下 ✓（后面来的留给下一轮 ✓ —— 绝不丢 ✗）
      const batch = rungWaiters.splice(0, rungWaiters.length)
      if (batch.length === 0) continue
      // 各自的剩余预算（排队把预算耗光的 → 明确说 NO_BUDGET ✓，不投、但绝不静默 ✗）
      const live = batch.filter((b) => {
        const left = b.budgetMs - (nowMs() - b.atMs)
        if (left > 0) return true
        b.resolve({
          answered: false,
          code: 'NO_BUDGET',
          message: `在合并队列里等到没有剩余预算（${b.budgetMs}ms）`,
          steps: 0,
          tookMs: nowMs() - b.atMs,
          batchSize: batch.length,
        })
        return false
      })
      if (live.length === 0) continue
      if (batch.length > 1) {
        say(`  [batch] ★ 合并投递：本轮 ${batch.length} 艘船同时要决策 → **一个块** ✓（不各投一条 ✗）`)
      }
      let got: Map<string, SessionAttempt>
      try {
        got = live.length === 1
          ? new Map([[live[0].req.taskId,
            await runSessionRung(live[0].deps, live[0].req,
              live[0].budgetMs - (nowMs() - live[0].atMs), say)]])
          : await runSessionRungBatch(live, say)
      } catch (error) {
        got = new Map()
        for (const b of live) {
          got.set(b.req.taskId, {
            answered: false,
            code: 'SESSION_ERROR',
            message: `投递/等待时异常：${String(error)}`,
            steps: 0,
            tookMs: nowMs() - b.atMs,
            batchSize: live.length,
          })
        }
      }
      for (const b of live) {
        b.resolve(got.get(b.req.taskId) ?? {
          answered: false,
          code: 'UNANSWERED',
          message: `合并块里这艘船没有收到答案组（批 ${live.length} 艘）`,
          steps: 0,
          tookMs: nowMs() - b.atMs,
          batchSize: live.length,
        })
      }
    }
  } finally {
    rungPumpRunning = false
  }
}

/**
 * ★★ 合并块投递：**一次** followup、**一次**等待、**按 task= 分发** ✓（2026-10-18）。
 *
 * 与 `runSessionRung` 的关系：单船路径**原样保留** ✓（`pumpRungQueue` 里 1 条就走它 ✓）——
 * 这里只处理 N ≥ 2 的那一半 ✓，所以单船语义（重试一次 / ASKED_OWNER / TASK_MISMATCH…）
 * 一个字都没变 ✓✓。
 */
async function runSessionRungBatch(
  waiters: RungWaiter[],
  say: (l: string) => void,
): Promise<Map<string, SessionAttempt>> {
  const t0 = nowMs()
  const n = waiters.length
  const deps = waiters[0].deps
  const out = new Map<string, SessionAttempt>()
  const failAll = (code: string, message?: string): void => {
    for (const w of waiters) {
      if (out.has(w.req.taskId)) continue
      out.set(w.req.taskId, {
        answered: false, code, message, steps: 0, tookMs: nowMs() - t0, batchSize: n,
      })
    }
  }

  // ★ 期限取**最宽**的那条 ✓（每条船自己的预算已经按到达时间扣过 ✓）
  const budgetMs = Math.max(...waiters.map((w) => Math.max(0, w.budgetMs - (nowMs() - w.atMs))))
  if (budgetMs <= 0) {
    failAll('NO_BUDGET', '剩余预算为 0，不投递 ✓')
    return out
  }

  const release = deps.lock?.tryClaim()
  if (deps.lock !== undefined && release === undefined) {
    // 同一个会话同一刻只有一个块在飞 ✓（TAKEOVER.md 铁律 ✓）—— 不排队、不并发投 ✗
    failAll('SESSION_BUSY_ELSEWHERE', '同一时刻已经有一个合并块在用这个会话 → 本轮不投递 ✓')
    return out
  }
  const agent = deps.registry.get(deps.commanderId ?? '')
  if (agent === undefined) {
    release?.()
    failAll('SESSION_GONE', '投递目标会话不在了 ✓')
    return out
  }
  if (deps.subscribe === undefined) {
    release?.()
    failAll('NO_EVENT_CHANNEL', '拿不到 session/event 通道 → 不敢投递（会收不到答案 ✓）')
    return out
  }

  const texts: string[] = []
  let usage: unknown
  let endReason: string | undefined
  let resolveTurn: (() => void) | undefined
  const turnPromise = new Promise<void>((resolve) => { resolveTurn = resolve })

  const stop = deps.subscribe(deps.commanderId ?? '', (event) => {
    const payload = ((event as any)?.data ?? {}) as Record<string, any>
    if (event.type === 'assistant/message') {
      const message = payload.message ?? (event as any).message
      const blocks = message?.content
      const text = Array.isArray(blocks)
        ? blocks.filter((b: any) => b?.type === 'text').map((b: any) => b?.text ?? '').join('')
        : ''
      if (text.trim() !== '') {
        texts.push(text)
        say(`  [session] 合并块：她的第 ${texts.length} 条输出（${text.length} 字 ✓）`)
        try { deps.onAssistantText?.(texts.length, text) } catch { /* 旁路失败不影响决策 ✓ */ }
      }
      if (payload.usage !== undefined) usage = payload.usage
      else if ((event as any).usage !== undefined) usage = (event as any).usage
      return
    }
    if (event.type === 'turn/end') {
      const reason = payload.reason ?? (event as any).reason
      if (reason !== undefined && reason !== null) {
        const kind = typeof reason === 'object' ? (reason as any).kind : reason
        if (kind !== undefined && kind !== 'completed' && kind !== 'user') {
          endReason = typeof reason === 'string' ? reason : JSON.stringify(reason)
        }
      }
      resolveTurn?.()
      return
    }
  })

  try {
    const items = waiters.map((w) => w.req)
    const block = renderTaskBatchBlock({ items })
    say(`  [session] ★ 合并投递 ${n} 艘（task ${items.map((i) => i.taskId).join(', ')}）` +
      `→ 会话（预算 ${Math.round(budgetMs)}ms ✓）；一个块列出全部船 ✓`)
    deps.followup(agent, block, items[0])

    const waited = await withTimeout(turnPromise, budgetMs)
    const tookMs = nowMs() - t0
    if (!waited.settled) {
      try {
        agent.cancel({ kind: 'hook', reason: 'avorion-copilot: merged decision budget expired (timeout)' })
      } catch { /* 取消失败也不能让它抛上去 ✓ */ }
      say(`  [session] 合并块 ${budgetMs}ms 内没结束 → 已 cancel({kind:'hook'}) ✓（**不重投** ✗）`)
      failAll('TIMEOUT', `合并块在 ${budgetMs}ms 内没有给出结论`)
      return out
    }

    const joined = texts.join('\n')
    if (joined.trim() === '') {
      if (endReason !== undefined) {
        failAll('HOST_TURN_FAILED', `宿主结束了这一轮（无 assistant 文本）：${endReason}`)
      } else {
        failAll('EMPTY_REPLY', '这一轮没有任何文本')
      }
      return out
    }

    // ★ 每条船用**自己**的 allowedActions ✓（不同船的动作边界不同 ✓）
    // ★★ 2026-10-20：但**以当场重查**为准 ✓（块里那份是投递时快照，船刚加载完时可能还缺 Mine ✗）
    const specs: AnswerGroupSpec[] = []
    const allowByTask = new Map<string, { actions: string[]; fresh: boolean; snapshot: string[] }>()
    for (const w of waiters) {
      const allow = await allowListFor(w.deps, w.req.ship, w.deps.allowedActions, say)
      specs.push({ taskId: w.req.taskId, ship: w.req.ship, allowedActions: allow.actions })
      allowByTask.set(w.req.taskId, { actions: allow.actions, fresh: allow.fresh, snapshot: w.deps.allowedActions })
    }
    const multi = validateAnswers(joined, specs)
    say(`  [session] 合并块解析：看到 ${multi.groups} 组 / task= 回显对上 ${multi.echoedGroups} 组` +
      `${multi.stray.length > 0 ? `；**别船/未知 task=** ${multi.stray.join(',')} 已丢弃 ✗` : ''}`)
    for (const w of waiters) {
      const v = multi.verdicts.get(w.req.taskId)
      const steps = texts.length
      if (v === undefined) {
        out.set(w.req.taskId, {
          answered: false, code: 'UNANSWERED',
          message: '这一轮没有为这艘船写答案组',
          steps, tookMs, usage, batchSize: n,
        })
        say(`  [session] ✘ ${w.req.ship} 这一轮**没答到** → UNANSWERED（稍后重投 ✓，不进 20 分钟冷却 ✓）`)
        continue
      }
      if (v.ok) {
        out.set(w.req.taskId, {
          answered: true, answer: v.answer, steps, tookMs, usage, raw: joined, batchSize: n,
        })
        say(`  [session] ✔ ${w.req.ship} → ${v.answer.action}` +
          `${v.echoed ? '（回显对上 ✓）' : '（她没回显 task，按顺序配 ✓）'}`)
        continue
      }
      if (v.code === 'ASKED_OWNER') {
        out.set(w.req.taskId, {
          answered: false, code: 'ASKED_OWNER', question: v.question, steps, tookMs, usage, raw: joined, batchSize: n,
        })
        continue
      }
      out.set(w.req.taskId, {
        answered: false, code: v.code, message: v.message, steps, tookMs, usage, raw: joined, batchSize: n,
      })
      say(`  [session] ✘ ${w.req.ship} 校验没过：${v.code}（${v.message ?? ''}）`)
      if (v.code === 'BAD_ACTION') {
        // ★ 被拒的答复**必须留痕** ✓（投递时快照 vs 当场边界 ✓；拒绝理由由 index.ts 回给会话 ✓）
        const a = allowByTask.get(w.req.taskId)
        say(`  [session] ✘ ${w.req.ship} 被拒原因：${v.message ?? ''}）—— 投递时快照 [${(a?.snapshot ?? []).join(',')}]` +
          `，当场边界 [${(a?.actions ?? []).join(',')}]，当场查到的=${a?.fresh === true ? '是 ✓' : '否（退回快照 ✗）'}`)
      }
    }
    return out
  } catch (error) {
    failAll('SESSION_ERROR', `投递/等待时异常：${String(error)}`)
    return out
  } finally {
    try { stop?.() } catch { /* 退订失败不影响结果 ✓ */ }
    release?.()
  }
}

// ---------------------------------------------------------------------------
// 阶梯①的内部：投递 → 等这一轮结束 → 校验
// ---------------------------------------------------------------------------

/**
 * 投一次任务并等它的结论 ✓。**本函数永不抛** ✓（所有失败都变成结果码 ✓）。
 *
 * ★ 舰队级串行：先用 `lock` 抢（拿不到 = 别的决策正占着这个会话 ✓ → 直接放弃这一级 ✓，
 *   **不排队** ✗ —— 排队只会让这一轮白等到超时 ✓）。
 */
async function runSessionRung(
  deps: DispatchDeps,
  req: TaskRequest,
  budgetMs: number,
  say: (l: string) => void,
  allowRetry = true,
): Promise<SessionAttempt> {
  const t0 = nowMs()
  const fail = (code: string, message?: string): SessionAttempt =>
    ({ answered: false, code, message, steps: 0, tookMs: nowMs() - t0 })

  if (budgetMs <= 0) return fail('NO_BUDGET', '剩余预算为 0，不投递 ✓')

  const release = deps.lock?.tryClaim()
  if (deps.lock !== undefined && release === undefined) {
    // ★ 设计书 §3.4「舰队级串行：1 艘/轮」✓ —— 一个会话同一刻只有一个 turn ✓。
    //   抢不到就**不投**（下②单发 ✓）—— 绝不排队 ✗、绝不并发投 ✗✓。
    return fail('SESSION_BUSY_ELSEWHERE', '同一时刻已经有一条决策在用这个会话 → 本轮不投递，直接落单发 ✓')
  }

  const agent = deps.registry.get(deps.commanderId ?? '')
  if (agent === undefined) {
    release?.()
    return fail('SESSION_GONE', '投递目标会话不在了 ✓')
  }

  const texts: string[] = []
  let usage: unknown
  let endReason: string | undefined
  let resolveTurn: (() => void) | undefined
  const turnPromise = new Promise<void>((resolve) => { resolveTurn = resolve })

  const stop = deps.subscribe?.(deps.commanderId ?? '', (event) => {
    // ★★ 宿主派发的 `session/event` 把载荷放在 `event.data` 里 ✓（同宿主的
    //    `dsh-mode-boost` 读的正是 `event.data.source` / `extractText(event.data)` ✓）。
    //
    //    ★ 2026-10-17 实机事故（铁证）：这里原先读的是**顶层** `event.message` ✗ ——
    //    它永远是 `undefined`，于是"她答的每一个字"都没被收进来 ✗：
    //    会话那边明明已经吐出 assistant 文本（会话日志里看得见 ✓），
    //    这里 `texts` 依然是空 → 一轮结束就判 `EMPTY_REPLY`（"这一轮没有任何文本"）✗✗，
    //    整条"投递进会话"的路**从来没有成功过一次**（`decisions.live.log` 里
    //    "她的第 N 条输出" / "校验通过" 一次都没出现过 ✓）。
    //    顶层形态同时保留，两种派发形状都能吃 ✓。
    const payload = ((event as any)?.data ?? {}) as Record<string, any>
    if (event.type === 'assistant/message') {
      const message = payload.message ?? (event as any).message
      const blocks = message?.content
      const text = Array.isArray(blocks)
        ? blocks.filter((b: any) => b?.type === 'text').map((b: any) => b?.text ?? '').join('')
        : ''
      if (text.trim() !== '') {
        texts.push(text)
        say(`  [session] 她的第 ${texts.length} 条输出（${text.length} 字 ✓）`)
        try { deps.onAssistantText?.(texts.length, text) } catch { /* 旁路失败不影响决策 ✓ */ }
      }
      if (payload.usage !== undefined) usage = payload.usage
      else if ((event as any).usage !== undefined) usage = (event as any).usage
      return
    }
    if (event.type === 'turn/end') {
      // ★ 只认"我们发出去之后"这一轮的结束 ✓：本订阅是在**投递之前**建好的 ✓，
      //   所以此前那一轮（主人自己的聊天）的 turn/end 不可能走到这里 ✓✓。
      //
      // ★★ 但**宿主自己把这一轮判死**是另一回事 ✗：那种情况下它同样会发一个
      //    turn/end（reason 不是 completed），于是一个字都没有就"结束"了 ✓。
      //    把它的原话留下来 ✓ —— 否则错误会被吞成 EMPTY_REPLY，排查只能从
      //    "没有文本"倒推（2026-10-17 的 v4 source kind 事故就是这么被吞掉的 ✗）。
      const reason = payload.reason ?? (event as any).reason
      if (reason !== undefined && reason !== null) {
        const kind = typeof reason === 'object' ? (reason as any).kind : reason
        if (kind !== undefined && kind !== 'completed' && kind !== 'user') {
          endReason = typeof reason === 'string' ? reason : JSON.stringify(reason)
        }
      }
      resolveTurn?.()
      return
    }
  })

  try {
    const block = renderTaskBlock(req)
    if (deps.subscribe === undefined) {
      // 没有事件通道 = 收不到答案 ✗ → 别投（投了也是白投，还会污染那个会话 ✓）
      return fail('NO_EVENT_CHANNEL', '拿不到 session/event 通道 → 不敢投递（会污染会话且收不到答案 ✓）')
    }
    say(`  [session] 投递任务 ${req.taskId} → 会话（预算 ${budgetMs}ms ✓）；她会在会话里留下一条可见的 user 消息 ✓`)
    // ★ 真实现用 createUserMessage({content:[{type:'text',text}], source:{kind:'plugin',plugin:'dsh-avorion-copilot'}})
    //   —— 由 index.ts 注入（本模块不 import dsh-llm，好让测试完全离线 ✓）。
    deps.followup(agent, block, req)
    // ★ 续期由调用方做（index.ts 确认这次真的投出去了之后 renewLease ✓）。

    const waited = await withTimeout(turnPromise, budgetMs)
    const tookMs = nowMs() - t0
    if (!waited.settled) {
      // ★ 硬闸到 → **掐掉这一轮** ✓（否则失控的一轮会一直占着会话 ✓）；
      //   ★ 失败**绝不重投** ✗（重投 = 同一艘船两条矛盾命令 ✓ —— TAKEOVER.md 铁律 ✓）。
      // ★★ cancel 的 cause 必须是宿主认得的 kind（user | parent | disposed | hook ✓）。
      //    乱传 kind（原先传的是 'timeout' ✗）会让宿主的 abortedCancelCause 落到
      //    assertNever 抛错 → 那一轮的 turn/end 被写成 **reason: null** ✗ →
      //    客户端回放轨迹时 `reason.kind` 直接 TypeError → 整个会话界面空白 ✗✗
      //    （2026-10-17 实测事故 ✓）。官方支持的语义里，"插件/钩子让这一轮停下"
      //    就是 hook ✓，所以带上 reason 走 hook ✓。
      try { agent.cancel({ kind: 'hook', reason: 'avorion-copilot: decision budget expired (timeout)' }) } catch { /* 取消失败也不能让它抛上去 ✓ */ }
      say(`  [session] ${budgetMs}ms 内没结束 → 已 cancel({kind:'hook'}) ✓ 并放弃这一级（**不重投** ✗）`)
      return { answered: false, code: 'TIMEOUT', message: `会话在 ${budgetMs}ms 内没有给出结论`, steps: texts.length, tookMs, usage }
    }

    const last = texts.length > 0 ? texts[texts.length - 1] : ''
    // ★ 一个字都没收到、而宿主又**不是**正常收起这一轮 → 把宿主的原因原样报出来 ✓
    //   （这样 decisions.live.log 里出现的是真因，而不是含糊的"这一轮没有任何文本" ✓；
    //    2026-10-17 的 v4 source kind 事故就是被 EMPTY_REPLY 吞掉、白查了一小时的 ✓）
    if (last.trim() === '' && endReason !== undefined) {
      say(`  [session] ✘ 宿主结束了这一轮且没有 assistant 文本：${endReason}`)
      return {
        answered: false,
        code: 'HOST_TURN_FAILED',
        message: `宿主结束了这一轮（无 assistant 文本）：${endReason}`,
        steps: 0,
        tookMs,
        usage,
      }
    }
    // ★★ 2026-10-20：校验前**当场重查**动作边界 ✓（块里那份是投递时的快照，可能过期 ✓）
    const allow = await allowListFor(deps, req.ship, deps.allowedActions, say)
    const verdict = validateAnswer(last, req.taskId, allow.actions)
    if (verdict.ok) {
      say(`  [session] ✔ 校验通过${verdict.echoed ? '（回显 task 对上了 ✓）' : '（她没回显 task，但内容合格 ✓）'}`)
      return { answered: true, answer: verdict.answer, steps: texts.length, tookMs, usage, raw: last }
    }
    const code: string = verdict.code
    if (code === 'ASKED_OWNER') {
      return { answered: false, code, question: verdict.question, steps: texts.length, tookMs, usage, raw: last }
    }
    say(`  [session] ✘ 校验没过：${code}（${verdict.message ?? ''}）`)
    if (code === 'BAD_ACTION') {
      // ★ 被拒的答复**必须留痕** ✓：两条清单都摆出来（投递时 / 当场 ✓），下一步由 index.ts 回给会话 ✓
      say(`  [session] ✘ 被拒原因（${code}）：${verdict.message ?? ''}）—— 投递时快照 [${deps.allowedActions.join(',')}]` +
        `，当场边界 [${allow.actions.join(',')}]，当场查到的=${allow.fresh ? '是 ✓' : '否（退回快照 ✗）'}`)
    }

    // ---- 只对"完全没有动作行"再给一次机会 ✓（同 today 的重试 ✓，只此一次 ✓）----
    const retryable = code === 'NO_ACTION_LINE' || code === 'EMPTY_REPLY'
    if (allowRetry && deps.retrySessionOnce === true && retryable) {
      const left = budgetMs - (nowMs() - t0)
      const retryBudget = Math.min(left, deps.budgets?.retryOnceMs ?? BUDGETS.retryOnceMs ?? 0)
      if (retryBudget > 500) {
        // ★ 新任务 id：她上一轮可能已经在**同一轮里**回了一句别的（回显旧 id ✓）——
        //   沿用旧 id 会让她"回显旧 id 而被判 TASK_MISMATCH"✗。换新 id 最干净 ✓。
        const retryTaskId = makeTaskId()
        say(`  [session] 再投一次（同一批事实、只要求答案行 ✓；新任务号 ${retryTaskId}；` +
          `预算 ${Math.round(retryBudget)}ms，**只此一次** ✗）`)
        const second = await runSessionRung(deps, { ...req, taskId: retryTaskId }, retryBudget, say, false)
        return {
          ...second,
          steps: texts.length + second.steps,
          tookMs: nowMs() - t0,
          code: second.answered ? undefined : (second.code ?? code),
          message: second.answered
            ? undefined
            : `第一次：${code}（${verdict.message ?? ''}）；重试：${second.message ?? second.code ?? ''}`,
        }
      }
    }
    return { answered: false, code, message: verdict.message, steps: texts.length, tookMs, usage, raw: last }
  } catch (error) {
    return fail('SESSION_ERROR', `投递/等待时异常：${String(error)}`)
  } finally {
    try { stop?.() } catch { /* 退订失败不影响结果 ✓ */ }
    release?.()
  }
}

export { makeTaskId, renderTaskBlock, validateAnswer }
export type { TaskAnswer, TaskRequest }
