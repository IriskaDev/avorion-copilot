/**
 * @dsh-external/dsh-avorion-copilot —— Avorion `copilot` mod ⇄ DSH 的桥接插件。
 *
 * ## 本版（RPC 版）
 *
 * 传输从「文件桥」换成「**TCP + 对称 RPC**」✓（协议见 mod 仓库的 docs/dev/protocol.md v2）。
 * 本质就是主人点透的那句话：
 *   **让 DSH 能调游戏的功能，也让游戏能调 DSH 的功能。** ✓
 *
 * ```
 *   游戏（Lua rpc.lua）  ⇄  TCP 127.0.0.1:8765  ⇄  本插件（rpc.ts）
 *        handle: hello/query/order/decide/reload/ping      ← 游戏提供的功能
 *        call:   hello/state/decide                        ← 游戏发起的请求
 * ```
 *
 * 本插件**监听** 8765（游戏主动连过来 ✓ —— 这样不触发 Windows 防火墙弹窗 ✓）。
 *
 * ## 文件桥时代的东西去哪了
 *
 * `watch`/`atomicWrite`/`writeDiagnostics` 全部删掉 ✓ —— 不再需要 ✓。
 * **`SYSTEM_PROMPT` 与 `parseDecision` 那一套一字未改** ✓ —— 它们是调研出来的领域知识
 * 和踩过坑的鲁棒解析 ✓，与传输无关 ✓。
 */

import fs from 'node:fs'
import path from 'node:path'
import os from 'node:os'
import { createUserMessage } from '@deepseek-ai/dsh-llm'
// ★ 长期记忆（增量 1/3，2026-10-16）：决策大脑的持久运营知识 ✓
import {
  retrieve as retrieveMemory, rememberStart, rememberOutcome,
  describe as describeMemory, forget as forgetMemory, memoryPath,
} from './memory.js'
import type { GenerateOptions, StreamChunk } from '@deepseek-ai/dsh-llm/types'
import { RpcPeer } from './rpc.js'
import { registerFleetTools, ask } from './tools.js'
import { loadSystemPrompt, setPromptNotifier, describePromptPaths } from './promptfile.js'
// ★★ 投递阶梯（Phase A/B，2026-10-17 ✓）：目标会话 = **主人自己正在用的那个会话**
import {
  dispatchDecision, BUDGETS, makeTaskId, resetBatchQueue,
  type AgentLike, type DispatchOutcome, type SessionAttempt,
} from './dispatch.js'
import {
  getCommanderSessionId, setCommanderSession, renewLease, getState as getCommanderState,
  isLeaseFresh, setCommanderNotifier, COMMANDER_FILE, type CommanderState,
} from './commander.js'
import { renderTaskBlock, PREV_RESULT_BUDGET_BYTES } from './task.js'
// ★★ 待命裁定（2026-10-17 主人要求 ✓）：决策者判 None 后同船冷却期内不再征询 ✓
import {
  recordStandby, standbyVerdict, goalFingerprintOf, clearStandby, resetStandbyCache,
  DEFAULT_NONE_COOLDOWN_MS, DEFAULT_UNANSWERED_RETRY_MS, DEFAULT_UNANSWERED_MAX_MISSES,
  type StandbyKind,
} from './standby.js'
// ★★ 单发路径的**有界档案**（2026-10-17 ✓）：预取 + 裁剪 + 硬字节预算 ✓
//   ★ 它与 agent 路径**共享数据、不共享渲染** ✓✓ —— 见 dossier.ts 的文件头（根因就在那儿 ✓）
import { renderDossier, byteLen as dossierByteLen, type DossierPayload } from './dossier.js'

// ★ 把提示词相关通知接到实时流水 ✓（live 是函数声明，已提升 ✓）
setPromptNotifier(live)
// ★ 投递目标（会话）的变化也进流水 ✓（主人一眼看到"现在投给谁" ✓）
setCommanderNotifier(live)
// 启动时把"该改哪个文件"写进流水一次 ✓
for (const line of describePromptPaths()) live(line)

export const name = '@dsh-external/dsh-avorion-copilot'

/** 需要 LLM 服务；没有它插件不启动。 */
export const inject = ['llm', 'tools']   // ★ 'tools'：注册 fleet_* 工具必需 ✓（照 dsh-global-memory ✓）

/** ctx 的最小结构化描述，避免依赖拿不到的 cordis 类型。 */
interface CopilotCtx {
  logger?: {
    info?: (message: string) => void
    warn?: (message: string) => void
  }
  llm: {
    stream(options: GenerateOptions): AsyncIterable<StreamChunk>
    listProviders?(): unknown
  }
  effect(fn: () => (() => void) | void, label?: string): void
  /** ★ 工具注册（inject 里已声明 'tools' ✓） */
  tools: { register(tool: unknown): unknown }
  /** ★ `ctx.agents`（不经 inject：拿不到也不影响单发路径 ✓ —— 见 resolveAgents ✓） */
  agents?: unknown
  /**
   * ★ `ctx.on('session/event', …)` ✓ —— 收会话答案靠它 ✓。
   *   作用域规则（`dsh-scope`）：**未打 scope 标记的监听者收到所有会话的事件** ✓，
   *   所以我们按 sessionId 自己筛 ✓（与 dsh-goal-round-driver 同一套做法 ✓）。
   */
  on?: (event: string, listener: (...args: any[]) => void) => unknown
  get?(name: string): unknown
  /**
   * ★ **等一个可选服务**（cordis 自带 ✓）。
   *
   * `ctx.get(name)` 是**当场**查 ✗ —— 服务还没就绪就是 undefined ✓；
   * `ctx.inject([name], cb)` 则是**等它就绪再回调** ✓✓，回调收到的是能直接
   * `.name` 取到该服务的子 ctx ✓（原版 `dsh-client-modules` 就是这么拿 webServer 的 ✓）。
   * 注意：用它 ★ 不等于 ★ 把服务写进 `export const inject` ✗ ——
   * 后者是"没有它插件就别启动" ✓，而我们要的是"没有它照样跑，只是少个开关" ✓。
   */
  inject?(names: string[], fn: (ctx: any) => void): unknown
}

/**
 * ★ 把日志**同时写进文件** ✓
 *
 * 因为 DSH 的 `ctx.logger` 只进控制台、**不落盘** ✗ —— 而本项目的验证方式一直是"读日志" ✓。
 * 写到与 mod 同一个目录（`moddata/copilot/`）✓，agent 就能像读其他日志一样读它 ✓✓。
 */
const LOG_FILE = path.join(os.homedir(), 'AppData', 'Roaming', 'Avorion', 'moddata', 'copilot', 'rpc_dsh.log')

function fileLog(line: string): void {
  try {
    fs.mkdirSync(path.dirname(LOG_FILE), { recursive: true })
    fs.appendFileSync(LOG_FILE, `${new Date().toISOString()}  ${line}\n`)
  } catch { /* 日志失败绝不能影响主流程 ✓ */ }
}

interface CopilotConfig {
  /** 监听端口；默认 8765（与游戏侧一致） */
  port?: number
  provider?: string
  model?: string
  maxTokens?: number
  temperature?: number
  /**
   * ★ 决策任务投递到**哪个会话**（主人自己的会话 id ✓）。
   *   缺省 → 用落盘的选择（`fleet_commander` 指定过的 ✓）；都没有 = 不投递 ✓
   *   （= 今天的单发路径，逐字不变 ✓）。
   */
  commanderSession?: string
  /**
   * ★ 怎么用那个会话的答案（主人 2026-10-17 定的两阶段 ✓）：
   *   · `shadow`（**默认**）= 只投递 + 只观测：她的答案被记下来并跟单发的答案并排比较，
   *     但**实际下单仍然是单发** ✓✓ —— 零风险地量延迟/成本/质量 ✓（设计书推荐的第一步 ✓）。
   *   · `live` = 她的答案**算数** ✓（校验通过就直接下单 ✓）；她没答成才落单发 ✓。
   *     ★ 需要主人显式打开（这也是"回滚开关"：改回 shadow 即恢复零风险 ✓，不用重启游戏 ✓）。
   */
  decideMode?: 'shadow' | 'live'
  /** 主人在那个会话里聊天时要不要插队投递（**默认 false** ✓ —— 主人的对话优先 ✓） */
  steerWhenBusy?: boolean
  /** 会话第一次答不上来时要不要再投一次（默认 false ✓）；单发那次重试默认开 ✓ */
  retrySessionOnce?: boolean
  /**
   * ★★ 待命裁定冷却（毫秒）：决策者判某船 None 后，同船这段时间内不再征询 ✓
   *   （默认 20 分钟；主人建议 15~30 分钟 ✓）。目标改变 / 手动召回会提前恢复 ✓。
   *   ★ 2026-10-18：它**只**管"决策者明确写了 action=None"那种 ✓；
   *     漏答（fallbackNone）走下面的 `unansweredRetryMs` ✓（分级 ✓）。
   */
  noneCooldownMs?: number
  /**
   * ★★ 漏答**重投间隔**（毫秒，默认 3 分钟 ✓，2026-10-18）：
   *   会话在线但这一轮**没答到这艘船**（忙/超时/漏答/格式错）→ 不罚 20 分钟 ✗，
   *   记 `unanswered` 并在这么短之后**重新投递** ✓（建议 2~3 分钟 ✓）。
   */
  unansweredRetryMs?: number
  /**
   * ★★ 连续漏答**几次**才落到 None + 长冷却（默认 3 ✓，2026-10-18）——
   *   避免"会话一直答不上来"时无限重投打扰主人 ✗。
   */
  unansweredMaxMisses?: number
  /**
   * ★★ 合并投递的**收集窗口**（毫秒，默认 800 ✓，2026-10-18）：
   *   多艘船同时空闲时先等这一小会儿，把同一批收进**一个块** ✓；
   *   `0` = 不合并（逐条投，旧行为 ✓）。
   */
  mergeWindowMs?: number
}

/**
 * ★★ 一次决策的完整记录（主人在 DSH 里要看得见的东西 ✓✓）。
 *
 * 分五段，正好对应主人的问法 "决策过程" ✓：
 *   ① 触发  ship / at / goalText
 *   ② 输入  card（星区·船长·忙闲）+ routes（候选路线表 ✓）
 *   ③ 推理  modelText + **reasoning**（思维链 ✓✓）
 *   ④ 结论  answer（action / params / reason）
 *   ⑤ 结果  orderResult（下单回执 ✓）/ code + message（失败时 ✓）
 */
/**
 * ★★ 决策的**粗粒度来源**标签（2026-10-17 主人要求 ✓✓）——
 *   进「上一单的结果」块文案与 fleet_decisions，让主人一眼看出"这单谁定的" ✓。
 *   `source` 更细（区分 shadow / asked-owner / none），`decider` 只回答"谁拍板/谁不下单" ✓。
 */
export type Decider = 'session' | 'single-shot' | 'rendezvous' | 'fallbackNone'

/**
 * ★ source → decider 的**单一映射**（只有一个真相来源 ✓）：
 *   · 会话定的（含她在问主人）→ session；单发定的（含影子采纳）→ single-shot；
 *   · rendezvous → rendezvous；「都没有」与「兜底不下单」→ fallbackNone ✓。
 */
export function deciderOf(source: string | undefined): Decider | undefined {
  switch (source) {
    case 'session':
    case 'asked-owner':
      return 'session'
    case 'single-shot':
    case 'shadow':
      return 'single-shot'
    case 'rendezvous':
      return 'rendezvous'
    case 'fallbackNone':
    case 'none':
      return 'fallbackNone'
    default:
      return undefined
  }
}

export interface DecisionRecord {
  at: string
  ship: string
  goalText: string
  goalOptions: string[]
  /**
   * ★★ 这一单是**谁**定的（2026-10-17 补 ✓）—— 主人一眼看出决策来自哪条路 ✓：
   *   `session`      = 投进主人会话、由她定的 ✓
   *   `single-shot`  = 插件自己那一次单发调用定的 ✓（今天的行为 ✓）
   *   `shadow`       = ★ 影子模式：她答了，但这一单**采纳的是单发** ✓（Phase B ✓）
   *   `asked-owner`  = 她在问主人 → 本轮**明确延期**、未派单 ✓（人在环里 ✓）
   *   `none`         = 两条路都没有可用答案 ✓
   *   `rendezvous`   = 插件自己先派护航、本轮不下单 ✓（既有逻辑 ✓）
   *   `fallbackNone` = ★ 指挥官会话在线但本轮没答成 → 兜底 = None（不许单发拍板 ✓）
   */
  source?: 'session' | 'single-shot' | 'shadow' | 'asked-owner' | 'none' | 'rendezvous' | 'fallbackNone'
  /**
   * ★★ 这一单**谁定的**（2026-10-17 主人要求 ✓✓）—— 与 `source` 互补的**粗粒度**标签，
   *   贯通到「上一单的结果」块文案与 fleet_decisions ✓：
   *   · `session`      = 会话定的（含 `asked-owner`：是她在问主人，也算她这一级 ✓）；
   *   · `single-shot`  = 单发定的（含 `shadow`：影子模式下采纳的也是单发 ✓）；
   *   · `rendezvous`   = 护航 rendezvous 定的 ✓；
   *   · `fallbackNone` = 兜底说"不下单"（会话在线但没答成 / 待命裁定冷却期内 ✓）。
   *   ★ 由 `deciderOf(source)` 单一映射 ✓ —— 旧记录没有它就按 source 反推 ✓。
   */
  decider?: Decider
  card?: unknown
  routes?: unknown
  ok: boolean
  code?: string
  message?: string
  modelText?: string
  reasoning?: string
  truncated?: boolean
  answer?: { action: string; params: Record<string, unknown>; reason?: string }
  orderResult?: unknown
  /** ★ 会话那一路的观察结果（她答了什么 / 几步 / 多久 / 为什么没答成 ✓ —— 影子模式最有价值的一栏 ✓） */
  session?: SessionAttempt
  /** ★ 她的答案与单发的答案**是否一致**（影子模式下用来量"她靠不靠谱" ✓） */
  agreement?: boolean
  /**
   * ★★ 两条路的**体积实测**（2026-10-17 加 ✓✓ —— 体积问题必须有可回看的数字 ✓）：
   *   · `blockBytes`   = 投进会话那个块的真实字节数 ✓（agent 路径；目标远小于 2 KB ✓）
   *   · `cardCopies`   = 那次块里出现了几遍船卡 ✓（**必须是 0** ✗ —— 以前是 2 ✓）
   *   · `dossierBytes` = 单发那份有界档案的字节数与裁剪记录 ✓（`dossier.ts` 的 stats ✓）
   */
  delivered?: { blockBytes: number; cardCopies: number; targetBytes: number }
  dossierBytes?: unknown
  /**
   * ★★ 下单回执（结构化，2026-10-17 补 ✓✓）：把游戏 order 的 accepted/executed/error 落盘 ✓。
   *   · `accepted` = 游戏收下了这单（没被拒 ✓）；
   *   · `executed` = 真的排进了 startCommand（两段式第二阶段 ✓）；
   *   · `error`   = 失败/被拒/未执行时的原因（游戏原话 or "not connected to the game" ✓）。
   */
  receipt?: OrderReceipt
  /**
   * ★★ 失败回投的完整记录（2026-10-17 补 ✓✓）：每回投一次就记一行 ✓，
   *   `reason` = 上一单为什么失败 / `action` = 回投后重新选了啥 / `receipt` = 那次下单的回执 ✓。
   */
  redeliveries?: Array<{
    at: string
    reason: string
    action?: string
    params?: Record<string, unknown>
    receipt?: OrderReceipt
    note?: string
  }>
  /** ★★ 回投达到上限/退避而停止时，写明"需人工介入"的原因 ✓ */
  needsIntervention?: string
}

/** ★ 下单回执（2026-10-17 补 ✓）：`accepted` + `executed` + `error`，跨重启可审计 ✓ */
/**
 * ★★ 游戏侧给的「这次下单的伏击风险评估」（2026-10-17 加 ✓✓）。
 *   口径 = 游戏 `predict` 的**同一份代码**（`link_in.lua` 的 `orderRiskOf` 直接调 predict ✓），
 *   所以数值与决策前用 `fleet_query what=predict` 查到的一模一样 ✓✓。
 *   · `known=false` → `attackChance` 是 **null/undefined**（**绝不是 0** ✗✓：0 = 游戏说不会遇伏击）；
 *   · Travel 的数是**整段航程**被伏击的概率 ✓（原版 Travel 命令自带评估 ✓）；
 *   · `baseAttackChance` 是基准（判断「<10% 吗」只看它 ✓）；Travel 没有 base →
 *     `baseAttackChanceKnown=false` + `baseAttackChanceUnknownReason` ✓。
 */
export interface OrderRisk {
  known: boolean
  attackChance?: number | null
  baseAttackChance?: number | null
  baseAttackChanceKnown?: boolean
  baseAttackChanceUnknownReason?: string
  riskKind?: string | null
  unknownReason?: string
  attackChanceWithEscorts?: number | null
}

/**
 * ★★ 预检（preflight）—— 游戏侧在**下单前**按动作核对前置条件的结论 ✓✓（2026-10-17）
 *
 * 主人的原话（这套结构的由来）：「你下的指令似乎你都不知道是有没有正常执行啊，回执没法带结果吗？」
 * 今晚四种「接了却没做」（回执都是 accepted:true executed:true ✗）：
 *   ① Sell 清单里混了没人收的货 → 一件没卖；② Sell 在没买家的框 → 空转；
 *   ③ `startCommand -> ok=true` 只是"进队列"；④ Travel 只有 1 跳 → 接单不动。
 * 根因 = 回执只反映 RPC 队列那一步 ✗ —— 所以游戏侧加了这一层：
 *   `preflight.ok=false` → **压根没下单**（没发起区域分析、没排 startCommand ✓）。
 * ★ `ok=false` 时字段是 `{ok:false, code, reason, detail}` ✓；通过时还会有 checks / warnings。
 */
export interface OrderPreflightCheck { name?: string; ok?: boolean; reason?: string; detail?: string }
export interface OrderPreflightWarning { code?: string; detail?: string }

export interface OrderPreflight {
  ok: boolean
  /** 失败码：MIN_DISTANCE / ALREADY_THERE / SHIP_NOT_IN_AREA / CAPTAIN_NOT_MERCHANT / ... */
  code?: string
  /** 人话原因（游戏侧原文，**不翻译** ✓） */
  reason?: string
  detail?: string
  /** 逐项结论（ok=true 的那些也在这里 ✓） */
  checks?: OrderPreflightCheck[]
  /**
   * ★ 提示（**不是失败** ✓）：原版**不会**拒绝、但按主人的规矩/机制值得知道的事。
   *   例：`DURATION_CLAMPED`（被原版夹紧）、`SELL_SKIPPED`（卖不掉的货被剔掉）、
   *       `ESCORT_UNARMED`（原版不查武装 ✗）、`ESCORT_OUT_OF_SECTOR`（原版允许一跳之内 ✓）
   */
  warnings?: OrderPreflightWarning[]
  /** 预检时真的改过的参数（如 duration 被夹紧 ✓） */
  applied?: Record<string, unknown>
  /** 预检时读到的船状态（位置 / busy / 货舱 ✓ —— 与实测同一个读取函数 ✓） */
  state?: Record<string, unknown>
  /** Sell 专用：有买家 / 卖不掉 的逐货结论（判据 = 原版 getErrors ✓） */
  sell?: {
    sellableKinds?: number
    sellableUnits?: number
    skippedKinds?: number
    skippedUnits?: number
    skipped?: Array<{ goodName?: string; amount?: number; reason?: string }>
  }
  /** 护航逐条事实（available / sameSector / distance / reach / canFight ✓） */
  escorts?: Array<Record<string, unknown>>
  /** Travel 专用：距离 / route 段数 / 时长 ✓（与 predict 同一份分析 ✓） */
  travel?: Record<string, unknown>
}

/**
 * ★★ 实测（verify）—— startCommand 之后**延迟重读实体状态**的结论 ✓✓（2026-10-17）
 *
 * ★ 判定口径（游戏侧 verifyVerdict ✓，都来自原版实读）：
 *   · **主证据 = `busy:true`**（= `InBackground`，simulation.lua:584 —— 这一行在**所有**闸门之后 ✓）；
 *   · Travel：位置/终点（但原版**只在 onFinish/onRecall 才写坐标** → 航程中间不动是正常的 ✓）；
 *   · Sell/Refine：`cargoUsed` 下降（★ 只在**跑完**才结算 ✓ —— 短窗口里 `busy` 才是证据 ✓）；
 *   · Mine/Salvage/Trade/Scout：`busy:true`（产出进派系资源池 / 货舱在结束时才变 ✓）。
 *   · `ok=false` + `reason` = "**接了却什么都没发生**"（原版静默拒绝的样子 ✓）。
 * ★ `pending:true` = 还没到采样点（RPC 是一次问答，实测只能**稍后**取 ✓）。
 */
export interface OrderVerify {
  pending?: boolean
  /** 还要等几秒（pending 时有 ✓） */
  etaSeconds?: number
  at?: string
  ok?: boolean
  reason?: string
  note?: string
  /** atDestination / moved / busy / cargoUsedDecreased / cargoUsedIncreased / cargoChanged */
  evidence?: string
  started?: boolean
  startCommandQueued?: boolean
  afterStartSec?: number
  busy?: boolean
  busyKnown?: boolean
  availability?: unknown
  moved?: boolean | null
  atDestination?: boolean
  position?: { x: number; y: number }
  positionBefore?: { x: number; y: number }
  cargoUsed?: number
  cargoUsedBefore?: number
  cargoUsedDelta?: number
  cargoKinds?: number
  cargoKindsBefore?: number
  holdHasGoods?: boolean
  destination?: { x: number; y: number }
  stage?: number
  hint?: string
}

export interface OrderReceipt {
  at: string
  accepted: boolean
  executed: boolean
  /**
   * ★★ 已发送但没收到确认（order RPC 超时回 `no response` / 断连回 `connection lost`）✓✓。
   *   这是**假阴性** ✗：order 是 fire-and-forget，游戏可能已经在跑了 ✓（实机铁证：
   *   下单 RPC 超时回 no response，船其实已经从 (-381,57) 挪到 (-373,60) ✓✓）。
   *   → **绝不据此判失败、绝不回投** ✗（回投 = 同一艘船两条矛盾命令 ✗）；
   *   下一轮用 list/ship 的 busy/舱量来核实真实结果 ✓。
   */
  unconfirmed?: boolean
  /** ★ 游戏侧对**这一单**的伏击风险评估（2026-10-17 ✓）；缺省 = 老游戏侧没这个字段 ✓ */
  risk?: OrderRisk
  /** ★★ 下单**之前**的前置条件核对（2026-10-17 ✓✓）；`ok=false` = 这单**根本没下** ✗✓ */
  preflight?: OrderPreflight
  /** ★★ 下单**之后**的实测结论（2026-10-17 ✓✓）；`pending:true` = 还没到采样点 ✓ */
  verify?: OrderVerify
  /** ★★ 下单号（取实测结论用 ✓）：`fleet_query{what:'orderStatus', orderId}` 或按 ship ✓ */
  orderId?: number | string
  error?: string
  note?: string
}

/**
 * 决策记录（环形，最多 50 条 ✓）。放在模块级，工具与 decide 处理器共用 ✓。
 * 只在内存里 —— 够主人现场回看 ✓；要长期留档再落文件 ✓。
 */
export const decisionLog: DecisionRecord[] = []
export const DECISION_LOG_LIMIT = 50

/**
 * ★★ 决策记录也**落盘**（2026-10-16 补）：
 *   原来只在内存里 ✗ —— DSH 一重启就清空，主人就看不到历史 ✓。
 *   现在每记一条，就往 moddata/copilot/decisions.log **追加一行 JSON** ✓✓
 *   （一行一条，便于 grep；文件大了也不影响读取 ✓）。
 */
const decisionFile = path.join(
  os.homedir(), 'AppData', 'Roaming', 'Avorion', 'moddata', 'copilot', 'decisions.log',
)

function recordDecision(rec: DecisionRecord): void {
  // ★★ decider 由 source 单一映射补上（旧代码只设 source，这里绝不漏 ✓；读盘旧记录则按 source 反推 ✓）
  if (rec.decider === undefined && rec.source !== undefined) {
    rec.decider = deciderOf(rec.source)
  }
  decisionLog.push(rec)
  while (decisionLog.length > DECISION_LOG_LIMIT) decisionLog.shift()
  try {
    fs.appendFileSync(decisionFile, JSON.stringify(rec) + '\n')
  } catch {
    /* 落盘失败不能影响决策本身 ✓ */
  }
}

/**
 * ★★ 实时流水（2026-10-16 补 ✓）：主人希望**边发生边看** ✓✓
 *
 * 与 decisions.log 的区别：
 *   decisions.log  = 一条决策**结束后**的完整快照 ✓
 *   decisions.live = **每一步发生时就追加一行**（毫秒时间戳 ✓），
 *                    所以主人（或本 agent）可以一边跑一边 tail -f ✓✓
 */
const liveFile = path.join(
  os.homedir(), 'AppData', 'Roaming', 'Avorion', 'moddata', 'copilot', 'decisions.live.log',
)

export function live(msg: string): void {
  const ts = new Date().toISOString().replace('T', ' ').replace('Z', '')
  try {
    fs.appendFileSync(liveFile, `${ts}  ${msg}\n`)
  } catch {
    /* 流水写不进去也不能影响决策 ✓ */
  }
}

/**
 * ★★★ 原始 token 流（2026-10-16 补，主人要求"实时看原始思维过程及输出" ✓✓）
 *
 * 与 decisions.live.log 的区别：
 *   decisions.live = **加工过的行**（本鱼组织的步骤文字 ✓ + 思维链按行 ✓）
 *   decisions.raw  = ★ **一字不改的 delta 流** ✓✓
 *                    模型的推理 token 与正文 token **到达的瞬间**就落盘 ✓，
 *                    顺序、断行、半截词全都保留 ✓ —— 这才是"原始" ✓✓
 *
 * 注意：**内容是否完整取决于模型/服务商** ✗ ——
 *   若端点返回的是整理过的 reasoning，那这里也就是整理版 ✓（本鱼无法还原 ✗）。
 *   要真正完整，需换成返回完整 CoT 的模型 ✓。
 */
const rawFile = path.join(
  os.homedir(), 'AppData', 'Roaming', 'Avorion', 'moddata', 'copilot', 'decisions.raw.log',
)

// ---------------------------------------------------------------------------
// ★★ 会话事件的**路由**（Phase A，2026-10-17 ✓）
//
// 我们靠 `ctx.on('session/event', …)` 收"她答了什么" ✓。作用域规则（`dsh-scope`）是：
// **未打 scope 标记的监听者收到所有会话的事件** ✓ —— 所以我们只**装一个**监听器，
// 再按 sessionId 把它派发给"此刻正在等这个会话"的那一个等待者 ✓✓。
//
// ★ 为什么必须路由、不能每个决策各装一个监听器 ✗：那样 N 艘船同时决策就有 N 个监听器，
//   每个都要自己筛一遍所有事件（还可能互相看见对方那一轮 ✗）✓。
// ---------------------------------------------------------------------------

type SessionEventListener = (event: any) => void
const sessionListeners = new Map<string, Set<SessionEventListener>>()

/** 把一个监听器挂到某个会话上 ✓；返回退订函数 ✓ */
function subscribeSession(sessionId: string, fn: SessionEventListener): () => void {
  let set = sessionListeners.get(sessionId)
  if (set === undefined) { set = new Set(); sessionListeners.set(sessionId, set) }
  set.add(fn)
  return () => {
    const cur = sessionListeners.get(sessionId)
    if (cur === undefined) return
    cur.delete(fn)
    if (cur.size === 0) sessionListeners.delete(sessionId)
  }
}

/** 把一条 session/event 派发给等这个会话的人 ✓（没有等待者就静默丢掉 ✓ —— 主人自己的聊天不该被我们插嘴 ✓） */
function dispatchSessionEvent(session: any, event: any): void {
  const id = (session !== null && typeof session === 'object' && typeof session.id === 'string')
    ? session.id
    : ''
  if (id === '') return
  const set = sessionListeners.get(id)
  if (set === undefined) return
  for (const fn of [...set]) {
    try { fn(event) } catch { /* 单个监听器出错不许影响别人 ✓ */ }
  }
}

// ---------------------------------------------------------------------------
// ★★ 舰队级串行 + 下单幂等（2026-10-17 ✓）
//
// 铁律（TAKEOVER.md）：**同一时刻只能有一个决策者** ✓。一个会话同一刻只能有一个 turn ✓，
// 所以"投递目标会话"这一级用一把**单一**锁 ✓：抢不到就**根本不投** ✓ → 直接落单发 ✓
// （不排队 ✗ —— 排队只会让这一轮白等到超时，而单发本来就是对的答案 ✓）。
// ---------------------------------------------------------------------------

let sessionInFlight: boolean = false

/**
 * 取不到 = 已经有一条决策在用那个会话 ✓（本次调用直接落单发 ✓）。
 * ★ 这只是**兜底**：主路径上"会话正忙"时我们压根不会走到这里 ✓（见 dispatch.ts ✓）。
 */
const fleetSessionLock = {
  tryClaim(): (() => void) | undefined {
    if (sessionInFlight) return undefined
    sessionInFlight = true
    let released = false
    return () => {
      if (released) return
      released = true
      sessionInFlight = false
    }
  },
}

/**
 * ★ 下单幂等闸：同一艘船同一刻只允许一条在飞的 `order` ✓。
 *
 * 为什么需要（诚实说明）：`ask()` 有超时 ✓，而**超时之后那条 RPC 其实还在飞** ✓ ——
 * 于是"超时 → 走下一级 → 又下一条"就可能变成**同一艘船两条命令** ✗✓，
 * 正是 TAKEOVER.md 铁律要防的那种事 ✓。这道闸让它不可能发生 ✓。
 */
const ordersInFlight = new Set<string>()

let rawKind: 'reasoning' | 'text' | null = null

/** 收到一个 delta → 立刻追加（不做任何组织/截断 ✓✓） */
export function liveRaw(kind: 'reasoning' | 'text', delta: string): void {
  try {
    if (kind !== rawKind) {
      fs.appendFileSync(rawFile, `\n\n===== ${kind === 'reasoning' ? '思维过程 (reasoning)' : '正文 (output)'} =====\n`)
      rawKind = kind
    }
    fs.appendFileSync(rawFile, delta)
  } catch {
    /* 写不进去也不能影响决策 ✓ */
  }
}

/** 读回落盘的记录（DSH 重启后仍能看到历史 ✓） */
export function readDecisionFile(limit: number): DecisionRecord[] {
  try {
    const lines = fs.readFileSync(decisionFile, 'utf8').split('\n').filter((l) => l.trim() !== '')
    return lines.slice(-limit).map((l) => JSON.parse(l) as DecisionRecord)
  } catch {
    return []
  }
}

// ---------------------------------------------------------------------------
// ★ 下单回执（2026-10-17 ✓）：把 order 的 RPC 结果统一成 accepted/executed/error ✓
// ---------------------------------------------------------------------------

/** 从一次 `ask(peer,'order',…)` 的结果里取出结构化回执 ✓ */
function receiptOf(ord: { ok: boolean; data?: any; why?: string }, at: string): OrderReceipt {
  if (!ord.ok) {
    // ★★ 超时/断连 = **没拿到确认**，不是"被拒" ✗（order 是 fire-and-forget，游戏可能已经在跑 ✓）。
    //   `no response` = sweepTimeouts 超时 ✓；`connection lost` = 连接断开 ✓。
    //   两者都**不算失败** → 标 unconfirmed，绝不回投 ✓（见 OrderReceipt.unconfirmed ✓）。
    const why = ord.why ?? 'unknown'
    if (why === 'no response' || why === 'connection lost') {
      return {
        at, accepted: false, executed: false, unconfirmed: true,
        note: `order sent, no ack (${why}) — verify next round via list/ship busy+cargo`,
      }
    }
    // ★★ 游戏侧的**拒绝**（`ok=false`）也统一成 preflight 形状 ✓（2026-10-17）：
    //   老检查（NO_BUYER / HOLD_HAS_GOODS / PILOTED_SHIP / SHIP_NOT_AVAILABLE / BAD_REQUEST）
    //   回的是 `false, CODE, message` → 这里把 code 与 message 都留下来 ✓，
    //   于是**任何**被拒的单在回执里都能一眼看出"哪一项没过 + 原话" ✓✓。
    const code = typeof ord.data === 'string' && ord.data !== '' ? ord.data : undefined
    return {
      at, accepted: false, executed: false, error: why,
      preflight: code !== undefined
        ? { ok: false, code, reason: why }
        : { ok: false, reason: why },
    }
  }
  const d = (ord.data ?? {}) as Record<string, unknown>
  const accepted = d.accepted !== false
  const executed = d.executed !== false
  const note = typeof d.note === 'string' ? d.note : undefined
  // ★ 游戏侧回的风险（老版本游戏侧没有这个字段 → undefined ✓，不编 0 ✗）
  const risk = (d.risk !== null && typeof d.risk === 'object' && !Array.isArray(d.risk))
    ? d.risk as OrderRisk
    : undefined
  const isObj = (v: unknown): v is Record<string, unknown> =>
    v !== null && typeof v === 'object' && !Array.isArray(v)
  // ★★ 预检 / 实测 / 下单号（2026-10-17 ✓✓）：老游戏侧没有这些字段 → undefined ✓（不编 ✗）
  const preflight = isObj(d.preflight) ? (d.preflight as unknown as OrderPreflight) : undefined
  const verify = isObj(d.verify) ? (d.verify as unknown as OrderVerify) : undefined
  const orderId = (typeof d.orderId === 'number' || typeof d.orderId === 'string') ? d.orderId : undefined
  const extra: Partial<OrderReceipt> = {}
  if (preflight !== undefined) extra.preflight = preflight
  if (verify !== undefined) extra.verify = verify
  if (orderId !== undefined) extra.orderId = orderId
  if (accepted && executed) return { at, accepted: true, executed: true, note, risk, ...extra }
  return { at, accepted, executed, error: note ?? 'order not executed', note, risk, ...extra }
}

/** 这单算不算失败（被拒 / 未执行都算 ✗；**未确认不算** ✓ —— 见 OrderReceipt.unconfirmed ✓） */
function receiptFailed(r: OrderReceipt): boolean {
  if (r.unconfirmed === true) return false
  return !(r.accepted === true && r.executed === true)
}

/** 失败回执的**短标签**（进块里给决策者看的那句「被拒（…）/未执行（…）」✓） */
function receiptFailText(r: OrderReceipt): string {
  const err = String(r.error ?? 'unknown')
  const short = err.length > 120 ? err.slice(0, 120) + '…' : err
  return r.accepted ? `未执行（${short}）` : `被拒（${short}）`
}

// ---------------------------------------------------------------------------
// ★★ 取「实测（verify）」结论 —— 下单**之后**的事，只能**再问一次** ✓✓（2026-10-17）
// ---------------------------------------------------------------------------
//
// 为什么不能在下单那次 RPC 里拿到 ✗：order 是一次一问一答 ✓ ——
//   startCommand 在 6s 后才发、实测采样还要再等 ~6s ✓，答复早就回去了 ✗。
//   所以游戏侧把结论**存住**（link_in.lua 的 orderRecords ✓），这里用
//   `query{what:'orderStatus'}` 按 orderId（或 ship）取 ✓✓。
//
// ★ 三条硬规矩：
//   ① **绝不编**：拿不到就返回 undefined（回执里 verify 保持 pending / 缺省 ✓）；
//   ② **有界**：总预算内轮询，绝不无限等（游戏侧自己也会在两次采样后定稿 ✓）；
//   ③ **不炸**：任何异常/断连都只意味着"没拿到实测"，**不影响**已经下出去的单 ✓。

function askPeer(
  peer: Pick<RpcPeer, 'call'>,
  cmd: string,
  data: unknown,
  timeoutSec = 10,
): Promise<{ ok: boolean; data?: any; why?: string }> {
  return new Promise((resolve) => {
    let done = false
    const sent = peer.call(
      cmd,
      data,
      (ok, payload, why) => { if (!done) { done = true; resolve({ ok, data: payload, why }) } },
      timeoutSec,
    )
    if (!sent) resolve({ ok: false, why: 'not connected to the game' })
  })
}

export interface VerifyWaitOptions {
  /** 总共最多等多久（ms ✓；缺省 25s —— 够 startCommand 6s + 采样 6s + 一次重采 9s ✓） */
  budgetMs?: number
  /** 两次查询之间至少隔多久（ms ✓） */
  pollMs?: number
}

/**
 * ★★ 轮询 `orderStatus` 直到拿到**定稿**的实测结论 ✓✓（2026-10-17）
 *   返回 `undefined` = 老游戏侧 / 没有这单的记录 / 断连（**不编** ✓）；
 *   返回 `{pending:true,…}` = 预算到了还没定稿（**也不编成功** ✓）。
 */
export async function waitForOrderVerify(
  peer: Pick<RpcPeer, 'call'>,
  target: { orderId?: number | string; ship?: string },
  opts: VerifyWaitOptions = {},
): Promise<OrderVerify | undefined> {
  const budgetMs = opts.budgetMs ?? 25_000
  const pollMs = opts.pollMs ?? 2_000
  const startedAt = Date.now()
  let last: OrderVerify | undefined
  for (;;) {
    const r = await askPeer(peer, 'query', {
      what: 'orderStatus', orderId: target.orderId, ship: target.ship,
    }, 10)
    if (!r.ok) {
      // 老游戏侧（unknown what）/ 这单没有记录 / 断连 → **没有实测** ✓（回执里保持 pending ✓）
      return last
    }
    const d = (r.data ?? {}) as Record<string, unknown>
    const v = (d.verify !== null && typeof d.verify === 'object' && !Array.isArray(d.verify))
      ? d.verify as OrderVerify
      : undefined
    if (v === undefined) return last
    last = v
    if (v.pending !== true) return v
    const elapsed = Date.now() - startedAt
    if (elapsed >= budgetMs) return v
    const etaMs = typeof v.etaSeconds === 'number' && v.etaSeconds > 0 ? v.etaSeconds * 1000 : 0
    await new Promise((r2) => setTimeout(r2, Math.max(pollMs, etaMs)))
  }
}

/**
 * ★★ 游戏侧风险 → 一行短文案（2026-10-17 ✓✓）：`伏击 3%（基准 3%）`。
 *   · `known=false` → 明说「伏击未知 + 原因」✓ —— **绝不写 0%** ✗✓（0% 是"游戏说不会遇伏击"，两回事 ✓）；
 *   · Travel 的数是**整段航程**的（`riskKind` 里写着 ✓），这里不重复解释 ✓。
 */
export function riskText(r: OrderRisk | undefined | null): string | undefined {
  if (r === undefined || r === null) return undefined
  if (r.known !== true || typeof r.attackChance !== 'number') {
    const why = typeof r.unknownReason === 'string' && r.unknownReason !== ''
      ? `（${r.unknownReason.slice(0, 80)}）`
      : ''
    return `伏击未知${why}`
  }
  const pct = (v: number): string => `${Math.round(v * 1000) / 10}%`
  if (typeof r.baseAttackChance === 'number' && r.baseAttackChance !== r.attackChance) {
    return `伏击 ${pct(r.attackChance)}（基准 ${pct(r.baseAttackChance)}）`
  }
  return `伏击 ${pct(r.attackChance)}`
}

// ---------------------------------------------------------------------------
// ★ 失败回投的**上限与退避**（2026-10-17 主人要求 ✓✓）
// ---------------------------------------------------------------------------

/** 同一艘船同一失败原因的连续回投上限（3 次后停止并记"需人工介入" ✓） */
const REDELIVER_MAX = 3
/** 每次回投前的退避（让游戏先把上次失败的状态落稳 ✓） */
const REDELIVER_BACKOFF_MS = 1500
/** 回投的总时间预算（游戏侧 decide 超时 90s，留足余量 ✓） */
const REDELIVER_DECIDE_BUDGET_MS = 60_000
/** 同一艘船同一失败原因的连续回投计数（内存；防无限重投 ✓） */
const redeliverMemo = new Map<string, { reason: string; count: number; atMs: number }>()

/**
 * ★ 上一次决策的"你上一单的结果"（2026-10-17 补 ✓）：给下一轮任务块用 ✓。
 *   先查内存（最近的 ✓），没有再回落盘 ✓ —— 这样 DSH 重启后下一轮也能看到历史 ✓。
 */
/** 截断（回执一句话长度有预算 ✓） */
function shorten(s: string, n: number): string {
  const t = s.replace(/\s+/g, ' ').trim()
  return t.length > n ? t.slice(0, n) + '…' : t
}

/**
 * ★★ 预检结论 → 人话（2026-10-17 ✓✓）
 *   `预检 ✗ MIN_DISTANCE — This route is too short. …`（`ok=false` = **没下单** ✓）
 *   `ok=true` 返回 undefined（成功不需要废话 ✓；要看细节直接读 JSON ✓）。
 */
export function preflightText(pf: OrderPreflight | undefined | null): string | undefined {
  if (pf === undefined || pf === null) return undefined
  if (pf.ok === true) return undefined
  const code = typeof pf.code === 'string' && pf.code !== '' ? pf.code : 'PREFLIGHT'
  const reason = typeof pf.reason === 'string' && pf.reason !== '' ? shorten(pf.reason, 120) : ''
  return `预检 ✗ ${code}${reason !== '' ? ` — ${reason}` : ''}（**没有下单** ✗）`
}

/** 预检里"值得知道但不拦"的提示（卖不掉的货 / 被夹紧的时长 / 护航事实 ✓） */
export function preflightWarningText(pf: OrderPreflight | undefined | null): string | undefined {
  if (pf === undefined || pf === null) return undefined
  const ws = Array.isArray(pf.warnings) ? pf.warnings : []
  if (ws.length === 0) return undefined
  const codes = ws.map((w) => String(w.code ?? '')).filter((c) => c !== '')
  const bits: string[] = []
  if (codes.length > 0) bits.push(codes.join('/'))
  if (pf.sell !== undefined && typeof pf.sell.skippedKinds === 'number' && pf.sell.skippedKinds > 0) {
    const units = typeof pf.sell.skippedUnits === 'number' ? pf.sell.skippedUnits : undefined
    bits.push(`卖不掉 ${pf.sell.skippedKinds} 种${units !== undefined ? `/${units} 单位` : ''}已剔除`)
  }
  return bits.length > 0 ? `预检提示 ${bits.join('；')}` : undefined
}

/**
 * ★★ 实测结论 → 人话（2026-10-17 ✓✓）
 *
 *   `已到 ✓` / `在跑 ✓（货舱要跑完才结算）` / `货舱 -120 ✓` /
 *   `实测 ✗ 货舱没少、也不在后台运行 —— …`（**这就是"接了就完"的样子** ✓）
 *   `实测待回（~8s）` = 还没到采样点（**不是成功** ✗✓）
 */
export function verifyText(v: OrderVerify | undefined | null): string | undefined {
  if (v === undefined || v === null) return undefined
  if (v.pending === true) {
    const eta = typeof v.etaSeconds === 'number' && v.etaSeconds > 0 ? `~${Math.round(v.etaSeconds)}s 后` : '稍后'
    return `实测待回（${eta}）`
  }
  if (v.ok === false) {
    const why = typeof v.reason === 'string' && v.reason !== '' ? shorten(v.reason, 110) : '启动后状态没有变化'
    return `实测 ✗ —— ${why}`
  }
  const delta = typeof v.cargoUsedDelta === 'number' ? v.cargoUsedDelta : undefined
  switch (v.evidence) {
    case 'atDestination':
      return '已到 ✓'
    case 'moved':
      return '已移动 ✓'
    case 'busy': {
      const note = typeof v.note === 'string' ? v.note : ''
      if (note.includes('结算')) return '在跑 ✓（货舱要跑完才结算）'
      if (note.includes('onFinish') || note.includes('onRecall')) return '在跑 ✓（原版只在到达/召回时写坐标）'
      return '在跑 ✓'
    }
    case 'cargoUsedDecreased':
      return delta !== undefined ? `货舱 ${delta} ✓` : '货舱下降 ✓'
    case 'cargoUsedIncreased':
      return delta !== undefined ? `货舱 +${delta} ✓` : '货舱上升 ✓'
    case 'cargoChanged':
      return delta !== undefined ? `货舱变化 ${delta > 0 ? '+' : ''}${delta} ✓` : '货舱变化 ✓'
    default:
      return v.ok === true ? '实测 ✓' : undefined
  }
}

/** 货舱/位置的最短人话（prevResult 预算紧，只挑一条 ✓） */
function verifyOrPreflightText(r: OrderReceipt): string | undefined {
  const vt = verifyText(r.verify)
  const pf = preflightWarningText(r.preflight)
  if (vt !== undefined && pf !== undefined) return `${vt}${pf !== undefined ? `｜${pf}` : ''}`
  return vt ?? pf
}

/**
 * ★ 把一条决策记录渲染成「上一单的结果」一行（**带 decider 来源标签** ✓✓）。
 *   2026-10-17 主人要求：不许把单发/兜底的结论写成"你（会话）上一单" ✗ ——
 *   所以每一行都带 `[session]` / `[single-shot]` / `[rendezvous]` / `[fallbackNone]` ✓。
 *   ★ 2026-10-17 第二轮追加：**预检 / 实测**也要在这行里（这是主人"回执带结果"的落点 ✓✓）。
 *   导出给测试 ✓。
 */
export function renderPrevResult(rec: DecisionRecord): string | undefined {
  if (rec.answer === undefined) return undefined
  const action = rec.answer.action
  const p = rec.answer.params ?? {}
  const loc = typeof p.x === 'number' && typeof p.y === 'number' ? ` @(${p.x},${p.y})` : ''
  const decider = rec.decider ?? deciderOf(rec.source)
  const tag = decider !== undefined ? `[${decider}] ` : ''
  if (rec.receipt !== undefined) {
    if (rec.receipt.accepted && rec.receipt.executed) {
      const rt = riskText(rec.receipt.risk)
      const vt = verifyOrPreflightText(rec.receipt)
      const parts = [vt, rt].filter((s): s is string => s !== undefined && s !== '')
      // ★ 实测明确**没有成功证据**时**不许**写"成功" ✗✓（那就是主人今晚骂的那种假回执 ✓）
      const verdict = rec.receipt.verify?.ok === false ? '下单 ✓' : '成功 ✓'
      return `${tag}${action}${loc}：${verdict}${parts.length > 0 ? `｜${parts.join('｜')}` : ''}`
    }
    if (rec.receipt.unconfirmed === true) return `${tag}${action}${loc}：已发送，未确认（${rec.receipt.note ?? ''}）`
    // ★ 被拒：先看预检（"哪一项没过 + 原话" ✓），再看老式 error ✓
    const pt = preflightText(rec.receipt.preflight)
    if (pt !== undefined) return `${tag}${action}${loc}：${pt}`
    return `${tag}${action}${loc}：${receiptFailText(rec.receipt)}`
  }
  // ★ 旧记录没有 receipt → 从 orderResult 反推（向后兼容 ✓）
  const or = rec.orderResult as Record<string, unknown> | undefined
  if (or === undefined) return `${tag}${action}${loc}：结果未知`
  if (typeof or.failed === 'string') return `${tag}${action}${loc}：失败（${or.failed}）`
  if (or.dropped !== undefined) return `${tag}${action}${loc}：被幂等闸丢弃`
  return `${tag}${action}${loc}：成功 ✓`
}

function lastResultFor(ship: string): string | undefined {
  let last: DecisionRecord | undefined
  for (let i = decisionLog.length - 1; i >= 0; i--) {
    if (decisionLog[i].ship === ship) { last = decisionLog[i]; break }
  }
  if (last === undefined) {
    const file = readDecisionFile(200)
    for (let i = file.length - 1; i >= 0; i--) {
      if (file[i].ship === ship) { last = file[i]; break }
    }
  }
  if (last === undefined) return undefined
  return renderPrevResult(last)
}

/** 在飞的任务（增量 2）：ship -> 我们交给它的活，等它变空闲时结算 ✓ */
const pendingJobs = new Map<string, {
  atMs: number; action: string; goodName?: string; hours?: number; sector?: string
}>()

const DEFAULTS = {
  port: 8765,
  provider: 'deepseek-official',
  model: 'deepseek-flash',
  maxTokens: 8000,   // ★ 700 不够：思维链会占掉输出空间、正文被截断 → 解析失败 ✗
  temperature: 0.2,
}
/**
 * ★★★ 系统提示词现在**放在文件里**（2026-10-17 主人要求："prompt 能搞成单独的文件，让程序运行时读取"）
 *
 *   ① 用户覆盖: %AppData%\Avorion\moddata\copilot\prompt\system.md   ← 改它**不用重启 DSH** ✓✓
 *   ② 插件自带: <插件目录>\prompt\system.md                          ← 随仓库走 ✓
 *   ③ 编译兜底: src/prompt-default.ts（由 prompt/system.md 生成 ✓）
 *
 * 读法与替换都在 src/promptfile.ts ✓；机制段仍是单一来源（mod 仓库的 docs/game/mechanics-source.md ✓）。
 * ★ 顺带消掉了老坑：正文不再是 TS 模板字符串 → 再也不会因反引号把 SYSTEM_PROMPT 提前结束 ✗✓。
 */

interface Decision {
  action?: string
  /** ★ Trade 专用：模型选中的货物名（2026-10-16 补 ✓） */
  goodName?: string
  /** ★ Trade 专用：预付金（2026-10-17 补 ✓ —— 不传就由游戏自己猜 ✗，见 orderHint.deposit ✓） */
  deposit?: number
  x?: number
  y?: number
  /** ★ Trade 的框**形状**（2026-10-17 加 ✓）：原版合法形状只有 17x17 / 29x11 / 11x29 ✓，
   *  29x11 与 11x29 **不是正方形** ✗ → 必须能把两个边长分别传下去 ✓✓。
   *  tradePlan 的每个候选框都带 shape / sizeX / sizeY ✓（缺省则游戏侧按 size 取正方形 ✓）。 */
  sizeX?: number
  sizeY?: number
  /** ★ 正方形边长（2026-10-17 补 ✓）：回单只给 `size=15` 时也能正确建框 ✓。
   *   与 task.ts 的 validateAnswer 同款：`size` 与 `sizeX/sizeY` **都**解析并透传 ✗✓
   *   （游戏侧 onOrder 优先 sizeX+sizeY，其次 size —— 见 link_in.lua ✓）。
   *   此前这里**漏了 size** ✗ → 单发模型答 `size=15` 会被静默丢掉 → order 缺框被拒 ✗✓。 */
  size?: number
  duration?: number
  /** ★ Mine/Salvage 专用：安全模式（原版把伏击概率 ×0.1 ✓）—— 2026-10-17 补 ✓ */
  safeMode?: boolean
  /** ★ Sell 专用：要卖的货（2026-10-17 补 ✓）。
   *  ★ 不写就是"**一件都没勾**" ✗ —— 原版窗口那样，没勾货命令**起不来** ✓✓。
   *  形状 = 原版 sellcommand 的 config.goodsToSell：{ {goodName=…, amount=…} } ✓；
   *  也允许字符串 'all' = 整舱全卖 ✓ —— 而**游戏侧本来就会默认全卖** ✓
   *  （见 link_in.lua:483-516 ✓：没给 goodsToSell 就按船上实际货装 ✓），
   *  所以 'all' 我们**不回传**，直接让游戏那边兜底 ✓✓。 */
  goodsToSell?: Array<{ goodName: string; amount: number }> | 'all'
  escorts?: string[]
  reason?: string
  error?: string
}

/**
 * 从回复里取一个字段。容忍模型常见的自由发挥：
 * `choice=1` / `choice: 1` / `**choice=1**` / 全角冒号。逐行匹配，不跨行。
 * ★ 原样保留 ✓。
 */
function field(text: string, key: string): string | undefined {
  const match = new RegExp(`^\\s*\\**\\s*${key}\\s*[:=：]\\s*(.*)$`, 'im').exec(text)
  if (match === null) return undefined
  return match[1].replace(/\*+$/, '').trim()
}

/**
 * 从一个字段里取数字。坐标可能是 `-406` / `x = -406` / `(-406,73)`（括号里取第一个），
 * 所以**只取第一段数字**（含负号）✓ —— 原版那个 `opt1`/`选项3` 的容错也一并在里面 ✓。
 */
function parseNumberField(raw: string): number | undefined {
  const match = /-?\d+(?:\.\d+)?/.exec(raw)
  if (match === null) return undefined
  const value = Number(match[0])
  return Number.isFinite(value) ? value : undefined
}

/** 表示"没有"的几种写法，别当成船名。★ 原样保留 ✓ */
const NONE_WORDS = new Set(['', '-', 'none', 'null', 'n/a', 'na', '无', '没有', '否'])

/** ★ 单一来源：模型可以选的**全部**行动 ✓
 *  提示词（prompt/system.md 的输出格式）、这里（解析器）、以及 toAnswer 的默认白名单
 *  三处**必须一致** ✗ —— 2026-10-17 的 pro 审查抓到 `Scout` / `Sell` 漏在解析器与白名单之外 ✓，
 *  于是"计划里算得出来、却永远下不了单" ✗✓。test/actions-consistency.mjs 会守住这条 ✓。 */
export const ALL_ACTIONS = ['Mine', 'Salvage', 'Trade', 'Travel', 'Sell', 'Scout', 'Refine'] as const

/** 解析模型回复。解析不出 action 就算失败，交给游戏按错误处理 ✓ */
function parseDecision(text: string): Decision {
  const decision: Decision = {}

  const rawAction = field(text, 'action')
  if (rawAction !== undefined) {
    // 容忍 `action=Mine` / `action: mine` / `**action = Mine**` ✓
    const word = rawAction.replace(/[`*"'。，,]/g, '').trim()
    const known = [...ALL_ACTIONS, 'None']
    const hit = known.find((k) => k.toLowerCase() === word.toLowerCase())
    if (hit !== undefined) decision.action = hit
    else if (word.length > 0) decision.action = word          // 原样带出，由 toAnswer 判合法性 ✓
  }

  const gn = field(text, 'goodName')
  if (gn !== undefined && gn !== '') {
    // 去掉模型爱加的引号/星号；「none」之类当没写 ✓
    const cleaned = gn.replace(/[`*"']/g, '').trim()
    if (cleaned !== '' && !NONE_WORDS.has(cleaned.toLowerCase())) decision.goodName = cleaned
  }

  const x = field(text, 'x')
  if (x !== undefined) { const v = parseNumberField(x); if (v !== undefined) decision.x = v }
  const y = field(text, 'y')
  if (y !== undefined) { const v = parseNumberField(y); if (v !== undefined) decision.y = v }

  // ★★ Trade 的框形状（2026-10-17 补 ✓✓）：29x11 / 11x29 **不是正方形** ✗ →
  //   两个边长必须分别解析并转发 ✓（游戏侧 onOrder 认 data.sizeX/data.sizeY ✓）。
  const rawShape = field(text, 'shape')
  if (rawShape !== undefined) {
    const m = /(\d+)\s*[x×*]\s*(\d+)/i.exec(rawShape.replace(/[`*"']/g, ''))
    if (m !== null) {
      decision.sizeX = Number(m[1])
      decision.sizeY = Number(m[2])
    }
  }
  const sizeX = field(text, 'sizeX')
  if (sizeX !== undefined) { const v = parseNumberField(sizeX); if (v !== undefined && v > 0) decision.sizeX = v }
  const sizeY = field(text, 'sizeY')
  if (sizeY !== undefined) { const v = parseNumberField(sizeY); if (v !== undefined && v > 0) decision.sizeY = v }
  // ★ 正方形边长（与 task.ts 的 validateAnswer 对齐 ✓）：回单/正文只给 `size=15` 时也正确建框 ✓
  const size = field(text, 'size')
  if (size !== undefined) { const v = parseNumberField(size); if (v !== undefined && v > 0) decision.size = v }

  // ★ Trade 的预付金（2026-10-17 补 ✗→✓）：tradePlan 已经算好了最优预付金 ✓，
  //   但此前**根本没人把它读出来转发** ✗，于是游戏只能自己猜 ✓。
  const deposit = field(text, 'deposit')
  if (deposit !== undefined) { const v = parseNumberField(deposit); if (v !== undefined && v > 0) decision.deposit = v }

  const duration = field(text, 'duration')
  if (duration !== undefined) {
    const match = /(\d+(?:\.\d+)?)/.exec(duration)
    if (match !== null) decision.duration = Number(match[1])
  }

  const escorts = field(text, 'escorts')
  if (escorts !== undefined) {
    decision.escorts = escorts
      .split(/[,，、]/)
      .map((s) => s.trim())
      .filter((s) => !NONE_WORDS.has(s.toLowerCase()))
  }

  // ★ safeMode（Mine/Salvage ✓）：容忍 true/false、yes/no、1/0、是/否 ✓
  //   游戏侧 `order` 早就读 data.safeMode == true（见 net/link_in.lua 的 onOrder ✓），
  //   这里只要把它**解析出来并透传**，原版那条"伏击概率 ×0.1"的救援牌才真的能用 ✓✓
  const safeMode = field(text, 'safeMode')
  if (safeMode !== undefined) {
    const w = safeMode.replace(/[`*"'。，,]/g, '').trim().toLowerCase()
    if (['true', 'yes', 'y', '1', '是', '开', 'on'].includes(w)) decision.safeMode = true
    else if (['false', 'no', 'n', '0', '否', '关', 'off'].includes(w)) decision.safeMode = false
  }

  // ★ Sell 的选货（2026-10-17 补 ✓）：`goodsToSell=all` 或 `货名:数量,货名:数量` ✓
  const rawGoods = field(text, 'goodsToSell')
  if (rawGoods !== undefined) {
    const g = rawGoods.replace(/[`*"']/g, '').trim()
    if (/^all$/i.test(g) || g === '全部' || g === '全卖') decision.goodsToSell = 'all'
    else {
      const list: Array<{ goodName: string; amount: number }> = []
      for (const part of g.split(/[,，;；]/)) {
        const m = part.trim().match(/^(.+?)\s*[:：=]\s*(\d+(?:\.\d+)?)$/)
        if (m !== null) list.push({ goodName: m[1].trim(), amount: Number(m[2]) })
      }
      if (list.length > 0) decision.goodsToSell = list
      else live(`  ⚠ goodsToSell 解析不出"货名:数量"（原文: ${g}）—— 不回传，交给游戏侧"默认全卖" ✓`)
    }
  }

  const reason = field(text, 'reason')
  if (reason !== undefined && reason.length > 0) decision.reason = reason

  if (decision.action === undefined) {
    const seen = rawAction === undefined ? 'no action line' : JSON.stringify(rawAction)
    decision.error = `model reply contained no usable action (saw: ${seen})`
  }
  return decision
}

interface StreamResult {
  text: string
  reasoning: string
  failure?: string
  truncated: boolean
}

/** 跑一次模型调用，把正文与思维链分别收拢。★ 逐字段保留（猜不得 ✗） */
async function askModel(ctx: CopilotCtx, cfg: Required<Pick<CopilotConfig, 'provider' | 'model' | 'maxTokens' | 'temperature'>>, prompt: string, onDelta?: (kind: 'reasoning' | 'text', delta: string) => void, history?: string[]): Promise<StreamResult> {
  let text = ''
  let reasoning = ''
  let failure: string | undefined
  let truncated = false

  // ★ 历史消息**放在当前消息之前** ✓（只用现成的 createUserMessage ✓，不发明 API ✓）
  const messages = [
    ...(history ?? []).map((h) =>
      createUserMessage({ content: [{ type: 'text', text: h }], source: { kind: 'user' } })),
    createUserMessage({ content: [{ type: 'text', text: prompt }], source: { kind: 'user' } }),
  ]

  const stream = ctx.llm.stream({
    provider: cfg.provider,
    model: cfg.model,
    system: loadSystemPrompt().text,   // ★ 每次决策现读文件 ✓ 改完不用重启 ✓
    messages,
    maxTokens: cfg.maxTokens,
    temperature: cfg.temperature,
  })

  for await (const chunk of stream) {
    if (chunk.type === 'text-delta') {
      text += chunk.text
      if (onDelta !== undefined) onDelta('text', chunk.text)        // ★ 原文流 ✓✓
    } else if (chunk.type === 'reasoning-delta') {
      reasoning += chunk.text
      if (onDelta !== undefined) onDelta('reasoning', chunk.text)   // ★ 推理流 ✓✓
    } else if (chunk.type === 'finish') {
      // 失败与取消都以 finish 结束，细节在 reason 里，带稳定 code（NO_ADAPTER / AUTH / RATE_LIMIT ...）
      const reason = chunk.reason
      if (reason.kind === 'error' || reason.kind === 'aborted') {
        failure = reason.failure.code
          ? `${reason.failure.code}: ${reason.failure.message}`
          : reason.failure.message
      } else if (reason.kind === 'max-tokens') {
        truncated = true
      }
    }
  }

  return { text, reasoning, failure, truncated }
}

// ---------------------------------------------------------------------------
// 把请求交给模型，得到一条命令
// ---------------------------------------------------------------------------

/**
 * 游戏侧发来的 decide 请求。
 *
 * ★ 按主人 2026-10-14 定的架构：**游戏侧只带船名** ✓ ——
 * 数据由 DSH 自己用 RPC `query` 去拉 ✓✓（不推 ✗）。
 */
interface DecideRequest {
  ship?: string
  hasGoal?: boolean
}

interface DecideAnswer {
  action: string
  params: Record<string, unknown>
  reason?: string
  raw?: string
}

/** DSH 自己拉回来的事实（prompt 的输入 ✓） */
interface DecideFacts {
  ship: string
  goalText: string
  goalOptions: string[]
  card: unknown
  /** ★ 护航候选（判据=**原版**：与行动船距离 ≤ 护卫自己一跳航程 ✓；不要求同星系 ✓✓） */
  escortCandidates?: string[]
  /**
   * ★★ 这次**没取到**的事实 ✗✓（"取不到" 与 "确实没有" 是**两个完全不同的事实** ✗）
   *
   * ★ 2026-10-24 起这里**只可能**出现 `ship`（船卡）✓ ——
   *   legacy 计划（jobPlan / minePlan / salvagePlan / sellPlan / scoutPlan / tradePlan）
   *   **一个都不再预取** ✗（它们全在游戏主循环里**同步**扫 67~71 个区域并自排序 ✓，
   *   真机实测 jobPlan 828/884 ms、scoutPlan 1321 ms、sellPlan 8248 ms、
   *   tradePlan 12633~15415 ms ✓ —— 按接口原子化的规矩，**选哪个框是决策者的事** ✓）。
   */
  planFetchFailures?: Array<{ what: string; why: string }>
}

// ★★ 2026-10-24：`compactJobPlan` **已移除** ✗ —— 它只服务"把游戏侧 jobPlan 的巨型
//   返回裁成喂模型的那份"✓，而 jobPlan 本身已不再被预取 ✓（主人原话：
//   「去掉吧，是旧的那套 JOB 之前直接扫区域，而非你去决策扫是吧」✓✓）。
//   正确路径：决策者自己 `predict`（≤24 框）/ `tradeEvaluate` 点名，游戏只算**它点的那几个框** ✓。

/** 把模型的正文解析成 action + 坐标（这才是要回给游戏的答案 ✓） */
function toAnswer(decision: Decision, f: DecideFacts, raw: string): DecideAnswer | string {
  if (decision.error !== undefined) return decision.error

  const action = decision.action ?? 'None'
  const allowed = f.goalOptions.length > 0 ? f.goalOptions : [...ALL_ACTIONS]

  // "None" 永远合法（什么都不做 ✓）
  if (action !== 'None' && !allowed.includes(action)) {
    return `model picked '${action}' which is not allowed here (allowed: ${allowed.join(', ')}, plus None)`
  }

  const params: Record<string, unknown> = {}
  if (decision.goodName !== undefined) params.goodName = decision.goodName   // ★ Trade 的选货 ✓
  if (decision.deposit !== undefined) params.deposit = decision.deposit      // ★ Trade 的预付金 ✓
  if (decision.x !== undefined) params.x = decision.x
  if (decision.y !== undefined) params.y = decision.y
  // ★ Trade 的框形状（两个边长分别传 ✓ —— 29x11 / 11x29 不是正方形 ✗）
  if (decision.sizeX !== undefined && decision.sizeX > 0) params.sizeX = decision.sizeX
  if (decision.sizeY !== undefined && decision.sizeY > 0) params.sizeY = decision.sizeY
  // ★ 正方形边长（与 task.ts 的 validateAnswer 对齐 ✓）：游戏侧 onOrder 优先 sizeX+sizeY、其次 size ✓
  if (decision.size !== undefined && decision.size > 0) params.size = decision.size
  if (decision.duration !== undefined) params.duration = decision.duration
  if (decision.safeMode !== undefined) params.safeMode = decision.safeMode    // ★ Mine/Salvage ✓
  // ★ Sell 的选货（2026-10-17 补 ✓）：游戏侧读 data.goodsToSell ✓（link_in.lua:483-516 ✓）。
  //   'all' **不回传** ✗ —— 游戏侧不给它就是"默认全卖" ✓，回传字符串反而会被它按表判空 ✓。
  if (decision.goodsToSell !== undefined && decision.goodsToSell !== 'all') {
    params.goodsToSell = decision.goodsToSell
  }
  if (decision.escorts !== undefined && decision.escorts.length > 0) {
    // ★★ 清洗（2026-10-16 实测的坑 ✗）：模型写 `escorts=` 空行时，
    //   解析会把**下一行**当成护航名 ✓✓（实测收到 ["deposit=1000000"] ✗）。
    //   → 只保留**护航候选名单里**的名字 ✓；名字不认识就丢掉并记一笔 ✓。
    const known = f.escortCandidates ?? []
    const clean = decision.escorts.filter((s) => known.includes(s))
    const dropped = decision.escorts.filter((s) => !known.includes(s))
    if (dropped.length > 0) live(`  ⚠ 丢弃无法护航的名字: ${dropped.join(", ")}`)
    if (clean.length > 0) params.escorts = clean
  }

  return { action, params, reason: decision.reason, raw }
}

// ---------------------------------------------------------------------------
// ★★ 护航 rendezvous（2026-10-17 起 ✓ / 2026-10-24 **接回来** ✓✓，主人原话：「接上吧」）
// ---------------------------------------------------------------------------
//
// ★★ 2026-10-24 的**新判据来源**（★ 绝不回退到自扫描 ✗✓）：
//   ① 风险数字 = **决策者自己点名拿到的**那一个 ✓：
//        · `fleet_query {what:"predict"}` 的 `risk.baseAttackChance` ✓
//        · `fleet_order` 回执的 `risk` ✓（与 predict 同一份代码、逐字相同 ✓）
//      —— 这两个由 `tools.ts` 在**工具调用处**记进 `RiskObservation` ✓（见下面 ✓）。
//   ② 「名单里有没有空闲战斗舰」= `list`（索引级 ✓）→ `ship brief` 的
//      `armedTurrets` / `canFight` ✓（那才是"能不能打"的事实 ✓，不是名字 ✗）。
//   ③ 判「缺不缺护航」= 下面 `escortNeedFor` 的**阈值语义** ✓
//      （闸门 10% + 一艘护航 ×0.75，2026-10-17 定的那条，一个数都没改 ✓）。
//   ★ 全程 **0 次 `*Plan`** ✗✓（`test/rendezvous.mjs` 有断言钉住 ✓）。
//
// ★★ 触发时机**也变了** ✗→✓：
//   · **不再**在「单发兜底」里触发 ✗（那条路只该给 None ✓，而且原来靠 legacy tradePlan
//     的 `recommendation === null` + `areaRanking` 判 —— tradePlan 的预取已删 ✓）。
//   · 决策者**自己派单**时本来就够用 ✓：`fleet_order` 回执里已有
//     `ESCORT_OK` / `ESCORT_TOO_FAR` / `ESCORT_UNARMED` ✓✓。
//   · 本段新增的价值只有一件 ✓：**她量完风险后**，插件主动算出「这单缺护航、且名单里
//     有可用船」，并把它写进**下一轮投递块** ✓✓（`buildEscortHint` ✓）。
//     ★ **只告知** ✓ —— 绝不替她下单 ✗✓。
//
// 下面这两个**纯函数**保留 ✓（`test/rendezvous.mjs` 逐条钉着它们的硬规矩 ✓）：
//   `escortNeedOf` 现在是**形状适配器** ✓（把 legacy plan 形状抽成数字，交给
//   `escortNeedFor` 判 ✓ —— 阈值语义只剩一份 ✓）。
//
// 历史（原文保留，说明"为什么当初这么设计"✓）：
//   主人的原话：
//     「当一艘船需要护卫时，可以把空闲战斗舰调到目标舰星系，再发起指令。」
//
//   游戏规则（硬，2026-10-17 更正 ✗→✓）：护航只要求**在自己一跳航程之内** ✓（**不要求同星区** ✓，
//     不能穿裂隙的还要与行动船同处屏障环一侧 ✓）。所以"把船调到同一星区/附近"仍是最稳的做法 ✓，
//     但**不是唯一**可行的 ✓ —— 别再把"必须同星系"当硬规则 ✗。
//   但 Travel 是**异步**的：船离开后要好一阵才到 ✓，而"目标星系没有护航"这个条件
//   在它到达前**一直成立** ✗ → 每轮 decide 都会想再派一艘 ✓。
//   当初靠下面这张**记忆表**把重复派压住 ✓（同一艘行动船 30 分钟内只派一次 ✓）。

/** 风险硬门槛（与游戏侧 copilottrade 的 MAX_ATTACK_CHANCE 同值 ✓） */
const ESCORT_RISK_GATE = 0.10

/** 一艘"自身够硬"的护航大约把伏击概率乘这个系数（与 SYSTEM_PROMPT 的说法一致 ✓） */
// ★ 这是**我们自己的估计** ✗，不是原版机制 ✓（2026-10-17 pro 审查 #4 指出 ✓）。
//   优先用原版：候选里若带 attackChanceWithEscorts（游戏侧按护航的 dps/hp 算的 ✓），就用它 ✓；
//   只有它缺失时才退到这个经验系数 ✓（流水里会说明是估计 ✓）。
const ESCORT_RISK_FACTOR = 0.75

/** 船名像不像战斗舰（主人点名的例子：Combat / Raven ✓；实测名单里就有 Combat-00001 ✓） */
const COMBAT_NAME_HINTS = [
  'combat', 'raven', 'fighter', 'gunship', 'warship', 'military', 'corvette', 'frigate',
  'destroyer', 'cruiser', 'battleship', 'sentinel', 'guard', 'escort',
  '战', '护卫', '炮', '巡洋', '驱逐', '武',
]

/** 从 JSON 来的数字（可能是 number / string / nil ✓ —— 绝不让 undefined 变成 NaN ✗） */
function toNum(value: unknown): number | undefined {
  if (typeof value === 'number') return Number.isFinite(value) ? value : undefined
  if (typeof value === 'string' && value !== '') {
    const n = Number(value)
    return Number.isFinite(n) ? n : undefined
  }
  return undefined
}

/** 概率 → 百分比文字（拿不到就写 ?） */
function fmtPct(value: number | undefined): string {
  return value === undefined ? '?' : `${(value * 100).toFixed(1)}%`
}

/** 船名里命中几个战斗词 ✓ */
function combatNameHits(name: string): number {
  const lower = name.toLowerCase()
  let hits = 0
  for (const hint of COMBAT_NAME_HINTS) if (lower.includes(hint)) hits += 1
  return hits
}

/** `escortNeedOf` 的结论 ✓ */
export interface EscortNeed {
  needed: boolean
  why: string
  route?: string
  risk?: number
  riskWithEscort?: number
  gate?: number
}

/**
 * ★★ 一份「决策者点名的风险数字」—— 2026-10-24 新判据的**唯一输入** ✓✓
 *
 * 与 legacy `tradePlan` 的形状**彻底无关** ✗✓：这里只有**游戏算出来的数** ✓
 * （`predict` 的 `risk` / `fleet_order` 回执的 `risk` —— 同一份代码、逐字相同 ✓）。
 */
export interface RiskFacts {
  /** 行动船 ✓（只进措辞 ✓） */
  ship: string
  /** 路线名 / 商品名 / 框描述 —— 只进措辞 ✓（**不参与判断** ✓） */
  label?: string
  /** ★ 判断只看**基准**伏击概率（主人钦定口径 ✓）；缺 = 没数 ✗ */
  baseAttackChance?: number
  /** `baseAttackChance` 缺失时的兜底（Travel 只有一个数 ✓） */
  attackChance?: number
  /** 游戏说算出来了没有 ✓（`false` / 缺 = **没有数字**，绝不填 0 ✗） */
  known?: boolean
  /** 闸门（缺省 0.10 ✓ 与游戏侧 MAX_ATTACK_CHANCE 同值 ✓） */
  gate?: number
  /** 游戏侧算好的「带一艘护航」概率（有就用原版 ✓ 没有才退经验系数 ✓） */
  withEscortsRisk?: number
  /** 行动船**同星系**已有的可用护航候选 ✓（有 = 不用再派人 ✓） */
  sameSectorEscorts?: string[]
}

/**
 * ★★★ 判「这一单**真的缺一艘护航**吗」—— **纯数字**判据 ✓✓（2026-10-24 ✓）
 *
 * ★ 阈值语义**原样沿用** `escortNeedOf`（2026-10-17 定的 ✓，一条都没改 ✗）：
 *   ① 没有数字（游戏没算出来）→ 不判 ✓（绝不把"未知"当 0% ✗）
 *   ② 本星系已有护航候选        → 不需要派人 ✓（现有流程会处理 ✓）
 *   ③ 风险本来就在闸门内        → 不需要 ✓
 *   ④ 加一艘护航仍压不到闸门内  → 不派（派了也压不下来，别白跑 ✓）
 *   ⑤ 其余（风险超闸门、加一艘能压进去）→ **缺护航** ✓
 *
 * ★ 它**不发**任何查询 ✓（纯函数 ✓ —— `test/rendezvous.mjs` 钉着"不发 `*Plan`" ✓）。
 */
export function escortNeedFor(f: RiskFacts): EscortNeed {
  const gate = f.gate ?? ESCORT_RISK_GATE
  const risk = f.baseAttackChance ?? f.attackChance
  if (f.known === false || risk === undefined) {
    return { needed: false, why: '没有可用的风险数字（游戏没算出来 ✓ 不填 0 ✗）', gate }
  }
  const locals = f.sameSectorEscorts ?? []
  if (locals.length > 0) {
    return { needed: false, why: `本星系已有护航候选 ${locals.join(',')}`, gate }
  }
  const label = f.label !== undefined && f.label !== '' ? `「${f.label}」` : ''
  if (risk <= gate) {
    return { needed: false, why: `${label}伏击概率 ${fmtPct(risk)} 本来就在门槛 ${fmtPct(gate)} 内`, risk, gate }
  }
  // ★ 优先用**游戏侧**算好的带护航概率 ✓（那是原版机制 ✓）；它缺失时才退到经验系数 ✓
  const withEscort = f.withEscortsRisk ?? (risk * ESCORT_RISK_FACTOR)
  if (withEscort > gate) {
    return {
      needed: false,
      why: `${label}伏击概率 ${fmtPct(risk)}，加一艘护航估约 ${fmtPct(withEscort)}` +
        ` 仍高于门槛 ${fmtPct(gate)} —— 派了也压不下来，不派 ✓`,
      risk, riskWithEscort: withEscort, gate,
    }
  }
  return {
    needed: true,
    why: `${label}伏击概率 ${fmtPct(risk)} > 门槛 ${fmtPct(gate)}，` +
      `加一艘护航估约 ${fmtPct(withEscort)} ✓`,
    route: f.label, risk, riskWithEscort: withEscort, gate,
  }
}

/**
 * ★ 判断"这一轮的 tradePlan 是不是**真的缺一艘护航**" ✓
 *
 * ★★ 2026-10-24：它现在只是**形状适配器** ✗→✓ —— 把 legacy plan 形状抽成数字，
 *   交给 `escortNeedFor` 判 ✓（**阈值语义只剩一份** ✓，不再有第二套闸门 ✓）。
 *   生产路径**已经不用它**了 ✓（`buildEscortHint` 走的是数字入口 ✓）；
 *   留着是为了钉住 2026-10-17 定下的那套语义（`test/rendezvous.mjs` ③~⑨ ✓）。
 *
 * 只**读**游戏给的字段，不改扫描逻辑 ✓：
 *   recommendation 非空        → 已经有能出海的推荐 → 不需要 ✓
 *   一条路线都没有              → 护航只降伏击概率，救不了"没货可运" ✗ → 不需要 ✓
 *   最好候选 ×0.75 仍超门槛     → 派过去也压不下来 ✗ → 不派（诚实说明 ✓，别白跑一趟 ✓）
 *
 * 兼容两种形状：新的多区域 areaRanking ✓、老的 candidates ✓。
 */
export function escortNeedOf(plan: unknown, sameSectorEscorts: string[]): EscortNeed {
  if (plan === null || plan === undefined || typeof plan !== 'object') {
    return { needed: false, why: '没有 tradePlan 数据' }
  }
  const p = plan as Record<string, unknown>
  if (p.recommendation !== null && p.recommendation !== undefined) {
    return { needed: false, why: 'tradePlan 已有能出海的推荐' }
  }

  const scan = (p.scan ?? {}) as Record<string, unknown>
  const gate = toNum(scan.maxAttackChance) ?? ESCORT_RISK_GATE

  // 收集"有路线、但过不了闸门"的候选 ✓（新形状优先，老形状兜底 ✓）
  const risky: { name: string; risk: number; profit: number; withEscorts?: number }[] = []
  const ranking = Array.isArray(p.areaRanking) ? (p.areaRanking as Record<string, unknown>[]) : []
  for (const entry of ranking) {
    const route = typeof entry.bestRouteName === 'string' ? entry.bestRouteName : ''
    if (route === '' || entry.acceptable === true) continue
    const base = toNum(entry.attackChanceBase)
    const risk = toNum(entry.attackChance) ?? base
    if (risk === undefined) continue
    risky.push({ name: route, risk, profit: toNum(entry.netProfitLow) ?? 0 })
  }
  if (risky.length === 0) {
    const cands = Array.isArray(p.candidates) ? (p.candidates as Record<string, unknown>[]) : []
    for (const c of cands) {
      const route = typeof c.name === 'string' ? c.name : ''
      const risk = toNum(c.attackChanceEffective) ?? toNum(c.attackChance)
      if (route === '' || risk === undefined) continue
      risky.push({ name: route, risk, profit: toNum(c.netProfitLow) ?? 0, withEscorts: toNum(c.attackChanceWithEscorts) })
    }
  }
  if (risky.length === 0) {
    const warn = typeof p.riskWarning === 'string' ? p.riskWarning : ''
    return {
      needed: false,
      why: warn !== '' ? `没有路线可护航（${warn.slice(0, 80)}）` : '这个区域没有可用贸易路线',
      gate,
    }
  }

  risky.sort((a, b) => b.profit - a.profit)
  const best = risky[0]
  return escortNeedFor({
    ship: typeof p.ship === 'string' ? p.ship : '',
    label: best.name,
    baseAttackChance: best.risk,
    known: true,
    gate,
    withEscortsRisk: best.withEscorts,
    sameSectorEscorts,
  })
}

/** 挑出来的护航船 ✓ */
export interface EscortPick {
  name: string
  sector: { x: number; y: number }
  turretCount?: number
  basis: string
}

/**
 * ★ 从舰队快照里挑一艘**别的星系**的护航 ✓
 *
 * 硬规矩（一条都不能松 ✗）：
 *   · 绝不挑玩家正在开的那条（`fd.piloted` ✓ —— 本项目的老规矩 ✓）
 *   · 绝不挑行动船自己 ✓
 *   · 跳过忙船 ✓（后台命令是异步的，忙船派不动 ✓）
 *   · 必须有船长 ✓（没船长接不了后台命令 ✓）
 *   · 必须在**别的**星系 ✓（同星系就直接当候选了，不用旅行 ✓）
 *   · "像战斗舰"：**名字命中战斗词** 或 **有炮塔** ✓ —— 只看名字太窄 ✗
 *     （实测有些船 turretCount 探针读不到 ✗，只认名字会把能用的船全漏掉 ✓）
 *
 * 打分：名字命中数 ×10 + 炮塔数（封顶 10）✓ —— 名字最重（主人点名 Combat/Raven ✓）。
 * 并列时按船名排序 → **确定性** ✓（同一局不会一会儿挑 A 一会儿挑 B ✓）。
 */
export function pickRendezvousEscort(
  ships: Record<string, unknown>[],
  actionShip: string,
  pilotedName: string,
  targetSector: { x?: number; y?: number },
): EscortPick | null {
  let best: (EscortPick & { score: number }) | null = null
  for (const s of ships) {
    const name = typeof s.name === 'string' ? s.name : ''
    if (name === '' || name === actionShip || name === pilotedName) continue
    if (s.busy === true) continue
    if (s.hasCaptain !== true) continue
    const sec = (s.sector ?? {}) as { x?: unknown; y?: unknown }
    const sx = toNum(sec.x)
    const sy = toNum(sec.y)
    if (sx === undefined || sy === undefined) continue
    if (sx === targetSector.x && sy === targetSector.y) continue
    const turrets = toNum(s.turretCount)
    const hits = combatNameHits(name)
    if (hits === 0 && !(turrets !== undefined && turrets > 0)) continue
    const score = hits * 10 + Math.min(turrets ?? 0, 10)
    const basis = `名字命中战斗词 ${hits} 个 / 炮塔 ${turrets ?? '?'}`
    if (best === null || score > best.score || (score === best.score && name < best.name)) {
      best = { name, sector: { x: sx, y: sy }, turretCount: turrets, basis, score }
    }
  }
  if (best === null) return null
  return { name: best.name, sector: best.sector, turretCount: best.turretCount, basis: best.basis }
}

// ★★ 2026-10-24：`RENDEZVOUS_MEMO_MS` / `rendezvousMemo` **仍然不回来** ✗✓ ——
//   它们服务的是"插件自己决定派哪艘船过去"那条路 ✓，而现在插件**只告知** ✓（不替她下单 ✗）。
//   取代它的是下面 `RiskObservation` 的**有效期**（15 分钟 ✓）。

// ---------------------------------------------------------------------------
// ★★ 护航建议（2026-10-24 接回来 ✓）—— **只告知** ✓ 不替她下单 ✗
// ---------------------------------------------------------------------------
//
// 主人原话：「接上吧」✓ —— 接在「**决策者点名后的数字**」上 ✓，绝不回退到自扫描 ✗✓。
// 数据只有两样 ✓：
//   ① 她自己量到的风险数字（`predict` / `fleet_order` 回执 ✓ —— 同一份代码 ✓）
//   ② `list` → `ship{brief:true}` 的**空闲战斗舰**（`armedTurrets` / `canFight` ✓）
// 查询次数 ✓：不需要护航 → **0 次** ✓；需要时 = 1 次 `list` + 最多 2 次 `ship`
//   ★ 一次 `*Plan` 都没有 ✗✓（`test/rendezvous.mjs` 有断言钉住 ✓）。
// 写进哪 ✓：**下一轮投递块**（`task.ts` 的 `escortHint` ✓）—— 只告知，派不派由她定 ✓✓。

/** 一次「她点名的风险数字」（`predict` / `fleet_order` 回执 ✓）—— 护航建议就从它算 ✓ */
export interface RiskObservation {
  /** 观察时刻（ms ✓）；超过 TTL 就不再用 ✓ */
  atMs: number
  /** 行动船 ✓ */
  ship: string
  action?: string
  /** 游戏算出来的**基准**概率 ✓（`known=false` 时没有这个数 ✓） */
  baseAttackChance?: number
  attackChance?: number
  /** 游戏说算出来了没有 ✓（false = 没有数字，绝不填 0 ✗） */
  known: boolean
  /** 下单时**已经带了**护航 → 这件事做过了，不再建议 ✓ */
  escortsGiven?: string[]
  /** 闸门（预测/回执给的那一个 ✓） */
  gate?: number
  /** 来源：`predict` = 她自己量的 ✓；`order` = 下单回执 ✓ */
  source: 'predict' | 'order'
}

/** 一次原子查询（与 `tools.ts` 的 `ask(peer,'query',…)` 同形 ✓）—— 测试可注入桩 ✓ */
export type AtomQuery = (what: string, params: Record<string, unknown>) =>
  Promise<{ ok: boolean; data?: unknown; why?: string }>

export interface EscortHintOptions {
  nowMs?: number
  /** 观察的有效期（缺省 15 分钟 ✓ —— 她量完通常马上处理这一单 ✓） */
  ttlMs?: number
  /** 最多查几艘船的 brief（缺省 2 ✓ —— 这是投递路径上的 RPC，要省 ✓） */
  maxBriefLookups?: number
  /** 总预算（ms）：超了就不再查 ✓（**绝不**为这一行拖慢投递 ✗） */
  budgetMs?: number
}

/** 观察的有效期 ✓（15 分钟：够她把这一单处理完 ✓，又不会拿半小时前的数装懂 ✗） */
export const ESCORT_OBS_TTL_MS = 15 * 60_000

/** 一行护航建议最多多少字节（与 task.ts 的 320 预算对齐 ✓ —— 那边还会再挡一次 ✓） */
const ESCORT_HINT_MAX_BYTES = 260

/** 按 UTF-8 字节裁（不切断半个字符 ✓）；裁了就加省略号 ✓ */
function clipHintText(s: string, maxBytes: number): string {
  if (Buffer.byteLength(s, 'utf8') <= maxBytes) return s
  let cut = s
  while (cut !== '' && Buffer.byteLength(cut + '…', 'utf8') > maxBytes) cut = cut.slice(0, -1)
  return cut === '' ? '' : cut + '…'
}

/**
 * ★★★ 算出「这单缺护航、且名单里有可用船」那一行 ✓✓（2026-10-24 接回来 ✓）
 *
 * 返回 `undefined` = **nothing to say** ✓（不需要护航 / 没数字 / 名单里没人 / 超预算 ✓）
 *   —— 绝不返回"猜的"建议 ✗✓。
 *
 * 查询序列（★ 全程**不发任何 `*Plan`** ✗✓）：
 *   · **0 次**：数字不在闸门之上（或本来就在闸门内 / 加一艘也压不下来 ✓）
 *   · **1 次**：`list`（索引级 ✓）—— 顺带看"同星系已有护航候选"（有 = 现有流程就够 ✓）
 *   · **1 + N 次**：`ship{ship, brief:true}`（N ≤ maxBriefLookups，缺省 2 ✓）
 *
 * ★ 判据/阈值全部来自 `escortNeedFor` ✓（2026-10-17 定的那条语义 ✓ **不新造阈值** ✗）。
 */
export async function buildEscortHint(
  query: AtomQuery,
  obs: RiskObservation,
  opts: EscortHintOptions = {},
): Promise<string | undefined> {
  const now = opts.nowMs ?? Date.now()
  if (now - obs.atMs > (opts.ttlMs ?? ESCORT_OBS_TTL_MS)) return undefined          // 过期的数 ✓
  if (obs.escortsGiven !== undefined && obs.escortsGiven.length > 0) return undefined  // 已经带了 ✓

  // ① 先**纯数字**判一次 ✓（不需要护航 → **0 次查询** ✓✓）
  const pre = escortNeedFor({
    ship: obs.ship, baseAttackChance: obs.baseAttackChance, attackChance: obs.attackChance,
    known: obs.known, gate: obs.gate,
  })
  if (!pre.needed) return undefined

  const deadline = Date.now() + (opts.budgetMs ?? 2_500)
  const late = (): boolean => Date.now() > deadline

  // ② 名单（索引级 ✓ 不扫星区、不算预测 ✓）
  const lr = await query('list', {})
  if (!lr.ok) return undefined
  const listData = (lr.data ?? {}) as Record<string, unknown>
  const ships = Array.isArray(listData.ships) ? (listData.ships as Record<string, unknown>[]) : []
  if (ships.length === 0) return undefined

  const me = ships.find((s) => s.name === obs.ship)
  const mySec = (me?.sector ?? {}) as { x?: unknown; y?: unknown }
  const sameSector: string[] = []
  const pool: Record<string, unknown>[] = []
  for (const s of ships) {
    const nm = typeof s.name === 'string' ? s.name : ''
    if (nm === '' || nm === obs.ship) continue
    if (s.busy === true) continue                 // 忙船派不动 ✓
    if (s.hasCaptain === false) continue          // 没船长接不了后台命令 ✓（nil = 未知，不排除 ✓）
    const sec = (s.sector ?? {}) as { x?: unknown; y?: unknown }
    if (me !== undefined && sec.x === mySec.x && sec.y === mySec.y) sameSector.push(nm)
    else pool.push(s)
  }
  // ②b 用**同一套判据**再确认一次 ✓（同星系有可用护航 = 现有流程就够 ✓ —— 原语义 ✓）
  const need = escortNeedFor({
    ship: obs.ship, baseAttackChance: obs.baseAttackChance, attackChance: obs.attackChance,
    known: obs.known, gate: obs.gate, sameSectorEscorts: sameSector,
  })
  if (!need.needed) return undefined

  // ③ 「名单里有没有空闲战斗舰」—— 名字像战斗舰的优先 ✓（主人点名 Combat/Raven ✓），
  //    再最多查 N 艘 brief ✓（`armedTurrets` / `canFight` 才是"能不能打"的事实 ✓ 不是名字 ✗）
  pool.sort((a, b) => {
    const an = combatNameHits(String(a.name))
    const bn = combatNameHits(String(b.name))
    if (bn !== an) return bn - an
    return String(a.name) < String(b.name) ? -1 : 1
  })
  const limit = Math.max(1, opts.maxBriefLookups ?? 2)
  const fighters: string[] = []
  let unreadable = 0
  let lookups = 0
  for (const s of pool) {
    if (fighters.length >= 2 || lookups >= limit || late()) break
    const nm = String(s.name)
    lookups += 1
    const br = await query('ship', { ship: nm, brief: true })
    if (!br.ok) continue
    const card = (br.data ?? {}) as Record<string, unknown>
    if (card.canFight === true) { fighters.push(nm); continue }
    const armed = toNum(card.armedTurrets)
    if (armed !== undefined && armed > 0) { fighters.push(nm); continue }
    // ★ 读到了武器、且都不是"能打" → 确实不能打 ✓；读不到 → 只计数，**不猜** ✓
    if (card.canFightKnown !== true && card.armedTurretsKnown !== true) unreadable += 1
  }

  const head = `你上次量的这单伏击 ${fmtPct(need.risk)} > 闸门 ${fmtPct(need.gate)}` +
    `（加一艘约 ${fmtPct(need.riskWithEscort)} ✓）`
  if (fighters.length > 0) {
    return clipHintText(
      `${head} —— 名单里有空闲战斗舰 ${fighters.join(' / ')}` +
      `（要生效：订单带 escorts=，且它在自己一跳航程内 ✓）`, ESCORT_HINT_MAX_BYTES)
  }
  const tail = unreadable > 0
    ? `名单里没读到能打的空闲船（${unreadable} 艘武器未知 —— 别当它能打 ✓）`
    : '名单里没有空闲战斗舰（别硬派 ✗）'
  return clipHintText(`${head} —— ${tail}`, ESCORT_HINT_MAX_BYTES)
}

// ---------------------------------------------------------------------------
// 小数：单发路径被判成"没有动作行"时要重试一次 ✓（2026-10-17 ✓）
//
// 实机事故（`decisions.live.log` 16:18:10 逐字）：**正文一个动作行都没吐** ✗
//   （`BAD_MODEL_REPLY ... saw: no action line`）→ 于是整轮决策被丢弃 ✓、货也没卖成 ✓✓。
// 规矩：**同一批事实**再来一次 ✓、只要求"答案行在前、之后再写理由" ✓、
//   ★ **只此一次** ✗（不循环 ✓）、**不重取数据** ✗（慢且游戏状态可能已变 ✓）。
// ---------------------------------------------------------------------------

/** 单发路径的"重试一次"补语（进提示词末尾 ✓） */
const SINGLE_SHOT_RETRY_HINT =
  '\n\n★ 你上一次**没有输出任何 action 行**。\n'
  + '请把结论行写在**第一行** ✓：action=… 之后再写理由 ✓；'
  + 'reason 可以留空 ✓。一行一个字段，从 action= 开始。'

/** 报告里用的失败码（由 `apply` 里的 decide 处理器回给游戏 ✓） */
type SingleShotFailCode = 'MODEL_ERROR' | 'MODEL_FAILED' | 'BAD_MODEL_REPLY'

/** 单发那一路的产物 ✓（成功或失败**都**把"要不要重试"告诉调用方 ✓） */
interface SingleShotCall {
  text: string
  reasoning: string
  truncated: boolean
  failure?: string
  /** ★ 只有一种情况要让调用方再问一次：**完全没有动作行** ✓ */
  retryHint?: string
  /** ★ 重试也没成时，把"两轮为什么都不行"写在这里 ✓（`failure` 会照着它回报游戏 ✓） */
  why?: string
}

/** 单发路径的失败（带稳定 code，回给游戏侧做日志 ✓） */
interface SingleShotFailure {
  ok: false
  code: SingleShotFailCode
  message: string
  why: string
  text?: string
}

// ---------------------------------------------------------------------------
// 插件入口：把 RPC 接起来
// ---------------------------------------------------------------------------

export function apply(ctx: CopilotCtx, config: CopilotConfig = {}): void {
  // ★★ 待命裁定是**运行时状态**（每个插件实例从零开始 ✓）—— 每次 apply 清空，
  //   避免多实例/热重载之间串味（test/session-no-prefetch.mjs 的两个场景就靠它隔离 ✓）。
  resetStandbyCache()
  // ★★ 合并投递的收集队列也是**运行时状态** ✓ —— 每次 apply 清空（否则上一次实例里
  //   卡住的 waiter 会把新实例的第一批也一起吞掉 ✓；测试里两个场景互不串味 ✓）。
  resetBatchQueue()

  const cfg = {
    port: config.port ?? DEFAULTS.port,
    provider: config.provider ?? DEFAULTS.provider,
    model: config.model ?? DEFAULTS.model,
    maxTokens: config.maxTokens ?? DEFAULTS.maxTokens,
    temperature: config.temperature ?? DEFAULTS.temperature,
  }

  /** ★ Phase B（影子）是**默认**：先零风险地量她答得怎么样，再决定要不要让她说了算 ✓ */
  const decideMode: 'shadow' | 'live' = config.decideMode === 'live' ? 'live' : 'shadow'
  const steerWhenBusy = config.steerWhenBusy === true
  const retrySessionOnce = config.retrySessionOnce === true
  // ★★ 待命裁定冷却（默认 20 分钟，可配置 ✓）
  const noneCooldownMs = typeof config.noneCooldownMs === 'number' &&
    Number.isFinite(config.noneCooldownMs) && config.noneCooldownMs > 0
    ? config.noneCooldownMs
    : DEFAULT_NONE_COOLDOWN_MS
  // ★★ 2026-10-18：**漏答**不是决策 ✗ —— 短重试 + 连续 N 次才落 None ✓（C 项 ✓）
  const unansweredRetryMs = typeof config.unansweredRetryMs === 'number' &&
    Number.isFinite(config.unansweredRetryMs) && config.unansweredRetryMs > 0
    ? config.unansweredRetryMs
    : DEFAULT_UNANSWERED_RETRY_MS
  const unansweredMaxMisses = typeof config.unansweredMaxMisses === 'number' &&
    Number.isFinite(config.unansweredMaxMisses) && config.unansweredMaxMisses >= 1
    ? Math.floor(config.unansweredMaxMisses)
    : DEFAULT_UNANSWERED_MAX_MISSES
  // ★★ A：合并投递的收集窗口（默认 800ms ✓；0 = 不合并）
  const mergeWindowMs = typeof config.mergeWindowMs === 'number' &&
    Number.isFinite(config.mergeWindowMs) && config.mergeWindowMs >= 0
    ? config.mergeWindowMs
    : BUDGETS.mergeWindowMs
  live(`  ├ 漏答策略：短重试 ${Math.round(unansweredRetryMs / 1000)}s × 连续 ${unansweredMaxMisses} 次 才落 None（` +
    `明确 None 才按 ${Math.round(noneCooldownMs / 60000)} 分钟冷却 ✓）；合并窗口 ${mergeWindowMs}ms ✓`)

  // ★ 投递目标：① 显式 config（主人写在 profile 里 ✓）→ ② 落盘的选择（fleet_commander 指定过 ✓）
  //   都没有 = 不投递 ✓（= 今天逐字不变 ✓）。**绝不猜** ✗（猜错就塞进别人的聊天里了 ✓）。
  if (typeof config.commanderSession === 'string' && config.commanderSession.trim() !== '') {
    setCommanderSession(config.commanderSession)
  }
  const targetSession = (): string | undefined => getCommanderSessionId()

  // 双写：控制台（人看 ✓）+ 文件（agent 读 ✓）
  const logger = {
    info: (m: string): void => { ctx.logger?.info?.(m); fileLog(m) },
    warn: (m: string): void => { ctx.logger?.warn?.(m); fileLog('WARN ' + m) },
  }
  fileLog(`=== 插件启动：监听 ${cfg.port}（模型 ${cfg.provider}/${cfg.model}）===`)

  // ---- 会话那一级：拿服务 + 装**唯一一个** session/event 监听器 --------------
  // ★ 不经 `inject`（inject 里多一项就要重启 DSH 才生效 ✗）—— 拿不到就是"不投递"，
  //   单发路径逐字不受影响 ✓✓。
  const agents = ctx.get?.('agents') as { get(id: string): AgentLike | undefined } | undefined
  if (agents !== undefined && ctx.on !== undefined) {
    ctx.on('session/event', (session: any, event: any) => dispatchSessionEvent(session, event))
    live(`  ├ 会话投递：已就绪（模式=${decideMode}${decideMode === 'shadow' ? '（影子：只观测、不采纳 ✓）' : '（她的答案算数 ✓）'}）`)
  } else {
    live('  ├ 会话投递：**不可用**（拿不到 ctx.agents / ctx.on ✗）→ 决策全部走单发（今天的行为 ✓）')
  }
  // 启动时把"现在投给谁"写进流水一次 ✓（主人一眼看到 ✓）
  const startState: CommanderState = getCommanderState()
  live(startState.session === null
    ? '  ├ 投递目标：**未指定** ✓ → 决策走单发（用 fleet_commander 指定主人自己的会话即可启用投递 ✓）'
    : `  ├ 投递目标：会话 ${startState.session} ✓（租约 ${startState.leasedUntil === null ? '未开始' : new Date(startState.leasedUntil).toISOString()}）`)

  const peer = new RpcPeer({
    port: cfg.port,
    logger,
    defaultTimeoutSec: 5,
  })

  /**
   * ★★ 会话页顶部的**开关**用的 HTTP 路由（2026-10-17，主人要的形状 ✓）
   *
   * 主人的原话：「在会话上方做个开关，打开就切到对应会话，不再投递到之前会话。」
   * 客户端的那个开关（`lib/client.js` ✓）就靠这条路由读写"现在谁是投递目标" ✓：
   *   GET  /avorion-copilot/api/commander            → 当前状态（含"是不是这个会话" ✓）
   *   POST /avorion-copilot/api/commander/toggle     → 原子切换 ✓（打开=我；再点=关 ✓）
   *   POST /avorion-copilot/api/commander/clear      → 清除 ✓
   *
   * ★ 「打开就**不再投递到之前会话**」是**原子**的 ✓：`setCommanderSession` 只保存一个 id ✓，
   *   所以换成 X 的那一刻，旧会话就已经不在投递路径上了 ✓✓（不是"两个都投"✗）。
   *   与 TAKEOVER.md 的"同一时刻只有一个决策者"完全一致 ✓。
   *
   * ★ webserver **没就绪**（比如 headless / 根本没有该服务）→ 不当场放弃 ✗：
   *   没就绪就**等它**（`ctx.inject` ✓）；**永远拿不到**才退化成"没有 UI 开关" ✓：
   *   开关是**便利**，不是功能本体 ✗ —— 没有它也照样能用 `fleet_commander` 工具指定 ✓✓。
   */
  /**
   * ★★ 挂路由：**必须等 `webServer` 就绪**（2026-10-17 二次修正 ✗✓
   *    —— 这就是“会话开关在界面上看不见”的**真因** ✗✗）
   *
   * 第一版写的是 `const webServer = ctx.get?.('webServer')` 当场判断 ✗ ——
   * 而 `apply()` 跑的时刻，`webServer`（由 `dsh-web-app` bundle 提供 ✓）
   * **还没就绪** ✗，于是静默走了 else 分支：
   * **路由根本没挂** ✗✓ → 客户端开关每次 GET 都 404 →
   * 状态拿不到 → **永远渲染 null** ✗✗（所以重启再多次也没用 ✗）。
   * 铁证：`moddata/copilot/decisions.live.log` 里那行
   *   “会话开关：拿不到 webServer → **没有 UI 开关** ✗” ✓✓。
   *
   * ✓ 正确姿势：照抄原版 `dsh-client-modules/lib/index.js`
   *   处理**可选服务**的写法 ✓✓：
   *     `ctx.get('webServer')` 有 → 立刻挂 ✓；
   *     没有 → `ctx.inject(['webServer'], …)` **等它出现再挂** ✓✓。
   * ★ 千万不要把 'webServer' 写进 `export const inject` ✗ —— 那样在
   *   headless 等**没有 web 服务**的 profile 里**整个插件都不会启动** ✗✓
   *   （我们要的是“没开关也照跑” ✓）。
   */
  const mountCommanderApi = (svcCtx: any): void => {
    try {
        const webServer = (svcCtx?.get?.('webServer') ?? svcCtx?.webServer ?? ctx.get?.('webServer')) as {
        register(route: { kind: 'exact' | 'prefix'; path: string; handler: (req: any, res: any) => void | Promise<void> }): unknown
      } | undefined
      if (webServer !== undefined && typeof webServer.register === 'function') {
        const COMMANDER_API = '/avorion-copilot/api'
        const snapshot = (mine: string | null): Record<string, unknown> => {
          const st = getCommanderState()
          return {
            commander: st.session,
            isMine: st.session !== null && st.session === mine,
            leasedUntil: st.leasedUntil,
            leaseFresh: isLeaseFresh(),
            mode: decideMode,
            sessionLive: st.session === null ? false : agents?.get(st.session) !== undefined,
          }
        }
        const json = (res: any, code: number, body: unknown): void => {
          res.writeHead(code, { 'content-type': 'application/json; charset=utf-8' })
          res.end(JSON.stringify(body))
        }
        const readBody = async (req: any): Promise<any> => {
          try {
            const chunks: Buffer[] = []
            for await (const c of req) chunks.push(Buffer.from(c))
            const raw = Buffer.concat(chunks).toString('utf8')
            return raw.trim() === '' ? {} : JSON.parse(raw)
          } catch { return {} }
        }
        ctx.effect(() => {
          // ★ 保留 register 的返回值不等于把它交给 effect ✓（effect 要 void | cleanup ✓）；
          //   真要清理就自己 return 一个 ✓（拿不到就不 return ✓）。
          const handle = webServer.register({
          kind: 'prefix',
          path: COMMANDER_API,
          handler: async (req, res) => {
            try {
              const url = new URL(req.url ?? '/', 'http://localhost')
              const pathname = url.pathname.replace(/^\/avorion-copilot\/api/, '') || '/'
              const method = String(req.method ?? 'GET').toUpperCase()
              const body = method === 'POST' ? await readBody(req) : {}
              // ★ 缺陷③修复：GET 时 body 恒为 {} → `mine` 恒 null ✗ → 页面永远显示"关" ✗。
              //   现在从 URL 查询串 `?session=` 兜底 ✓（POST 的 toggle/clear 仍走 body ✓）。
              const fromBody = typeof body.session === 'string' && body.session.trim() !== '' ? body.session.trim() : null
              const fromQuery = url.searchParams.get('session')
              const mine = fromBody ?? (typeof fromQuery === 'string' && fromQuery.trim() !== '' ? fromQuery.trim() : null)

              if (method === 'GET' && (pathname === '/commander' || pathname === '/')) {
                return json(res, 200, { ok: true, ...snapshot(mine) })
              }
              if (method === 'POST' && pathname === '/commander/toggle') {
                if (mine === null) return json(res, 400, { ok: false, error: 'toggle needs the session id' })
                const was = getCommanderState().session
                // ★ 点开一个已经是目标的会话 = 关掉它（开关的语义 ✓）；否则 = 切换到这个会话 ✓
                const now = was === mine ? null : mine
                setCommanderSession(now)
                live(`  ├ [开关] 会话 ${mine} 把投递目标${now === null ? '**关掉**了' : `切到了自己`}` +
                  `${was !== null && was !== now ? `（原目标 ${was} 立刻不再收到任务 ✓）` : ''}`)
                return json(res, 200, { ok: true, ...snapshot(mine), previous: was })
              }
              if (method === 'POST' && pathname === '/commander/clear') {
                const was = getCommanderState().session
                setCommanderSession(null)
                live(`  ├ [开关] 投递目标已清除${was !== null ? `（原目标 ${was}）` : ''} ✓ → 决策回到单发 ✓`)
                return json(res, 200, { ok: true, ...snapshot(mine), previous: was })
              }
              return json(res, 404, { ok: false, error: `no such route: ${method} ${pathname}` })
            } catch (error) {
              return json(res, 500, { ok: false, error: String(error) })
            }
          },
          })
          void handle
          live(`  ├ 会话开关：HTTP 路由已挂（${COMMANDER_API}/commander ✓ —— 客户端开关靠它 ✓）`)
          return undefined
        }, 'avorion-copilot:commander-api')
      } else {
        live('  ├ 会话开关：拿不到 webServer → **没有 UI 开关** ✗；' +
          '请改用 fleet_commander 工具显式指定（功能本体不依赖开关 ✓）')
      }
    } catch (error) {
      live(`  ⚠ 会话开关：挂路由失败（${String(error)}）—— 功能本体不受影响 ✓（用 fleet_commander 工具 ✓）`)
    }
  }

  // ★ 服务可能还没就绪 → **等它** ✓（旧版在这里静默放弃 ✗，就是“开关看不见”的真因 ✗）
  if (ctx.get?.('webServer') !== undefined || typeof ctx.inject !== 'function') {
    mountCommanderApi(ctx)
  } else {
    live('  ├ 会话开关：webServer 尚未就绪 → **等它出现再挂路由** ✓')
    ctx.inject(['webServer'], (webCtx: any) => mountCommanderApi(webCtx))
  }

  // ---- 我提供的功能（游戏可以调我）------------------------------------------

  peer.handle('hello', (data: any) => {
    // 协议 §6/§8：两端各发一次 hello，各自声明 caps ✓
    logger.info(`avorion-copilot: 游戏握手 side=${data?.side} ver=${data?.ver} caps=${(data?.caps ?? []).join(',')}`)
    return [true, { side: 'dsh', ver: 2, caps: peer.caps() }]
  })

  peer.handle('ping', () => [true, { pong: true, from: 'dsh' }] as [boolean, any])

  /**
   * ★ `decide` —— **游戏调 DSH 的决策能力**，整条链的核心 ✓
   *
   * `data` 由游戏侧给出：`{ship, card, options}` —— 其中 `options` 来自游戏侧的
   * `orderSchema` ✓，所以模型**只可能选到合法命令** ✓✓。
   *
   * 返回 `{action, params}` ✓；游戏侧拿到后走 `order` 真正下单 ✓。
   */
  /**
   * ★★ decide 的外层：保证**任何出口都留下一条决策记录** ✓✓（主人要在 DSH 里看得见 ✓）。
   * 真正的逻辑在内层 decideInner 里，它边做边把过程写进 rec ✓。
   */
  peer.handle('decide', async (data: any) => runDecide((data ?? {}) as DecideRequest))

  /**
   * ★★ `decide` 的**唯一实现**（2026-10-18 抽出 ✓）：游戏调一次、B 的**漏答重投**也调它 ✓。
   *
   * ★ 为什么必须共用同一个函数 ✗→✓：重投如果自己再写一份"问会话 + 下单"，
   *   就等于**第二套决策逻辑** ✓（本仓库反复吃过的亏 ✓）。共用它 = 重投真的**重投**，
   *   而不是"另开一条捷径" ✓✓。
   */
  const runDecide = async (req: DecideRequest): Promise<[boolean, any, string?]> => {
    const rec: DecisionRecord = {
      at: new Date().toISOString(),
      ship: typeof req.ship === 'string' ? req.ship : '(none)',
      goalText: '',
      goalOptions: [],
      ok: false,
    }
    live(`▶ 收到 decide  ship=${rec.ship}  hasGoal=${String(req.hasGoal)}`)
    try {
      const out = await decideInner(req, rec)
      if (out[0] === true) {
        rec.ok = true
        rec.answer = out[1] as DecisionRecord['answer']
      } else {
        rec.ok = false
        rec.code = String(out[1])
        rec.message = out[2]
      }
      return out
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error)
      rec.ok = false
      rec.code = 'EXCEPTION'
      rec.message = message
      // ★★ 2026-10-17 实机血案：只报 "Cannot read properties of null (reading 'x')" ✗
//    —— 这种字面信息**定位全靠猜** ✗✓（一晚猜了三次 ✓）。★ 有栈就能一眼指到行 ✓✓。
      const where = error instanceof Error && error.stack
        ? error.stack.split('\n').slice(0, 4).map((s) => s.trim()).join(' | ')
        : ''
      logger.warn(`avorion-copilot: EXCEPTION in decide: ${message} @ ${where}`)
      live(`  ⚠ 异常位置(栈): ${where}`)
      return [false, 'EXCEPTION', message] as [boolean, any, string]
    } finally {
      recordDecision(rec)
      live(rec.ok
        ? `✔ 完成  ${rec.ship}  action=${rec.answer?.action ?? '?'}  ${JSON.stringify(rec.answer?.params ?? {})}`
        : `✘ 失败  ${rec.ship}  ${rec.code ?? ''} ${rec.message ?? ''}`)
      logger.info(
        `avorion-copilot: 决策记录 #${decisionLog.length} ` +
        `${rec.ship} ok=${rec.ok}${rec.answer ? ' -> ' + rec.answer.action : ''}`,
      )
    }
  }

  // ---------------------------------------------------------------------------
  // ★★ B/C：漏答 = 「没答到」，**不是**决策 ✗✓（2026-10-18）
  //
  // 病根（真机日志 2026-10-18 08:50:58 ✓）：两艘船同一秒各发一条 decide →
  //   第二条被 `SESSION_BUSY` 挡掉 → `fallbackNone` → **20 分钟**待命冷却 ✗✗。
  //   于是"漏答"被当成"判了 None"来罚 ✓ —— 那艘船静默 20 分钟 ✓。
  //
  // 治法：
  //   · `fallbackNone`（以及她在问主人 asked-owner）→ `kind='unanswered'` ✓
  //     → **短冷却**（unansweredRetryMs，默认 3 分钟）+ 进这个重投队列 ✓；
  //   · 只有**明确写了 `action=None`**（会话/单发判的）→ `kind='none'` → 长冷却（20 分钟 ✓）；
  //   · 连续 `unansweredMaxMisses`（默认 3）次没答到 → 才落到 None + 长冷却 ✓（避免无限刷 ✗）。
  // ---------------------------------------------------------------------------
  interface UnansweredEntry {
    /** 连续没答到几次 ✓ */
    misses: number
    /** 第一次没答到的时刻 ✓ */
    atMs: number
    /** 下一次重投的时刻 ✓ */
    nextAtMs: number
    /** 重投正在跑（防同一艘船两个重投叠在一起 ✓） */
    running?: boolean
  }
  const unansweredRetry = new Map<string, UnansweredEntry>()

  // ---------------------------------------------------------------------------
  // ★★ 护航观测 + 建议（2026-10-24 接回来 ✓）—— **只告知** ✓ 不替她下单 ✗
  // ---------------------------------------------------------------------------
  //
  // 写入：`tools.ts` 在 `fleet_query{predict}` / `fleet_order` 的**回包处**记一笔 ✓
  //   （那里已经拿到游戏算好的数字 ✓ —— 不额外发任何查询 ✗）。
  // 读取：`decideInner` 投递前调 `escortHintFor(ship)` ✓，结果进投递块的 `escortHint` ✓。
  // ★ 一船一份、后写覆盖 ✓：最近量的那一单最有信息量 ✓。
  // ★ 有效期 15 分钟 ✓（`ESCORT_OBS_TTL_MS`）—— 过期的数**不当数** ✓。

  /** 她**自己量到**的风险数字 ✓（key = 行动船名 ✓） */
  const riskObservations = new Map<string, RiskObservation>()

  const noteRiskObservation = (obs: RiskObservation): void => {
    riskObservations.set(obs.ship, obs)
    live(`  ├ 记下风险数字（${obs.source}）：${obs.ship} ${obs.action ?? '?'} ` +
      `base=${fmtPct(obs.baseAttackChance)} attack=${fmtPct(obs.attackChance)}` +
      (obs.known ? '' : '（游戏没算出来 ✓ 不填 0 ✗）') +
      (obs.escortsGiven !== undefined && obs.escortsGiven.length > 0
        ? `，已带护航 ${obs.escortsGiven.join(',')}` : ''))
  }

  /**
   * 投递前的**护航建议**（一行 ✓；拿不到就是 undefined ✓ —— 绝不编 ✗）。
   * ★ 只有她量过数字的船才有 ✓（没有观测 = **0 次查询** ✓✓）；
   *   ★ 发的只有 atomic 的 `list` / `ship{brief:true}` ✓ —— **一次 `*Plan` 都没有** ✗✓。
   */
  const escortHintFor = async (ship: string): Promise<string | undefined> => {
    const obs = riskObservations.get(ship)
    if (obs === undefined) return undefined
    if (Date.now() - obs.atMs > ESCORT_OBS_TTL_MS) {
      riskObservations.delete(ship)
      return undefined
    }
    const t0 = Date.now()
    try {
      const hint = await buildEscortHint(
        async (what, params) => {
          const r = await ask(peer, 'query', { what, ...params }, 10)
          return { ok: r.ok, data: r.data, why: r.why }
        },
        obs,
      )
      live(`  ├ 护航建议：${hint ?? '无（不需要/没船 → 不加那一行 ✓）'}` +
        `（${Date.now() - t0} ms；只用 list / ship{brief} —— **不发 *Plan** ✓）`)
      return hint
    } catch (error) {
      // ★ 这一行只是**告知** ✓ —— 失败绝不能影响决策 ✗✓
      live(`  ├ 护航建议失败（不影响决策 ✓）：${error instanceof Error ? error.message : String(error)}`)
      return undefined
    }
  }

  /** 这些 code = **没答到**（不是决策 ✗）→ 走短重试 ✓；其余一律按"她判了"处理 ✓ */
  const MISS_CODES = new Set([
    'SESSION_BUSY', 'SESSION_BUSY_ELSEWHERE', 'TIMEOUT', 'UNANSWERED',
    'EMPTY_REPLY', 'NO_ACTION_LINE', 'TASK_MISMATCH', 'BAD_ACTION',
    'HOST_TURN_FAILED', 'NO_EVENT_CHANNEL', 'SESSION_GONE', 'SESSION_ERROR', 'NO_BUDGET',
    'ASKED_OWNER',
  ])

  // ---------------------------------------------------------------------------
  // ★★ 被拒的答复**必须回给会话**（2026-10-20 ✓）
  //
  // 真机事故的另一半（`decisions.live.log` 2026-10-20 14:32:19 ✓）：答复被判 `BAD_ACTION` 之后，
  //   拒绝理由只落在插件自己的流水里 ✗ —— 会话那边**一个字都没看到** ✗，
  //   于是下一轮（180s 后重投）她还在猜同一个动作，同一个坑会再踩一次 ✓。
  //
  // 治法：记一条**一次性**的拒绝条 ✓，塞进下一次投递块的「上一单的结果」行 ✓
  //   （块里那条线本来就有 ✓，2026-10-17 加的 ✓）；看过即删，免得它一直刷屏 ✗
  //   —— 块体积契约是 ~200 字节，所以这里先把原因裁到放得下 ✓（裁不出就说清楚裁了 ✓）。
  // ---------------------------------------------------------------------------
  interface RejectNote { text: string; atMs: number }
  const rejectNotes = new Map<string, RejectNote>()
  /** 拒绝条最多留多久（超了就当旧的丢掉 ✓ —— 半小时后的"上次"没有信息量 ✓） */
  const REJECT_NOTE_MAX_MS = 30 * 60_000

  /** 按 UTF-8 字节截断（不切断半个字符 ✓）；截了就加省略号 ✓ */
  const clipUtf8 = (s: string, maxBytes: number): string => {
    if (Buffer.byteLength(s, 'utf8') <= maxBytes) return s
    let cut = s
    while (cut !== '' && Buffer.byteLength(cut + '…', 'utf8') > maxBytes) cut = cut.slice(0, -1)
    return cut === '' ? '' : cut + '…'
  }

  /** 组装「答复被拒」那条（保证整行塞得进 prevResult 的 200 字节预算 ✓） */
  const rejectBody = (code: string, why: string): string => {
    const head = `上次答复被拒 ${code}：`
    const suffix = '（块里清单=投递时快照；以当前船卡 allowedActions 为准）'
    const fixed = Buffer.byteLength(`★ 上一单的结果：${head}`, 'utf8') + Buffer.byteLength(suffix, 'utf8')
    const room = PREV_RESULT_BUDGET_BYTES - fixed - 1
    if (room < 24) return head + clipUtf8(why, Math.max(0, PREV_RESULT_BUDGET_BYTES - fixed))
    return head + clipUtf8(why, room) + suffix
  }

  /** 取走这条船的一次性拒绝条 ✓（取过就删 ✓；过期的直接丢 ✓） */
  const takeRejectNote = (ship: string): string | undefined => {
    const e = rejectNotes.get(ship)
    if (e === undefined) return undefined
    rejectNotes.delete(ship)
    if (Date.now() - e.atMs > REJECT_NOTE_MAX_MS) return undefined
    return e.text
  }

  /** 这些 code = **她的答复被拒** → 原因必须回给会话 ✓（其余 code 是"没收到"，没有"她的错"可回 ✗） */
  const REJECT_FEEDBACK_CODES = new Set(['BAD_ACTION', 'TASK_MISMATCH'])

  // 内层：真正的决策逻辑（边做边填 rec ✓）
  const decideInner = async (
    req: DecideRequest,
    rec: DecisionRecord,
  ): Promise<[boolean, any, string?]> => {
    const ship = req.ship
    if (typeof ship !== 'string' || ship === '') {
      return [false, 'BAD_REQUEST', 'decide needs data.ship']
    }

    logger.info(`avorion-copilot: 为 ${ship} 决策中…`)
    live(`  ├ 开始决策  ${ship}`)

    // ── ① 轻量预取（毫秒级）：只取 goal ✓✓ ────────────────────────────────
    //   ★ 会话路径到此为止 ✗✓：船卡 / 舰队 / 计划 / 记忆 / rendezvous 一个都不预取 ✓，
    //     全留给「单发路径」的惰性预取（见下面 prefetchSingleShot ✓）——
    //     这样投递任务前的游戏侧总耗时就是毫秒级 ✓（主人"决策中不能操作舰船"的根因 ✓）。
    //   ★ 2026-10-24 的唯一例外 = **投递前那一行护航建议** ✓（`escortHintFor` ✓）：
    //     只在「她量过数字」时才有动作 ✓（没有观测 = **0 次查询** ✓✓），
    //     且只发 atomic 的 `list` / `ship{brief}` ✓（**一次 `*Plan` 都没有** ✗✓）。
    const goalR = await ask(peer, 'query', { what: 'goal', ship }, 10)
    if (!goalR.ok) {
      logger.warn(`avorion-copilot: 拉目标失败 ${goalR.why ?? ''}`)
      return [false, 'GOAL_QUERY_FAILED', goalR.why ?? 'unknown']
    }
    const gd = (goalR.data ?? {}) as Record<string, unknown>
    const facts: DecideFacts = {
      ship,
      goalText: typeof gd.text === 'string' ? gd.text : '',
      // ★★ 2026-10-19 起这**不是**玩家填的白名单 ✗✓：游戏侧按船自动推导
      //   （`lib/copilot/card.lua` 的 `M.deriveActions` ✓，`goal.describe` 把推导值放进 `options` ✓）。
      //   语义不变 → 下游 `validateAnswer` / `allowedActions` 一行都不用改 ✓✓
      goalOptions: Array.isArray(gd.options) ? (gd.options as string[]) : [],
      card: undefined,   // ★ 船卡延迟到单发路径再取 ✓（会话路径不需要 ✓）
    }
    rec.goalText = facts.goalText
    rec.goalOptions = facts.goalOptions

    // ★★ 待命裁定（2026-10-17 主人要求 ✓）：决策者判这艘船 None 后，冷却期内不再征询 ✓。
    //   判据只有两条（见 standby.ts）：冷却到期 / 目标指纹改变 → 恢复征询；否则直接 None ✓。
    //   ★ 2026-10-18：冷却**分级** ✓ —— `unanswered`（漏答）用短冷却、`none`（真的判了）用长冷却 ✓。
    const standbyNow = standbyVerdict(
      ship, facts.goalText, facts.goalOptions,
      { noneMs: noneCooldownMs, unansweredMs: unansweredRetryMs },
    )
    if (standbyNow.kind === 'standby') {
      const oldKind: StandbyKind = standbyNow.entry.kind
      const kindText = oldKind === 'unanswered'
        ? `漏答重投冷却（${Math.round(unansweredRetryMs / 1000)}s，连续 ${unansweredMaxMisses} 次才落 None）`
        : `待命裁定（明确 None）`
      const reason = `待命裁定：${ship} 上一轮是**${kindText}**（来源 ${standbyNow.entry.source}），` +
        `还剩约 ${standbyNow.minsLeft} 分钟；目标改变、冷却到期或手动召回后恢复 ✓`
      rec.source = 'fallbackNone'
      rec.decider = 'fallbackNone'
      live(`  ├ 待命裁定：${ship} 仍在冷却期内（${kindText}，状态未变）→ 本轮直接 None，不投递、不跑模型 ✓`)
      return [true, { action: 'None', params: {}, reason }]
    }

    // ── ② 单发路径的**轻量**预取（惰性、幂等）──────────────────────────────
    //   ★★ 这是「单发路径」**专属**的预取 ✗✓ —— 会话路径**绝不**调用它（见分支 ③ ✓）。
    //
    //   ★★ 2026-10-24 主人点名的拆 ✓✓（原话：「去掉吧，是旧的那套 JOB 之前直接扫区域，
    //      而非你去决策扫是吧」—— 主人说得对 ✓）：
    //      **一个 legacy 计划都不再预取** ✗ —— `jobPlan` / `minePlan` / `salvagePlan` /
    //      `sellPlan` / `scoutPlan` / `tradePlan` 的老实现是**自己扫 67~71 个区域并自排序** ✓，
    //      而且全都跑在游戏**主循环里同步**算的（真机实测：jobPlan 828/884 ms、
    //      scoutPlan 1321 ms、sellPlan 8248 ms、tradePlan 12633~15415 ms ✓）——
    //      一跑就是「决策中不能操作舰船」✓✓。
    //      正确做法 = **决策者先选框、再点名要数** ✓：`predict`（≤24 框 ✓）/
    //      `tradeEvaluate` / `tradeRoutes` 这些**原子**接口**照旧可用** ✓（第 ③ 条 ✓），
    //      只是不再由这里替它预扫 ✗✓。
    //   ★ 这里只剩**轻的、原子的事实** ✓：船卡 ✓ / 目标（上面已取 ✓）/ 舰队名单 ✓ / 记忆结算 ✓。
    //   ★ 所以返回值恒为 null ✓ —— 旧的"预取期间就定了这一单"那条路（rendezvous）已随
    //     legacy tradePlan 一并移除 ✓（见上面 rendezvous 那段的说明 ✓）。
    //   ★ 2026-10-24 接回来的是**会话路径**上的那一行建议 ✓（`escortHintFor` ✓）——
    //     **不是**这里的自派 ✗✓：单发兜底依然什么都不预取、也不派船 ✓。
    //   ★ 没有计划也能给 None ✓✓ —— 单发档案会**明说**「无计划（已移除预扫描）」✓（dossier.ts ✓）。
    let singleShotPrepared = false
    let sectorKey = ''
    let memoryBlock = ''
    const prefetchSingleShot = async (): Promise<DecideAnswer | null> => {
      if (singleShotPrepared) return null
      singleShotPrepared = true

      const cardR = await ask(peer, 'query', { what: 'ship', ship }, 10)
      if (!cardR.ok) {
        logger.warn(`avorion-copilot: 拉能力卡失败 ${cardR.why ?? ''}`)
        facts.planFetchFailures = [{ what: 'ship', why: cardR.why ?? 'unknown' }]
        return null
      }
      facts.card = cardR.data ?? {}
      // ★★ 舰队名单（**轻**：一次 roster 读 ✓，不扫任何区域 ✓）——
      //   只有两个消费方：① `toAnswer` 清洗 `escorts=`（只认名单里的名字 ✓）；
      //   ② 单发档案里的「护航候选」✓。**没有任何计划查询** ✗✓。
      {
        // ★★ 算**护航候选** ✓✓
        //   ★★ 规则以**原版**为准（实读 simulationutility.lua:145-176，2026-10-17 更正 ✗→✓）：
        //     护卫与行动船的距离 ≤ **护卫自己一跳的航程**（:161 `> reach*reach` → TooFarAway）✓
        //     —— **不要求同星系** ✗✓（同星系只是它的一个子集 ✓）；
        //     另外，**不能穿裂隙**（canPassRifts=false）的护卫还须与行动船**同处屏障环一侧**（:165-168）✓。
        //   ⚠️ 环侧要用 `Balancing_InsideRing` 才判得准 —— 那在**游戏侧** ✗，
        //      所以这里对两种情况**保守取"同星系"** ✓（同星系必然同环侧 ✓，只会少收、不会错收 ✓）：
        //        · canPassRifts 明确为 false ✓
        //        · 拿不到航程（卡片没给 hyperspace ✓）
        //     并在流水里把"保守未收"的船列出来（人能看到为什么 ✗✓）。
        try {
          const fr = await ask(peer, 'query', { what: 'fleet' }, 10)
          if (fr.ok) {
            const fd = (fr.data ?? {}) as Record<string, unknown>
            const shipSector = ((facts.card as Record<string, unknown>).sector ?? {}) as { x?: number; y?: number }
            const ships = Array.isArray(fd.ships) ? (fd.ships as Record<string, unknown>[]) : []
            const cands: string[] = []
            const conservative: string[] = []
            for (const s of ships) {
              const nm = typeof s.name === 'string' ? s.name : ''
              const sec = (s.sector ?? {}) as { x?: number; y?: number }
              if (nm === '' || nm === ship) continue
              if (nm === String(fd.piloted ?? '')) continue
              if (s.busy === true) continue

              const sameSector = sec.x === shipSector.x && sec.y === shipSector.y
              if (sameSector) { cands.push(nm); continue }   // 同星系 → 必然满足原版判据 ✓

              const hs = (s.hyperspace ?? {}) as { reach?: unknown; canPassRifts?: unknown }
              const reach = typeof hs.reach === 'number' ? hs.reach : undefined
              if (reach === undefined) { conservative.push(nm + '(航程未知)'); continue }
              if (hs.canPassRifts === false) {
                // ★ 2026-10-17 主人实机反馈「她尝试护航但失败」✗ —— 查到根在这里：
                //   此处**一律保守排除**✗，把**原版允许**的护航白白漏掉 ✓。
                //   而环侧**游戏侧一直算着** ✓（card.lua:298 用原版 Balancing_InsideRing ✓
                //   写在卡片的 depth.insideCentreRing ✓）。
                //   → 两边都拿得到就**按原版判** ✓✓：同环侧=可用 ✓；不同环侧=真不可用 ✓；
                //     只有**真拿不到**时才退回"保守同星系" ✓（只会多收合法的 ✓，不会错收 ✗）。
                const ringHere = ((facts.card as Record<string, unknown> | undefined)?.depth as
                  { insideCentreRing?: unknown } | undefined)?.insideCentreRing
                const ringThere = ((s.depth ?? {}) as { insideCentreRing?: unknown }).insideCentreRing
                if (typeof ringHere === 'boolean' && typeof ringThere === 'boolean') {
                  if (ringHere !== ringThere) { conservative.push(nm + '(不同环侧)'); continue }
                } else {
                  conservative.push(nm + '(环侧未知)'); continue
                }
              }
              const dx = (sec.x ?? 0) - (shipSector.x ?? 0)
              const dy = (sec.y ?? 0) - (shipSector.y ?? 0)
              if (Math.sqrt(dx * dx + dy * dy) <= reach) cands.push(nm)   // ★ 原版判据 ✓
            }
            facts.escortCandidates = cands
            live(`  ├ 护航候选 ${cands.length} 艘${cands.length > 0 ? ': ' + cands.join(',') : ''}`
              + `（判据=原版: 距离 ≤ 护卫自己一跳航程 ✓）`
              + (conservative.length > 0 ? `；保守未收 ${conservative.length} 艘: ${conservative.join(', ')}` : ''))
          }
        } catch { /* 拿不到护航候选不影响决策 ✓ */ }
      }

      // ★★ 2026-10-24：这里**曾经**预取 `minePlan` / `salvagePlan` / `sellPlan` /
      //   `scoutPlan` / `tradePlan` ✗ —— 全部删掉 ✓✓（主人原话：「去掉吧，是旧的那套 JOB
      //   之前直接扫区域，而非你去决策扫是吧」）。
      //   · 为什么必须删 ✗：它们每一个都会在游戏主循环里**同步**扫区域并**自排序**
      //     （真机 rpc_trace 2026-10-24 01:35 逐条：`jobPlan Mine …
      //     扫描=71区域/828ms`、`jobPlan Salvage … 884ms`、`scoutPlan … 1321ms`、
      //     `sellPlan … 8248ms`、`tradePlan … 12633~15415ms` ✓）；
      //     同一时刻 serverlog 留下 `had a very long tick of over 19214ms` ✓。
      //   · 为什么可以删 ✓：单发兜底**没有这些也能给 None** ✓✓；
      //     要真数据的那条路由**决策者自己点名**：`predict`（≤24 框 ✓）/
      //     `tradeEvaluate` / `tradeRoutes` ✓✓ —— 见 docs/dev/interface-atomicity.md ✓。

      // ★ 2026-10-24：`scoutPlan` / `tradePlan` 预取**已删除** ✗✓（理由见上 ✓）。
      //   要侦察/贸易的候选框，请**点名**要：`predict{Scout, 21x21}` /
      //   `tradeRoutes` / `tradeEvaluate`（原子接口 ✓ 一次只算你给的框 ✓）。

      // ★ 记录②"输入"（主人要看的 ✓）
      rec.goalText = facts.goalText
      rec.goalOptions = facts.goalOptions
      rec.card = facts.card
      live(`  ├ 事实  目标=[${facts.goalText}] 可选动作(按船自动)=[${facts.goalOptions.join(',') || '不限'}]`)
      logger.info(
        `avorion-copilot: ${ship} 目标=[${facts.goalText}] 可选动作(按船自动)=${facts.goalOptions.join(',') || '(不限)'}`,
      )

      // ★★★ 单发路径的**档案**（2026-10-17 主人批准的改动 ✓✓）--------------------------
      //   组装点 `dossierInputOf` 已挪到 `prefetchSingleShot` **之后**定义 ✓（它只读 facts、
      //   不参与预取，放在预取之后、runSingleShot 之前，语义更清楚 ✓）。
      // ★★ 2026-10-24：**单发兜底里仍然不派护航** ✗✓（原触发块就在这个位置 ✓）——
      //   它当年只靠 legacy `tradePlan` 的 `recommendation === null` + `areaRanking`
      //   判断"缺护航" ✓，而 tradePlan 正是这次**不再预取**的那个 ✓。
      //   ★ 接回来的位置**不在**这里 ✗：护航建议只在**会话路径**上算 ✓（`escortHintFor` ✓），
      //     数据是**决策者自己量到的**数字 ✓ + `list` 的空闲战斗舰 ✓（见上面 rendezvous 段 ✓）。
      //   单发兜底仍然**不替它扫 67 框** ✗，也**不替它派船** ✗。
      //   （`escortNeedOf` / `escortNeedFor` / `pickRendezvousEscort` 仍在上面保留 ✓，
      //     `test/rendezvous.mjs` 钉着它们的硬规矩 ✓。）

      // ★★ 增量 2：结算**上一次**任务（busy→idle 转换 ✓）
      //   游戏侧没有把产出回灌给 Lua 的干净通道 ✗（见提交说明），所以这里记录的是
      //   **可得到的弱信号**：它忙了多久 / 是否远早于申请时长结束（远早 ≈ 被伏击或召回 ✓）。
      // ★★ 实测崩溃点（2026-10-17，真机 Scout-00001 逐字复现 ✓）:
      //   `sector` 可能是 **null** ✗ —— 此时 `cardSec !== undefined` **仍然成立** ✓
      //   → `cardSec.x` 抛 `Cannot read properties of null (reading 'x')` ✓✓
      //   ★ 读不到坐标 = "**取数缺失**"这个事实 ✓ —— 绝不当成 (0,0) 用 ✗（那会**伪造**一个星区 ✓）。
      const cardSecRaw = (facts.card as Record<string, unknown>).sector
      const cardSecObj = (typeof cardSecRaw === 'object' && cardSecRaw !== null)
        ? (cardSecRaw as Record<string, unknown>)
        : undefined
      const cardSecX = toNum(cardSecObj?.x)
      const cardSecY = toNum(cardSecObj?.y)
      const memSectors: string[] = []
      if (cardSecX !== undefined && cardSecY !== undefined) {
        memSectors.push(String(cardSecX) + "," + String(cardSecY))
      }
      // ★ 2026-10-24：这里原来看 `facts.tradeRoutes?.orderHint` 把贸易候选星区也记进记忆 ✓
      //   —— tradeRoutes 已不再预取 ✗，所以只剩**船卡星区**这一个确定来源 ✓（够用 ✓）。
      sectorKey = memSectors.length > 0 ? memSectors[memSectors.length - 1] : ""

      const prevJob = pendingJobs.get(ship)
      if (prevJob !== undefined) {
        const busyNow = (facts.card as Record<string, unknown>).busy
        if (busyNow === false) {
          const busySeconds = Math.max(0, Math.round((Date.now() - prevJob.atMs) / 1000))
          const requestedSec = (prevJob.hours ?? 0) * 3600
          const endedEarly = requestedSec > 0 && busySeconds < requestedSec * 0.5
          rememberOutcome(ship, {
            at: new Date().toISOString(), action: prevJob.action, goodName: prevJob.goodName,
            sector: prevJob.sector, busySeconds, requestedHours: prevJob.hours, endedEarly,
          })
          live("  ├ 结算上一次：" + prevJob.action + (prevJob.goodName !== undefined ? " " + prevJob.goodName : "")
            + " 忙了 " + busySeconds + "s" + (endedEarly ? "（远早于申请时长 → 疑似被伏击/召回 ✓）" : "（正常完成 ✓）"))
          pendingJobs.delete(ship)
        }
      }

      // ★★ 增量 1/3：只载入**这一轮真正相关**的记忆 ✓（按预算截断 ✓，绝不整库灌入 ✓）
      const mem = retrieveMemory(ship, memSectors)
      live("  ├ 载入记忆：" + mem.counts + (mem.compressed > 0 ? "（压缩 " + mem.compressed + " 条）" : ""))
      memoryBlock = "【你自己的记忆 —— 仅供参考 ✓；若与下面新算出的游戏数据冲突，以游戏数据为准 ✗】"
        + String.fromCharCode(10) + mem.text

      // 预取结束 → 返回 null，照常走模型（dossier + 单发 ✓）
      return null
    }

    // ★★★ 单发路径的**档案**（2026-10-17 主人批准的改动 ✓✓）--------------------------
    //
    //   为什么单发那条路**必须**"预取 + 裁剪"而不是"告知 + 自拉" ✗→✓：
    //   它是一个**没有工具、没有文件访问**的模型调用 ✓ —— 它不能自己查任何东西 ✗。
    //   而 agent 那条路（投进会话）**只被告知**（`task.ts` ✓），数据由**她自己查** ✓✓。
    //   ★ 两条路**共享数据**（同一份卡片 ✓），**不共享渲染** ✗✓
    //     —— "共享那一份'把所有东西都嵌进去'的渲染"**正是** 8.7 MB 的根因 ✓✓。
    //
    //   ★★ 关键取舍：档案**不再另发一次 RPC** ✗✓ —— 上面的轻量预取已经把卡片/目标/名单取回来了 ✓，
    //     所以这里**组装字段**就行了 ✓（与"重试不重取"同一条纪律 ✓）。
    //   ★ 游戏侧那个 `dossier` 入口仍然保留 ✓ —— 它是给**手动/诊断**用的查询 ✓
    //     ★ 2026-10-24 起它也**只读卡片/目标**，不跑任何计划 ✓✓（见 `data/scripts/net/link_in.lua`
    //       的 `CopilotLinkIn.dossier` ✓）。
    //   ★★ 2026-10-24：**plans 恒为空数组** ✗✓ —— 单发兜底不再预取任何 legacy 计划 ✓
    //     （它们全是游戏主循环里同步扫 67~71 区的重活 ✓）。渲染侧会**明说**
    //     「无计划（已移除预扫描）」✓，模型据此老实给 None 或换个动作 ✓，**不崩** ✓。
    const dossierInputOf = (): DossierPayload => {
      const empty = {} as DossierPayload
      const d = {
        what: 'dossier', ship, gate: 0.1,
        card: facts.card ?? empty,
        goal: { ship, text: facts.goalText, options: facts.goalOptions, hasGoal: facts.goalOptions.length > 0 },
        plans: [] as unknown[],
        planFetchFailures: facts.planFetchFailures ?? null,
      }
      return d as unknown as DossierPayload
    }

    // ★★★ 决策来源：**先试着投给主人的会话**，不行才自己单发 ✓✓
    //   （范围见 commander.ts 的文件头：没有分身、没有新建会话 ✓；
    //     没指定会话 / 会话在忙 / 超时 → 逐字回到今天那条单发 ✓✓）

    /**
     * 今天那条路的**全部既有语义**都留在里面 ✓（同一条重试 ✓ 同一套 `parseDecision`/`toAnswer` ✓）——
     * 提示词从"预取全塞的 `buildPrompt`"换成**有界档案**（`dossier.ts` ✓），
     * 并**加了一道硬期限**（今天没有 ✗ 见设计书 §3.4 ✓）。
     * `hint` 非空 = 任务层要的那次"只要答案行"的重试 ✓。
     */
    const runSingleShot = async (hint?: string): Promise<SingleShotCall> => {
      const attempt: SingleShotCall = { text: '', reasoning: '', truncated: false }
      try {
        rawKind = null                                  // 每次调用重新分段 ✓
        liveRaw('reasoning', '')
        // ★★★ 单发提示词的**组装点**（2026-10-17 主人批准的改动 ✓✓）：
        //   · 旧写法 = `buildPrompt(facts)` —— **把预取的全部数据原样嵌进去** ✗
        //     （船卡 + 每个计划的原始 JSON + 渲染好的候选表 + 散文 ✓）。
        //   · 新写法 = **预取 + 裁剪 + 硬字节预算** ✓（`dossier.ts` ✓）：
        //     船 essentials + 玩家的规则 + 能做什么 + 每个计划最好的 2~3 个候选与风险/收益数字 ✓，
        //     并且**超预算就按固定顺序继续裁、把裁了什么记下来** ✓（绝不静默 ✓）。
        //   ★ 两道渲染**彻底分开** ✓：agent 路径在 `task.ts`（一行通知 ✓），
        //     单发路径在这里（有界档案 ✓）—— 共享的只有**数据** ✓✓。
        const dossierPayload = dossierInputOf()
        const dossier = renderDossier({
          payload: dossierPayload,
          fallbackCard: (facts.card ?? {}) as DossierPayload,
          goalText: facts.goalText,
          goalOptions: facts.goalOptions,
          // ★★ 护航候选**必须**进单发档案 ✗✓（Trade 那一单没有它就判断不了风险能不能压到闸门内 ✓）
          escortCandidates: facts.escortCandidates,
          // ★ 记忆块是**单发路径专属**的拼装点 ✓（agent 那条路不给 ✓）——
          //   以前它是 `askModel(history)` 的第二个参数 ✗，现在直接进同一段文本 ✓（少一次历史拼装 ✓）。
          memoryBlock: hint === undefined ? memoryBlock : undefined,
          // ★ 只把"裁过头了"记进流水 ✓（正常情况一句话都不刷 ✓ —— 流水已经很吵了 ✓）。
          log: (l) => live(l),
        })
        if (hint === undefined) {
          live(`  ├ 单发档案：${dossier.stats.finalBytes} 字节 / 预算 ${dossier.stats.budgetBytes}` +
            `（未裁剪时 ${dossier.stats.untouchedBytes} 字节；候选 ${dossier.stats.rowsPerPlan} 行/计划）`)
          for (const d of dossier.stats.dropped) live(`  │ 裁剪：${d}`)
          rec.dossierBytes = dossier.stats
        }
        const r = await askModel(
          ctx, cfg,
          dossier.text +
            (prevFailHint !== undefined && prevFailHint !== ''
              ? `\n\n★ 上一单的结果：${prevFailHint}` : '') +
            (hint ?? ''),
          liveRaw,
          // ★ 历史参数**不再传** ✗：记忆块已经在 dossier 文本里 ✓（见上面的 memoryBlock ✓）。
          undefined,
        )
        attempt.text = r.text
        attempt.reasoning = r.reasoning
        attempt.truncated = r.truncated
        attempt.failure = r.failure
        if (r.failure !== undefined) return attempt
        // ★ 记录③"推理"（含思维链 ✓✓ —— 这是主人最想看的一段 ✓）
        rec.modelText = hint === undefined ? r.text : rec.modelText
        rec.reasoning = hint === undefined
          ? r.reasoning
          : (rec.reasoning ?? '') + String.fromCharCode(10) + '--- 重试（仅答案行）---'
            + String.fromCharCode(10) + r.reasoning
        rec.truncated = r.truncated
        live(`  ${hint === undefined ? '├' : '├ 重试回复 '}模型回复 正文 ${r.text.length} 字 / 思维链 ${r.reasoning.length} 字${r.truncated ? '  ⚠️被maxTokens截断' : ''}`)
        for (const line of r.reasoning.trim().split('\n')) {   // ★ 不截断（主人要看原始全过程 ✓）
          if (line.trim() !== '') live(`  │ ${line.trim()}`)   // ★ 思维链**逐行**进流水 ✓✓
        }
        if (hint === undefined) {
          // ★ 只有"**完全没有动作行**"这一种才值得再问一次 ✓（见上面的小段注释 ✓）。
          //   ★ 判据用**结构化事实**（`decision.action === undefined` ✓），
          //     不拿 `toAnswer` 那句话去 `includes()` 匹配 ✗ —— 那句文案改一个字，
          //     重试就静默失效 ✓（本仓库"靠字符串匹配同一个事实"踩过不止一次 ✓）。
          const decision = parseDecision(r.text)
          if (decision.action === undefined) attempt.retryHint = SINGLE_SHOT_RETRY_HINT
          void decision
        }
      } catch (error) {
        attempt.failure = `EXCEPTION: ${error instanceof Error ? error.message : String(error)}`
      }
      return attempt
    }

    /** 单发那一路的中止出口（把"为什么"原样报给游戏 ✓） */
    const failSingleShot = (why: string, last?: SingleShotCall): SingleShotFailure => {
      // ★ 重试那一路会把"两轮都不行"写进 `why` ✓ —— 那比只报最后一轮有用得多 ✓（见 singleShotWithRetry ✓）
      const detail = last?.why ?? why
      logger.warn(`avorion-copilot: 单发决策失败 ${detail}`)
      const truncated = last?.truncated === true
      return {
        ok: false,
        code: detail.startsWith('模型失败') || detail.includes('EXCEPTION') ? 'MODEL_FAILED' : 'BAD_MODEL_REPLY',
        message: detail,
        why: detail,
        text: last?.text,
      }
    }

    /** 把(可能重试过的)单发回复解析成结论 ✓（**解析器与今天逐字相同** ✓） */
    const answerFromText = (r: SingleShotCall): DecideAnswer | string => toAnswer(parseDecision(r.text), facts, r.text)

    /**
     * ★★ 单发路径的"**没有动作行 → 再问一次**"（把 2026-10-17 那条既有行为守住 ✓）。
     *
     * 为什么必须有这个包装 ✗✓（这是本鱼自己踩的坑）：重试原来同时活在**两处** ✓ ——
     *   index.ts 里一份 ✓、投递阶梯里一份 ✓。重构时只把阶梯那份做对了 ✗，
     *   于是"**没有指定会话**"这条**与今天逐字相同**的路径**静默丢掉了重试** ✗✓，
     *   而它正是实机事故（正文一个动作行都没吐 ✓）发生时**唯一会走**的那条 ✓。
     *   `test/order-payload.mjs` 的 g/g2 用例当场抓住了它 ✓✓。
     *
     * 规矩（与实机一致 ✓）：**同一批事实**再来一次 ✓、只要求"答案行在前、之后再写理由" ✓、
     *   ★ **只此一次** ✗（不循环 ✓）、**不重取数据** ✗ —— 两次都不行就照旧失败 ✓，
     *   **绝不替她编一个动作** ✗✓。
     */
    const singleShotWithRetry = async (): Promise<SingleShotCall> => {
      const first = await runSingleShot()
      if (first.failure !== undefined) return first
      const firstVerdict = answerFromText(first)
      try {
      } catch { /* ignore */ }
      if (typeof firstVerdict !== 'string') return first
      if (first.retryHint === undefined) return first
      live('  ├ ⚠ 首轮没有可用动作行 → **重试一次**：同一批事实，只要求答案行 ✓')
      const retry = await runSingleShot(first.retryHint)
      if (retry.failure !== undefined) return retry
      const retryVerdict = answerFromText(retry)
      if (typeof retryVerdict === 'string') {
        // ★ 两轮都要留在理由里 ✓（要看的是"为什么两次都没成" ✓；只报最后一轮会把第一轮的
        //   信息抹掉 ✗ —— 而那正是排查时最需要的一条 ✓）。措辞与既有实机事故记录一致 ✓。
        retry.why = `first attempt had no usable action line (text ${first.text.length} chars, `
          + `truncated=${first.truncated}); retry also failed: ${retryVerdict}`
        return retry
      }
      live('  ├ ✔ 重试成功（拿到动作行 ✓）')
      return retry
    }

    // ★ 会话那一级的两条注入点（投递 + 收答案 ✓）：
    //   · `followup` 用**现成的** `createUserMessage` + `source.kind='plugin'` ✓
    //     —— 所以她在会话里看到的是"插件投递"，不是主人在说话 ✓；
    //   · `subscribe` 走上面那个**唯一**的 session/event 监听器 ✓。
    // ★ v4 会话格式的 producer-owned source = `plugin:<插件名>` ✓
    //   （**不是** v3 的 `{ kind: 'plugin', plugin: '<包名>' }` 包裹形态 ✗ ——
    //   那个形态在会话格式 v4 下会被**原生准入**直接拒绝：
    //   "format v4 message requires a producer-owned source kind"，整个会话那一轮
    //   直接失败 ✗；v3→v4 迁移也正是把它提升成 `plugin:<包名>` ✓）。
    //   ★ 已发布的 npm 版 dsh-llm 的 MessageSourceMap 仍停在 v3 的那个联合 ✗，
    //   所以只在**构造处**断言一次（与 dsh-global-memory 同款做法 ✓）；
    //   运行时按 v4 原生准入走 ✓。
    type UserMessageSource = Parameters<typeof createUserMessage>[0]['source']
    const copilotSource = (): UserMessageSource =>
      ({ kind: 'plugin:@dsh-external/dsh-avorion-copilot' } as unknown as UserMessageSource)

    /**
     * ★★ 把任务块投进会话 —— 顺手**量一次体积** ✓✓（2026-10-17 主人批准的改动 ✓）
     *
     * 为什么必须在**投递处**量 ✗→✓：这次的全部理由是"投进去的东西太大"✓ ——
     * 那就得有一个**真实投递字节数**留在记录里 ✓，而不是靠事后估算 ✓。
     * ★ `cardCopies` 是同一件事的**回归探针** ✓：以前船卡在块里出现**两遍** ✓
     *   （块一遍 + 提示词一遍 ✓）—— 现在**必须是 0** ✗✓（数据一个字节都不进来 ✓）。
     */
    const BLOCK_TARGET_BYTES = 2_000
    const deliverToSession = (agent: AgentLike, block: string, _req?: unknown): void => {
      agent.followup(createUserMessage({
        content: [{ type: 'text', text: block }],
        source: copilotSource(),
      }))
      // 真投出去了才续租 ✓（主人能在 fleet_status 里看到"这条选择还新鲜 ✓"）
      try { renewLease() } catch { /* 续租失败不影响本轮 ✓ */ }
      try {
        const bytes = dossierByteLen(block)
        const cardCopies = block.split('"cargoCapacity"').length - 1
        rec.delivered = { blockBytes: bytes, cardCopies, targetBytes: BLOCK_TARGET_BYTES }
        const over = bytes > BLOCK_TARGET_BYTES ? ` ★ 超过目标 ${BLOCK_TARGET_BYTES} 字节 ✗` : ''
        live(`  ├ 投递块体积：${bytes} 字节（目标 < ${BLOCK_TARGET_BYTES} ✓）；块里船卡副本 ${cardCopies} 份（必须 0 ✓）${over}`)
      } catch { /* 量体积失败不影响投递 ✓ */ }
    }

    // ★ 失败回投时，单发路径的提示词里要带上一单失败原因（closure ✓；首轮为空 ✓）
    let prevFailHint: string | undefined
    // ★ 首轮与**回投**共用的投递依赖（依赖都已在上方定义 ✓）
    const dispatchDeps = {
      registry: (agents ?? { get: (): AgentLike | undefined => undefined, list: (): AgentLike[] => [] }) as {
        get(id: string): AgentLike | undefined
        list(): AgentLike[]
      },
      commanderId: (agents !== undefined && ctx.on !== undefined) ? targetSession() : undefined,
      subscribe: subscribeSession as any,
      followup: (agent: AgentLike, block: string) => deliverToSession(agent, block),
      prefetch: prefetchSingleShot,
      singleShot: runSingleShot,
      allowedActions: facts.goalOptions.length > 0 ? facts.goalOptions : [...ALL_ACTIONS],
      /**
       * ★★ 2026-10-20 真机丢单的修 ✓：校验前**当场重查**这艘船的动作边界 ✓✓。
       *
       * 真机证据（`moddata/copilot/decisions.live.log` 2026-10-20 14:32:19 逐字 ✓）：
       *   `[session] ✘ 校验没过：BAD_ACTION（action Mine 不在允许集合内（Travel, Sell, Scout，以及 None））`
       *   → `fallbackNone` → 船保持 `busy:false`；而同一刻 `fleet_query{what:'ship'}` 已是 `Mining:4` ✓，
       *   用 `fleet_order` 直下**一次就成** ✓。根因 = 校验拿**投递时**的 `facts.goalOptions` 快照当白名单 ✗。
       *
       * 这里与 `facts.goalOptions` **完全同源** ✓（游戏侧 `query{what:"goal"}` → `goal.describe`
       * → `Card.allowedActions` → `deriveActions` 现读炮塔/船长/货舱 ✓，见
       * `data/scripts/lib/copilot/goal.lua:147-182` 与 `card.lua:708-712`），
       * 所以"船刚加载完、炮塔还没恢复"那种过期快照会被**当场纠正** ✓✓。
       * 拿不到 → `undefined` → dispatch 退回投递时快照 ✓（绝不因为查不到就丢单 ✗）。
       */
      allowedActionsFor: async (name: string): Promise<string[] | undefined> => {
        const norm = (v: unknown): string[] | undefined => {
          if (!Array.isArray(v)) return undefined
          const list = v.filter((x): x is string => typeof x === 'string' && x !== '')
          // ★ 与上面 `facts.goalOptions` 同一口径 ✓：空 = 不限 → 全集 ✓
          return list.length > 0 ? list : [...ALL_ACTIONS]
        }
        const g = await ask(peer, 'query', { what: 'goal', ship: name }, 10)
        if (g.ok) {
          const opts = norm((g.data as Record<string, unknown> | undefined)?.options)
          if (opts !== undefined) return opts
        }
        const s = await ask(peer, 'query', { what: 'ship', ship: name, brief: true }, 10)
        if (s.ok) {
          const opts = norm((s.data as Record<string, unknown> | undefined)?.allowedActions)
          if (opts !== undefined) return opts
        }
        return undefined
      },
      mode: decideMode,
      steerWhenBusy,
      retrySessionOnce,
      lock: fleetSessionLock,
      log: live,
      // ★★ A（2026-10-18）：合并收集窗口 ✓（0 = 逐条投，旧行为 ✓）
      budgets: { mergeWindowMs },
    }
    // ★ 「上一单的结果」行（若有记录 ✓）；超 200 字节就**不附加**并在流水里说明 ✓。
    //   2026-10-17：措辞去掉"你" ✗→"上一单"（因为上一单可能是单发/兜底定的，不是她定的 ✗✓），
    //   来源由 renderPrevResult 的 `[decider]` 标签标明 ✓。
    const fitPrev = (body: string | undefined): string | undefined => {
      if (body === undefined || body.trim() === '') return undefined
      const full = `★ 上一单的结果：${body.trim()}`
      if (Buffer.byteLength(full, 'utf8') > PREV_RESULT_BUDGET_BYTES) {
        live(`  ├ 上一单结果行 ${Buffer.byteLength(full, 'utf8')} 字节 > ${PREV_RESULT_BUDGET_BYTES} → **不附加** ✓`)
        return undefined
      }
      return body.trim()
    }

    // ★★ 护航建议的计算在 `apply` 顶层（`escortHintFor` ✓）—— 这里是 decideInner ✓，
    //   只负责把它的结论塞进投递块 ✓。
    let outcome: DispatchOutcome
    if (agents === undefined || ctx.on === undefined) {
      // 拿不到会话服务 → 与今天完全一致 ✓（不绕远、不报错 ✓；**含那条重试** ✓）
      // ★ 单发路径的**轻量**预取在这里**急切**跑一次 ✓（船卡 + 舰队名单 + 记忆 ✓，
      //   **不含任何 legacy 计划** ✗ —— 2026-10-24 去掉了 ✓）。
      //   `rv` 仍留着那个约定（非 null = 预取阶段就定了这一单 ✓）；现在它恒为 null ✓，
      //   但分支保留 —— 将来若要恢复"预取阶段直接定单"，接回来的位置就在这里 ✓。
      const rv = await prefetchSingleShot()
      if (rv !== null) {
        rec.source = 'rendezvous'
        rec.answer = rv
        live(`  ├ 决策 [rendezvous] ${rv.action} ${JSON.stringify(rv.params)}  (${rv.reason ?? ''})`)
        return [true, rv]
      }
      const r = await singleShotWithRetry()
      if (r.failure !== undefined) {
        const fail = failSingleShot(`模型失败 ${r.failure}`, r)
        rec.source = 'none'
        return [false, fail.code, fail.message]
      }
      const a = answerFromText(r)
      outcome = typeof a === 'string'
        // ★ 失败理由用**我们记下的详版**（两轮都写进去了 ✓），不要用 `a` 那句单轮短句 ✗✓
        ? { action: 'None', params: {}, reason: r.why ?? a, source: 'none', text: r.text, truncated: r.truncated }
        : { action: a.action, params: a.params, reason: a.reason, source: 'single-shot', text: r.text, truncated: r.truncated }
    } else {
      const target = targetSession()
      live(`  ├ 决策来源：${target === undefined
        ? '**只走单发**（未指定投递目标会话 ✓）'
        : `优先投给会话 ${target}（模式=${decideMode}；忙时${steerWhenBusy ? '会插队' : '绝不打扰主人 ✗'}）`}`)
      live('  ├ 会话路径：未预取计划 ✓（投递前只取 goal；计划/船卡/记忆留给单发兜底或她自己查 ✓）')
      outcome = await dispatchDecision(dispatchDeps, {
        taskId: makeTaskId(),
        ship,
        goalText: facts.goalText,
        goalOptions: facts.goalOptions,
        // ★★★ 这里**故意**不再传数据 ✗✓（2026-10-17 主人批准的改动）：
        //   · `card: facts.card` —— 船卡曾经在这个块里出现**两遍** ✓（本块一遍 + 提示词一遍 ✓）；
        //   · `planText: buildPrompt(facts)` —— 那是**整份预取渲染**（8.7 MB 的入口 ✓）。
        //   → 现在 agent 路径**只告知**（`task.ts` ✓），数据她自己用工具拉 ✓（缺省 compact ✓）。
        //   ★ 单发那条路的档案是**另一个渲染**（`dossier.ts` ✓），两条路共享数据不共享渲染 ✓✓。
        deadlineHintSec: Math.round(BUDGETS.sessionDeadlineMs / 1000),
        // ★ 上一单结果（2026-10-17 补 ✓）：下一轮就能看到"上次成没成"，不触发回投也看得见 ✓
        //   ★★ 2026-10-20：**被拒理由优先** ✓（她那句话被校验拒了 → 下一次块里必须看见为什么 ✓）
        prevResult: fitPrev(takeRejectNote(ship) ?? lastResultFor(ship)),
        // ★★ B（2026-10-18）：漏答**必须可见** ✓ —— 块末尾一行「上次未答：X 艘」✓
        unansweredBefore: unansweredRetry.size,
        // ★★ 2026-10-24：护航建议（**只告知** ✓ 不替她下单 ✗）——
        //   数字来自**她自己量过的** `predict` / 下单回执 ✓（见上面的 `escortHintFor` ✓）；
        //   没量过 = 0 次查询 ✓；一次 `*Plan` 都没有 ✗✓。
        escortHint: await escortHintFor(ship),
      })
    }

    // ★ 三条出口：① 她的答案算数 ② 单发的答案算数 ③ 两条都没有（明说的 None ✓）
    //   —— 抽成纯函数：主路径与**失败回投**共用同一套"把阶梯结论落成最终答案"的逻辑 ✓
    const resolveAnswer = (o: DispatchOutcome): { answer?: DecideAnswer; failCode?: string; failMessage?: string } => {
      if (o.source === 'none') {
        // 单发那一路的细节要原样报给游戏 ✓（今天的行为：MODEL_FAILED / BAD_MODEL_REPLY ✓）
        const fail = failSingleShot(o.reason ?? '没有可用的决策', undefined)
        return { failCode: fail.code, failMessage: fail.message }
      }
      if (o.source === 'single-shot' || o.source === 'shadow') {
        const last: SingleShotCall = { text: o.text ?? '', reasoning: '', truncated: o.truncated === true }
        const a = answerFromText(last)
        if (typeof a === 'string') {
          const fail = failSingleShot(a, last)
          return { failCode: fail.code, failMessage: fail.message }
        }
        return { answer: { action: a.action, params: a.params, reason: a.reason, raw: o.text } }
      }
      // ★ 会话的答案直接可用 ✓（它已经在 dispatch 里按同一套契约校验过了 ✓）；'None' 也合法 ✓
      return { answer: { action: o.action, params: o.params, reason: o.reason, raw: o.text } }
    }

    const firstResolved = resolveAnswer(outcome)
    if (firstResolved.failCode !== undefined) {
      // ★ 影子模式下会话那一级**也**没成 —— 这本身就是主人要看的结论 ✓
      rec.source = outcome.source
      rec.session = outcome.session
      rec.agreement = outcome.agreement
      logger.warn(`avorion-copilot: ${ship} 没有任何可用的决策（${firstResolved.failMessage}）`)
      return [false, firstResolved.failCode, firstResolved.failMessage]
    }
    let answer: DecideAnswer = firstResolved.answer as DecideAnswer

    // ★ 记录④"结论"（先记下，⑤ 结果随后补 ✓）
    rec.source = outcome.source
    rec.session = outcome.session
    rec.agreement = outcome.agreement
    rec.answer = answer
    live(`  ├ 决策 [${outcome.source}] ${answer.action} ${JSON.stringify(answer.params)}  (${answer.reason ?? ''})`)

    // ★★ 待命裁定记录（2026-10-17 主人要求 ✓ / 2026-10-18 分级 ✓）：决策者判 None（非 rendezvous）→
    //   记下目标指纹，冷却期内同船不再征询 ✓（状态改变/冷却到期/手动召回后恢复 ✓）。
    //   ★★ C（2026-10-18）：**分清「漏答」与「判了 None」** ✗→✓：
    //     · `fallbackNone` / `asked-owner` = **没有决策**（会话忙/超时/没答到这艘船/在问主人）✗
    //       → `kind='unanswered'` → 短冷却 + 进重投队列 ✓（**绝不**罚 20 分钟 ✗）；
    //     · 其余（`session` 明确 action=None / `single-shot` 判 None）= **真的判了** ✓
    //       → `kind='none'` → 原来的 20 分钟冷却 ✓✓（这条一个字都没改 ✓）。
    if (answer.action === 'None' && outcome.source !== 'rendezvous') {
      const missCode = outcome.session?.code
      // ★ 只有这两种 source = **没有决策** ✗（`session`/`single-shot` 的 None 都是**她/它真的判了** ✓）；
      //   防御性地再看一眼「会话这一级是不是报了一个"没答到"的码」✓（见上面的 MISS_CODES ✓）
      const isLeak = outcome.source === 'fallbackNone' || outcome.source === 'asked-owner'
        || (outcome.source !== 'session' && outcome.source !== 'single-shot'
          && missCode !== undefined && MISS_CODES.has(missCode))
      const missKind: StandbyKind = isLeak ? 'unanswered' : 'none'
      let misses = 0
      if (missKind === 'unanswered') {
        const prior = unansweredRetry.get(ship)
        misses = (prior !== undefined ? prior.misses : 0) + 1
        // ★ 会话忙（主人在聊天）不算她的失败 —— 但这种"没答到"同样不能罚 20 分钟 ✓；
        //   计数器仍然记（否则会话一直忙 → 无限重投 ✓）。
      }
      const entry = recordStandby(
        ship,
        outcome.source,
        answer.reason ?? '',
        goalFingerprintOf(facts.goalText, facts.goalOptions),
        Date.now(),
        { kind: missKind, misses, maxMisses: unansweredMaxMisses },
      )
      if (missKind === 'unanswered' && entry.kind === 'unanswered') {
        // ★ B：短重试 —— 记下来，到点**重新投递** ✓（不罚 20 分钟 ✗）
        unansweredRetry.set(ship, {
          misses,
          atMs: unansweredRetry.get(ship)?.atMs ?? Date.now(),
          nextAtMs: Date.now() + unansweredRetryMs,
        })
        live(`  ├ ★ 漏答（不是决策 ✗）：${ship} 这一轮没答到（来源 ${outcome.source}` +
          `${missCode !== undefined ? ` / ${missCode}` : ''}；第 ${misses}/${unansweredMaxMisses} 次）` +
          `→ **${Math.round(unansweredRetryMs / 1000)}s 后重投** ✓（不进 ${Math.round(noneCooldownMs / 60000)} 分钟冷却 ✓）`)
        // ★★ 2026-10-20：答复被拒的**理由必须回给会话** ✓ —— 下一次投递块里带一行 ✓
        if (missCode !== undefined && REJECT_FEEDBACK_CODES.has(missCode)) {
          const why = outcome.session?.message ?? outcome.session?.code ?? ''
          const body = rejectBody(missCode, why)
          rejectNotes.set(ship, { text: body, atMs: Date.now() })
          live(`  ├ ★ 拒绝理由回给会话 ✓：下次投递块会带「${body}」`)
        }
      } else if (missKind === 'unanswered') {
        unansweredRetry.delete(ship)
        live(`  └ ★ 连续 ${misses} 次没答到 → 落到 None + ${Math.round(noneCooldownMs / 60000)} 分钟冷却 ✓` +
          '（会话一直答不上来，先别无限打扰主人 ✓）')
      } else {
        unansweredRetry.delete(ship)
        live(`  ├ 待命裁定：${ship} 被**明确判为待命**（来源 ${outcome.source}）→ ` +
          `冷却 ${Math.round(noneCooldownMs / 60000)} 分钟内不再征询 ✓`)
      }
    } else if (answer.action !== 'None') {
      // ★ 这一单真的定了动作 → 清掉漏答计数 ✓（下一次漏答重新从 1 数 ✓）
      unansweredRetry.delete(ship)
      // ★ 已经答对了 → 那条"上次被拒"的一次性提示也作废 ✓（不再回给会话 ✗）
      rejectNotes.delete(ship)
    }

    logger.info(
      `avorion-copilot: ${ship} -> ${answer.action} ${JSON.stringify(answer.params)}` +
      `  来源=${outcome.source}` +
      (answer.reason !== undefined ? `  (${answer.reason})` : '') +
      (outcome.truncated === true ? '  [被 maxTokens 截断]' : '') +
      ((rec.reasoning ?? '').length > 0 ? `\n--- 思维链 ---\n${(rec.reasoning ?? '').trim()}` : ''),
    )

    /** 坐标后缀（`@(x,y)`；没有就不写 ✓） */
    const locOf = (params: Record<string, unknown>): string =>
      typeof params.x === 'number' && typeof params.y === 'number' ? ` @(${params.x},${params.y})` : ''

    // ★ 真下单（DSH 主动调游戏的 order ✓✓；游戏侧走两段式 ✓）。
    //   ★★ 幂等闸（2026-10-17 ✓）：同一艘船同一刻只允许一条在飞的 order ✓（TAKEOVER.md 铁律 ✓）。
    const orderShip = async (a: DecideAnswer): Promise<OrderReceipt> => {
      const at = new Date().toISOString()
      if (a.action === 'None') {
        return { at, accepted: false, executed: false, error: 'action=None（本轮不下单 ✓）' }
      }
      if (ordersInFlight.has(ship)) {
        logger.warn(`avorion-copilot: ${ship} 已有一条 order 在飞 → **丢掉这一条** ✗（防同一艘船两条矛盾命令 ✓）`)
        live(`  └ ⚠ ${ship} 已有一条 order 在飞 → 丢掉本条（幂等闸 ✓）`)
        rec.orderResult = { dropped: 'another order for this ship is already in flight' }
        return { at, accepted: false, executed: false, error: 'another order for this ship is already in flight' }
      }
      ordersInFlight.add(ship)
      let ord: { ok: boolean; data?: any; why?: string }
      try {
        // ★ 60s：order 现在附带一次「回执风险」预测（与 predict 同一份代码 ✓），给足余量 ✓
        ord = await ask(peer, 'order', { ship, action: a.action, ...a.params }, 60)
      } finally {
        ordersInFlight.delete(ship)
      }
      // ★ 记录⑤"结果"（下单回执 ✓）
      rec.orderResult = ord.ok ? ord.data : { failed: ord.why ?? 'unknown' }
      const receipt = receiptOf(ord, at)
      if (receipt.accepted && receipt.executed) {
        // ★ 增量 2：把"我们交给它的活"记下来 ✓ —— 下一轮它变空闲时就能结算 ✓✓
        rememberStart(ship, a.action, a.params, sectorKey)
        const hours = typeof a.params.duration === 'number' ? a.params.duration : undefined
        pendingJobs.set(ship, {
          atMs: Date.now(), action: a.action,
          goodName: typeof a.params.goodName === 'string' ? a.params.goodName : undefined,
          hours, sector: sectorKey,
        })
        logger.info(`avorion-copilot: 已下单 ${ship} -> ${a.action} → ${JSON.stringify(ord.data)}`)
        // ★ 游戏侧对**这一单**的伏击评估（2026-10-17 ✓）：进 decisions.live.log，主人现场看得见 ✓
        const rt = riskText(receipt.risk)
        if (rt !== undefined) live(`  ├ ${rt}（游戏侧评估 ✓）`)
        // ★★ 实测（2026-10-17 第二轮 ✓✓）：startCommand 之后**再问游戏要结果** ✓。
        //   为什么在这里等 ✗→✓：这单的委托是"下单"，而主人的要求是"回执要带结果" ✓ ——
        //   不等到实体状态有证据就返回，就又变成"接了就完" ✗✓。
        //   ★ 有界（预算 18s：6s startCommand + 6s 采样 + 余量 ✓）+ 拿不到就是拿不到（不编 ✓）；
        //   ★ 老游戏侧（没有 orderId / 没有 orderStatus）→ 立刻跳过，一秒都不等 ✓。
        if (receipt.orderId !== undefined) {
          live(`  ├ 等实测：orderId=${String(receipt.orderId)}（startCommand 之后重读实体状态 ✓）`)
          const v = await waitForOrderVerify(peer, { orderId: receipt.orderId, ship }, { budgetMs: 18_000 })
          if (v !== undefined) {
            receipt.verify = v
            const vt = verifyText(v) ?? '实测（无结论）'
            live(`  ├ 实测：${vt}`)
            if (v.ok === false) {
              logger.warn(`avorion-copilot: ${ship} -> ${a.action} **下单后实测没有成功证据**（${v.reason ?? '状态未变'}）`)
            }
          } else {
            live('  ├ 实测：游戏侧没给结论（老版本 / 记录已过期）→ 回执保持 pending ✓（不编 ✗）')
          }
        }
      } else if (receipt.unconfirmed === true) {
        // ★★ 假阴性（超时/断连）：order 已送出、游戏可能已经在跑 ✗✓ ——
        //   **绝不判失败、绝不回投** ✗（否则同一艘船两条矛盾命令 ✓）。
        //   落一条 WARN（可见 ✓）并写清"已发送未确认"，下一轮用 list/ship 的 busy/舱量核实 ✓。
        rec.orderResult = { sent: true, unconfirmed: true, why: ord.why }
        logger.warn(`avorion-copilot: ${ship} -> ${a.action} **已发送，未确认**（${receipt.note ?? ord.why ?? ''}）→ 不回投 ✓，下一轮用 list/ship 核实 busy/舱量 ✓`)
      } else {
        logger.warn(`avorion-copilot: 下单失败 ${receipt.error ?? ord.why ?? ''}`)
      }
      return receipt
    }

    let receipt = await orderShip(answer)

    // ★★ 失败回投（2026-10-17 主人要求 ✓✓）：下单失败/被拒/未执行（或 RPC 根本没到游戏）→
    //   自动**重新投递一个决策任务**给同一个目标（会话空闲则投 ✓；否则走既有阶梯 ✓），
    //   块里带上一单的失败原因；同一艘船同一失败原因的连续回投有上限+退避 ✓。
    // ★★ 2026-10-17 主人铁律：**None 不是失败** ✗✓ —— 它是"本轮不下单"的正常裁定，
    //   **绝不**触发回投（否则会把"待命"重新拿去问、甚至被兜底改判成下单 ✗✓）。
    if (answer.action !== 'None' && receiptFailed(receipt)) {
      const decideStart = Date.now()
      let reason = receiptFailText(receipt)
      const redeliveries: DecisionRecord['redeliveries'] = []

      while (true) {
        // —— 上限：同一艘船同一失败原因的连续回投最多 REDELIVER_MAX 次 ✓
        const memo = redeliverMemo.get(ship)
        const prior = (memo !== undefined && memo.reason === reason) ? memo.count : 0
        if (prior >= REDELIVER_MAX) {
          rec.needsIntervention = `同一失败原因（${reason}）已连续回投 ${REDELIVER_MAX} 次 → 停止，需人工介入 ✓`
          live(`  └ 回投已达上限（${reason} × ${REDELIVER_MAX}）→ **需人工介入** ✗`)
          break
        }
        // —— 退避 + decide 时间预算（游戏侧 decide 超时 90s ✓）
        if (Date.now() - decideStart > REDELIVER_DECIDE_BUDGET_MS) {
          rec.needsIntervention = `回投超出 decide 时间预算（${REDELIVER_DECIDE_BUDGET_MS}ms）→ 停止，需人工介入 ✓`
          live('  └ 回投超出 decide 时间预算 → 停止（需人工介入 ✗）')
          break
        }
        redeliverMemo.set(ship, { reason, count: prior + 1, atMs: Date.now() })
        await new Promise((r) => setTimeout(r, REDELIVER_BACKOFF_MS))

        // —— 块里带上一单失败原因 ✓（带 decider 来源标签，不冒名 ✓）
        const deciderTag = deciderOf(outcome.source)
        const failBody = `${deciderTag !== undefined ? `[${deciderTag}] ` : ''}${answer.action}${locOf(answer.params)}：${reason} —— 请重新决策`
        const prevResult = fitPrev(failBody)
        prevFailHint = prevResult
        live(`  ├ 回投 #${prior + 1}：上一单 ${answer.action}${locOf(answer.params)} ${reason} → 重新投递决策任务 ✓`)

        const reOutcome = await dispatchDecision(dispatchDeps, {
          taskId: makeTaskId(),
          ship,
          goalText: facts.goalText,
          goalOptions: facts.goalOptions,
          deadlineHintSec: Math.round(BUDGETS.sessionDeadlineMs / 1000),
          prevResult,
          unansweredBefore: unansweredRetry.size,
          // ★★ 2026-10-24：回投也带护航建议 ✓（同一艘船、同一份观测 ✓ —— 只告知 ✓）
          escortHint: await escortHintFor(ship),
        })
        prevFailHint = undefined
        const reResolved = resolveAnswer(reOutcome)
        if (reResolved.failCode !== undefined) {
          redeliveries.push({ at: new Date().toISOString(), reason, note: `回投决策没能给出结论：${reResolved.failMessage}` })
          rec.needsIntervention = `回投决策没能给出结论（${reResolved.failMessage}）→ 停止，需人工介入 ✓`
          break
        }
        const next = reResolved.answer as DecideAnswer
        outcome = reOutcome
        answer = next
        rec.source = reOutcome.source
        rec.session = reOutcome.session
        rec.agreement = reOutcome.agreement
        rec.answer = next
        live(`  ├ 回投决策 [${reOutcome.source}] ${next.action} ${JSON.stringify(next.params)}  (${next.reason ?? ''})`)
        if (next.action === 'None') {
          redeliveries.push({ at: new Date().toISOString(), reason, action: 'None', note: next.reason })
          receipt = { at: new Date().toISOString(), accepted: false, executed: false, error: '回投后决定本轮不下单（action=None）' }
          break
        }
        receipt = await orderShip(next)
        redeliveries.push({ at: new Date().toISOString(), reason, action: next.action, params: next.params, receipt })
        if (!receiptFailed(receipt)) {
          redeliverMemo.delete(ship)
          live('  └ 回投成功：新单已接受 ✓')
          break
        }
        reason = receiptFailText(receipt)
      }
      if (redeliveries.length > 0) rec.redeliveries = redeliveries
    }

    rec.receipt = receipt
    return [true, answer]
  }

  // ---------------------------------------------------------------------------
  // ★★ B：漏答**重投**（2026-10-18，主人原话「我感觉你总是会漏」✓✓）
  //
  // 为什么要有它 ✗→✓：`unansweredRetry` 里记着"这一轮没答到"的船 ✓，而**光靠游戏**是不行的 ✗：
  //   `data/scripts/net/fleet.lua:31` 的 `REDECIDE_COOLDOWN = 300` 意味着**5 分钟**才重问一次 ✓，
  //   主人要的是 **2~3 分钟**就重投 ✓。所以插件自己定时重投 ✓✓。
  //
  // ★ 三条纪律（每一条都对着一个坑 ✓）：
  //   ① **会话忙不算她的失败** ✓ —— 主人在聊天时只推迟、**不投**、**不计数** ✓
  //      （C 项：这不是决策，是漏 ✓）；
  //   ② **船不空/不在名单就不碰** ✓ —— 绝不打断主人正在开的船、也不给已经在干活的船插单 ✗✓；
  //   ③ **共用一个 `runDecide`** ✓ —— 重投 = 真的重走一遍决策（含 merge 合并块 ✓），
  //      不是另开一条捷径 ✓✓。
  // ---------------------------------------------------------------------------
  // ★ 心跳间隔**跟重投间隔走** ✓（重投 3 分钟 → 30s 一跳；测试里重投 600ms → 200ms 一跳 ✓）
  const RETRY_TICK_MS = Math.max(200, Math.min(30_000, Math.round(unansweredRetryMs / 4)))
  let retryTickBusy = false

  const retryUnansweredTick = async (): Promise<void> => {
    if (retryTickBusy) return
    retryTickBusy = true
    try {
      if (unansweredRetry.size === 0) return
      const now = Date.now()
      for (const [ship, e] of [...unansweredRetry.entries()]) {
        if (e.running === true) continue
        if (now < e.nextAtMs) continue
        // 太久了就不再重投（游戏侧下一轮空闲期会自己重问 ✓）—— 绝不无限刷 ✗
        if (now - e.atMs > Math.max(unansweredRetryMs * 4, 10 * 60_000)) {
          unansweredRetry.delete(ship)
          live(`  ├ 漏答重投：${ship} 已超过重投窗口 → 放弃（等状态变化/游戏下一轮 ✓）`)
          continue
        }
        // ① 会话忙 → 推迟，**不算漏、不计数** ✓
        const target = targetSession()
        const agent = target !== undefined ? agents?.get(target) : undefined
        if (target !== undefined && agent !== undefined && agent.status !== 'idle') {
          e.nextAtMs = now + Math.min(60_000, unansweredRetryMs)
          live(`  ├ 漏答重投：${ship} —— 投递会话正忙 → 推迟（**这不是漏** ✓，不计数 ✓）`)
          continue
        }
        // ② 船已经忙 / 不在名单 → 取消重投 ✓（绝不碰主人正在开的船 ✗）
        let skip: string | undefined
        try {
          const fr = await ask(peer, 'query', { what: 'fleet' }, 10)
          if (fr.ok) {
            const raw = (fr.data ?? {}).ships
            const list: Array<Record<string, unknown>> = Array.isArray(raw)
              ? raw as Array<Record<string, unknown>>
              : (raw !== null && typeof raw === 'object' ? Object.values(raw) as Array<Record<string, unknown>> : [])
            const hit = list.find((s) => s.name === ship)
            if (hit === undefined) skip = '不在名单里'
            else if (hit.busy === true) skip = '已经忙起来了'
          }
        } catch { /* 拿不到快照就照旧试一次 ✓ */ }
        if (skip !== undefined) {
          unansweredRetry.delete(ship)
          live(`  ├ 漏答重投：${ship} ${skip} → 取消重投 ✓`)
          continue
        }
        e.running = true
        clearStandby(ship)      // ★ 清掉短冷却，让 decideInner 真的重新征询 ✓
        live(`  ├ ★ 漏答重投：${ship}（第 ${e.misses}/${unansweredMaxMisses} 次没答到）→ 现在重新投递 ✓`)
        try {
          await runDecide({ ship, hasGoal: true })
        } catch (error) {
          live(`  ├ 漏答重投异常：${ship} ${String(error)}`)
        } finally {
          e.running = false
          // decideInner 会更新/删除这条记录 ✓；它还在（仍未答到）就把下一次挪后 ✓
          const cur = unansweredRetry.get(ship)
          if (cur !== undefined && cur.nextAtMs <= Date.now()) cur.nextAtMs = Date.now() + unansweredRetryMs
        }
      }
    } finally {
      retryTickBusy = false
    }
  }

  // ---- 我调游戏（DSH 主动查询 / 下单）---------------------------------------
  /** 查一次舰队快照（"眼睛" ✓ —— 不用截图 ✓） */
  const queryFleet = (cb?: (ok: boolean, data?: any, why?: string) => void): boolean =>
    peer.call('query', { what: 'fleet' }, cb, 5)

  const queryShip = (ship: string, cb?: (ok: boolean, data?: any, why?: string) => void): boolean =>
    peer.call('query', { what: 'ship', ship }, cb, 5)

  const order = (ship: string, action: string, params: Record<string, unknown> = {}, cb?: (ok: boolean, data?: any, why?: string) => void): boolean =>
    peer.call('order', { ship, action, ...params }, cb, 15)

  const reload = (cb?: (ok: boolean, data?: any, why?: string) => void): boolean =>
    peer.call('reload', {}, cb, 10)

  // 连上后打一份舰队快照到日志 —— 既是握手确认，也是"眼睛"的第一次使用 ✓
  peer.onConnected = () => {
    logger.info('avorion-copilot: 游戏已连接，查询舰队快照…')
    queryFleet((ok, data, why) => {
      if (!ok) {
        logger.warn(`avorion-copilot: query fleet 失败 ${why ?? ''}`)
        return
      }
      // ★ 空的 Lua 表被 cJSON 编成 {}（不是 []）✗ —— 两种都当空列表处理 ✓
      const rawShips = data?.ships
      const ships: any[] = Array.isArray(rawShips)
        ? rawShips
        : (rawShips !== null && typeof rawShips === 'object' ? Object.values(rawShips) : [])
      logger.info(`avorion-copilot: 名单 ${data?.designated ?? '?'} 艘，快照 ${ships.length} 条（玩家在开：${data?.piloted ?? '?'}）`)
      for (const s of ships) {
        logger.info(
          `  - ${s.name} busy=${s.busy} captain=${s.hasCaptain}` +
          (s.status !== undefined ? ` status=${String(s.status).slice(0, 40)}` : ''),
        )
      }
    })
  }

  // ---- 生命周期 --------------------------------------------------------------

  ctx.effect(() => {
    void peer.listen().catch((err) => {
      logger.warn(`avorion-copilot: 监听 ${cfg.port} 失败（${String(err)}）—— 插件不会工作`)
    })
    return () => {
      logger.info('avorion-copilot: 关闭 RPC')
      peer.close()
    }
  }, 'dsh-avorion-copilot:rpc')

  // ★★ B（2026-10-18）：漏答重投的**心跳** ✓（20s 一跳；只处理到点的条目 ✓）
  ctx.effect(() => {
    const timer = setInterval(() => { void retryUnansweredTick() }, RETRY_TICK_MS)
    // ★ 别让定时器把 Node 进程钉住（DSH 关闭时要能退 ✓）
    if (typeof timer.unref === 'function') timer.unref()
    return () => clearInterval(timer)
  }, 'dsh-avorion-copilot:unanswered-retry')

  // ★ 把游戏能力暴露成 DSH 工具（主人要的"会话接管"就靠它们 ✓✓）
  registerFleetTools(ctx, peer, decisionLog, {
    current: getCommanderSessionId,
    set: (session) => setCommanderSession(session),
    state: () => getCommanderState(),
    // ★ 租约只用于**状态显示** ✓ —— 真正能不能投递看 `agents.get(id)` 是否活着 ✓（见 commander.ts ✓）
    leaseFresh: (now?: number) => isLeaseFresh(now !== undefined ? { now } : {}),
    agent: (id: string) => agents?.get(id),
    file: COMMANDER_FILE,
    /**
     * ★ 「**从这个会话打开，就是这个会话接管**」（主人原话 ✓）。
     *
     * `ctx.agents.currentInitiator()` 正是干这个的 ✓（证据：`dsh-goal-round-driver/lib/index.js:173`
     * 用 `ctx.agents.withoutInitiator(...)` / `:237` 用 `currentInitiator()` ✓ ——
     * 它把"发起这次调用的那个 Agent"传下去 ✓）。
     * → 所以主人在会话里说一句"接管舰队"，工具就能**自己认出是哪个会话** ✓✓，
     *   不用他去别处抄一个 id 过来 ✓。
     *
     * ★ 拿不到就返回 undefined ✓ —— 那时工具会**明确要求**显式给 `session=` 参数 ✓
     *   （绝不猜 ✗：猜错就是把任务塞进别人的聊天 ✓）。
     */
    currentSessionId: () => {
      try {
        const reg = agents as unknown as { currentInitiator?: () => { id?: unknown } | undefined } | undefined
        const initiator = reg?.currentInitiator?.()
        return (initiator !== undefined && typeof initiator.id === 'string') ? initiator.id : undefined
      } catch { return undefined }
    },
  }, {
    // ★ 待命裁定（2026-10-17 ✓）：fleet_recall / fleet_goal 会清掉同船的 None 冷却 ✓
    clear: (ship: string) => clearStandby(ship),
  }, {
    // ★★ 护航观测（2026-10-24 ✓）：她把 `predict` / `fleet_order` 的数字拿到手时记一笔 ✓
    //   —— 下一轮投递块的「护航建议」就靠它 ✓（只告知 ✓ 不替她下单 ✗）。
    onRiskObserved: noteRiskObservation,
  })

  // 供将来从 DSH 侧主动操作（例如命令面板、定时巡检）使用 ✓
  void queryShip
  void order
  void reload
}
