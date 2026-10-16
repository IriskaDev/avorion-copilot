/**
 * @dsh-external/dsh-avorion-copilot —— Avorion `copilot` mod ⇄ DSH 的桥接插件。
 *
 * ## 本版（RPC 版）
 *
 * 传输从「文件桥」换成「**TCP + 对称 RPC**」✓（协议见 mod 仓库的 PROTOCOL.md v2）。
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

// ★ 把提示词相关通知接到实时流水 ✓（live 是函数声明，已提升 ✓）
setPromptNotifier(live)
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
  get?(name: string): unknown
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
export interface DecisionRecord {
  at: string
  ship: string
  goalText: string
  goalOptions: string[]
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

/** 在飞的任务（增量 2）：ship -> 我们交给它的活，等它变空闲时结算 ✓ */
const pendingJobs = new Map<string, {
  atMs: number; action: string; goodName?: string; hours?: number; sector?: string
}>()

const DEFAULTS = {
  port: 8765,
  provider: 'deepseek-official',
  model: 'deepseek-flash',
  maxTokens: 2000,   // ★ 700 不够：模型会把额度烧在思维链上，正文被截断 → 解析失败 ✗
  temperature: 0.2,
}
/**
 * ★★★ 系统提示词现在**放在文件里**（2026-10-17 主人要求："prompt 能搞成单独的文件，让程序运行时读取"）
 *
 *   ① 用户覆盖: %AppData%\Avorion\moddata\copilot\prompt\system.md   ← 改它**不用重启 DSH** ✓✓
 *   ② 插件自带: <插件目录>\prompt\system.md                          ← 随仓库走 ✓
 *   ③ 编译兜底: src/prompt-default.ts（由 prompt/system.md 生成 ✓）
 *
 * 读法与替换都在 src/promptfile.ts ✓；机制段仍是单一来源（mod 仓库的 MECHANICS.md ✓）。
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
  duration?: number
  /** ★ Mine/Salvage 专用：安全模式（原版把伏击概率 ×0.1 ✓）—— 2026-10-17 补 ✓ */
  safeMode?: boolean
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
export const ALL_ACTIONS = ['Mine', 'Salvage', 'Trade', 'Travel', 'Sell', 'Scout'] as const

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
  /** ★ 贸易候选（只有 Trade 船才有）：游戏算出来的真实路线表 ✓ */
  tradeRoutes?: unknown
  /**
   * ★★ Mine / Salvage 的候选（只有对应动作在"允许的动作"里才有 ✓）：游戏侧算好的真实计划 ✓
   *   —— 与 tradeRoutes 同款做法 ✓✓（2026-10-17 补）
   *   形状：游戏侧 query { what = minePlan | salvagePlan } 的返回，**已裁成**给模型看的那份 ✓
   */
  jobPlans?: Array<{ action: string; plan: Record<string, unknown> }>
  /** ★ 卖货计划（船上有货时才有）：把货在 ≤10% 风险下变现 ✓ */
  sellPlan?: Record<string, unknown>
  /** 勘察计划（能勘察的船才有）：揭开的新地图 + 离地图中心多远 */
  scoutPlan?: Record<string, unknown>
  /**
   * ★★ 这次**没取到**的计划 ✗✓（2026-10-17 实测血案补 ✓）
   *
   * 为什么必须有它 ✗：游戏侧算好了计划 ✓（rpc_trace 里有 `推荐=longest/Titanium` ✓），
   * 但响应因为 bug/重连丢了 ✗ → 插件只打一行日志就 `continue` ✗✓ → 模型拿到的是
   * **什么都没有** ✓，于是它以为「**没有候选**」✗✓ 而开始瞎猜 ✓✓。
   * "取不到" 与 "确实没有候选" 是**两个完全不同的事实** ✗ —— 必须让模型分得清 ✓。
   */
  planFetchFailures?: Array<{ what: string; why: string }>
}

/**
 * 把游戏侧 jobPlan 的巨型返回**裁成**喂模型的那份 ✓
 *
 * 为什么不整份丢给模型 ✗：一份 minePlan 的原始返回约 37 KB（含 9 个区域 × 各参数档 ×
 * 逐材料明细 ✓），token 太贵且噪声太多 ✓。模型真正要的是：
 *   * scoreBasis  —— 分数**到底怎么算的**（口径必须可见 ✓）
 *   * capability  —— 这艘船采得动什么（原版权威口径 ✓）
 *   * recommendation / riskWarning —— 有解还是无解 ✓
 *   * orderHint   —— 评分器选中的那一档所对应的参数（x/y 绝对坐标 + duration + safeMode + escorts ✓；只是参考 ✓）
 *   * areaRanking —— 裁成标量，用来横向比区域 ✓
 * 逐材料的完整明细留在**推荐**那一份里（人要审计时看它 ✓），其余区域只给标量 ✓。
 */
function compactJobPlan(p: Record<string, unknown>): Record<string, unknown> {
  const rank = Array.isArray(p.areaRanking) ? (p.areaRanking as Record<string, unknown>[]) : []
  const areas = rank.map((e) => ({
    offset: (e.area as Record<string, unknown> | undefined)?.offset,
    acceptable: e.acceptable,
    // ★★ 风险判定必须活到模型眼前（2026-10-17 修 ✗）：游戏侧经 informOnly 算了这三个字段 ✓，
    //    而这里以前**只挑数字、把结论丢掉** ✗ → 模型看不到"谁越了玩家的闸门" ✓✓。
    riskLimit: e.riskLimit,
    exceedsRiskLimit: e.exceedsRiskLimit,
    satisfiesPlayerRiskRule: e.satisfiesPlayerRiskRule,
    bestTag: e.bestTag,
    valueLow: e.valueLow,
    valueHigh: e.valueHigh,
    attackChance: e.attackChance,
    topTier: e.topTier,
    topMaterial: e.topMaterial,
    fieldTier: e.fieldTier,
    duration: e.duration,
    safeMode: e.safeMode,
    parameterTags: e.parameterTags,
    error: e.error,
  }))
  return {
    scoreBasis: p.scoreBasis,
    weightSource: p.weightSource,
    weights: p.weights,                 // 层级权重表（原版 costFactor / 矿价 ✓ —— 能审计 ✓）
    capability: p.capability,           // ★ 这艘船到底采得动什么 ✓
    rarity: p.rarity,                   // Salvage：稀有度混合表 + E[层级] ✓
    durationChoices: p.durationChoices, // 原版 duration 合法区间 ✓
    recommendation: p.recommendation,   // null/缺省 = 没有档位过闸门 ✗ → 看 riskWarning ✓
    riskWarning: p.riskWarning,
    decisionNote: p.decisionNote,       // ★ informOnly 的说明（"这是事实与选项，选哪个由你定" ✓）
    orderHint: p.orderHint,             // ★ 其中一组的下单参数（x/y 绝对坐标 ✓）—— 是参考，不是必须照抄 ✓
    areasScanned: p.areasScanned,
    scanMs: p.scanMs,
    scanNote: p.scanNote,
    areaRanking: areas,
    note: p.note,
  }
}

/** 组一份给模型看的请求：目标 + 边界 + 事实 ✓ */
function buildPrompt(f: DecideFacts): string {
  const lines: string[] = []
  lines.push(`船：${f.ship}`)
  lines.push('')
  lines.push('玩家给这艘船设定的运营目标：')
  lines.push(f.goalText !== '' ? f.goalText : '(玩家没有写文字目标，只给了下面的动作边界)')
  lines.push('')
  lines.push('允许的动作：')
  lines.push(f.goalOptions.length > 0 ? f.goalOptions.join(', ') : '(玩家没有限制 —— 你可以从 Mine / Salvage / Trade / Sell / Travel / Scout 里选)')
  lines.push('')
  lines.push('这艘船的现状（能力卡）：')
  lines.push(JSON.stringify(f.card ?? {}, null, 2))
  lines.push('')
  if (f.planFetchFailures !== undefined && f.planFetchFailures.length > 0) {
    // ★★ 「没取到」必须与「没有候选」分开说 ✗✓（2026-10-17 实测血案 ✓）
    lines.push('★★ 这次**没取到**下面这些计划 ✗✓ —— 这是**取数失败**，')
    lines.push('   **并不代表那里没有候选** ✗✗（计划可能根本是好的 ✓，只是这次没传过来 ✓）：')
    for (const pf of f.planFetchFailures) {
      lines.push(`  · ${pf.what} 取失败，原因：${pf.why}`)
    }
    lines.push('  → 所以：不要据"它没来"就断定"没得挖/没得捞" ✗；')
    lines.push('    你可以再等一轮、换个动作、先侦察/换位置、或者先做别的 —— **由你判断** ✓。')
    lines.push('')
  }
  if (f.jobPlans !== undefined && f.jobPlans.length > 0) {
    // ★★ Mine / Salvage 的真实计划（游戏侧算好的 ✓ —— 2026-10-17 补）
    //   之前 Mine/Salvage 是**瞎猜**的 ✗：卡片只说"15x15、要船长、产出进全局资源"，
    //   模型不知道区域里有什么矿、这船采得动什么、伏击概率多少 ✗ → 只能挑自己所在星区 ✓。
    for (const jp of f.jobPlans) {
      lines.push(`★★ 游戏侧算好的 ${jp.action} 计划（多区域 × 参数（时长/安全模式/护航）× 层级加权 ✓）：`)
      lines.push(JSON.stringify(jp.plan, null, 2))
      lines.push('')
    }
    lines.push('★ 上面这份计划的读法（与系统提示一致 ✓）：')
    lines.push('  · 这是**评分器给的参考** ✓，不是必须照抄的答案 ✗ —— 每一档的数字都可以自己比 ✓')
    lines.push('  · recommendation = 评分器选的那一档（只代表它认为最好 ✓，你可以不同意 ✓）')
    lines.push('  · orderHint = 该档对应的下单参数（x/y 是**绝对星区坐标** ✓）；★ 不照抄也是允许的 ✓')
    lines.push('  · exceedsRiskLimit=true 的档位**照样列出来了** ✓：它超出玩家闸门，但数字你应该看 ✓')
    lines.push('  · recommendation 缺省/为 null + riskWarning 有字 = **一个档位都没过闸门** ✗ →')
    lines.push('    回 action=None 并说明理由（可为它派护航 / 换区域 / 换船 ✓）')
    lines.push('  · Mine 看 valueLow/valueHigh（材料层级加权产量，**不是吨位** ✗）与 topTier/topMaterial ✓')
    lines.push('  · Salvage 看 recommendation.items（装备件数 ✓ 主角）与 rarity.expectedTier ✓、fieldTier（次级键 ✓）')
    lines.push('  · capability.materials[i].dps = 0 表示这艘船**完全采不动**那种材料 ✗（别派它去 ✗）')
    lines.push('')
  }
  if (f.tradeRoutes !== undefined) {
    // ★★ 把游戏算出来的**真实贸易路线表**给模型 ✓✓（2026-10-16 补）
    //   之前不给 ✗ → 模型只能猜"就地贸易"，完全不知道有更赚钱的货可选 ✗。
    //   注意让模型按 **profitPerSize（每体积绝对利润 ✓）** 比较，而不是百分比 ✓。
    lines.push('本区域的贸易候选（★ 按 profitPerSize = 每体积绝对利润 比较，越大越好；')
    lines.push('  同时看 attackChance 伏击概率，必须低于 10%）：')
    lines.push(JSON.stringify(f.tradeRoutes, null, 2))
    lines.push('')
    if (f.escortCandidates !== undefined && f.escortCandidates.length > 0) {
      lines.push(`护航候选（★ 只能从这些里选；原版规则是"与行动船的距离不超过护航自己的一个跳跃航程" ✓，并不要求同一星系 ✓）：${f.escortCandidates.join(', ')}`)
      lines.push('  若候选路线的伏击概率偏高，就选 1~2 艘护航来压低它 ✓（这是主人教的正当手段 ✓）。')
      lines.push('')
    } else {
      lines.push('护航候选：无（此刻没有满足原版判据「与行动船距离 ≤ 护卫自己一跳航程」的护卫 ✓）')
      lines.push('')
    }
    lines.push('★ 候选里的 `attackChanceWithEscorts` = **带上上面那些护航之后**的伏击概率 ✓；')
    lines.push('  `attackChance` = 不带护航的概率 ✓。请据此判断：加护航能否压到 10% 以下 ✓。')
    lines.push('')
    lines.push('若选 action=Trade：**goodName 是必填** ✓ —— 必须**原样**取自 recommendation/候选表里的 name；')
    lines.push('  ★ 漏了它游戏的商品选择就失控了 ✗（实测模型漏过一次 ✓），所以这是格式里唯一"不能省"的字段 ✓。')
    lines.push('x/y 用上面的候选表 / orderHint（都是绝对星区坐标 ✓，且都保证区域包含船 ✓）；选哪个由你定 ✓。')
    lines.push('')
  }
  if (f.scoutPlan !== undefined) {
    lines.push('Scout 计划（游戏侧算出的**事实**）：候选区域、每个区域原版预测的数（revealsOffgrid / 时长 / 伏击概率）、' +
      '以及船所在邻域还剩多少**未探索**星区（coverage）、离地图中心多远（centre）、旅行与侦察的机制约束（travelFacts）')
    lines.push(JSON.stringify(f.scoutPlan, null, 2))
    lines.push('★ 侦察的机制（事实，不是指令）：侦察 = 开地图，区域 21x21 且**船必须已经在区域内**；')
    lines.push('  旅行（Travel）要求目的地**至少 2 跳远**；因此一艘船把所在邻域开完之后，那里就**没有可揭开的了** ——')
    lines.push('  该不该换位置、往哪换、还是先干别的，由你根据上面的事实自己判断 ✓。')
    lines.push(String.fromCharCode(10))
  }
  if (f.sellPlan !== undefined) {
    lines.push('★★ 游戏侧算好的 Sell（卖货）计划（船上有货时才会给 ✓）：')
    lines.push(JSON.stringify(f.sellPlan, null, 2))
    lines.push('')
    lines.push('★ 读法：netProfitLow/High = **风险调整后的期望**（被伏击可能只卖掉一部分 ✓）；')
    lines.push('  bestCaseLow/High = 最好情况；两者都标了 profitBasis ✓。')
    lines.push('  ★ 若船上有货（见能力卡的 holdHasGoods / cargoState），**先 Sell 再贸易** ✓；')
    lines.push('    卖了之后货舱才空，Trade 才装得进货 ✓（这是被伏击召回后的必经一步 ✓）。')
    lines.push('    要卖就 action=Sell，x/y 从上面的候选表 / orderHint 里挑一个达标的绝对坐标 ✓（不需要 goodName ✓）。')
    lines.push('')
  }
  lines.push('请按系统提示的格式回复。')
  return lines.join('\n')
}

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
  if (decision.duration !== undefined) params.duration = decision.duration
  if (decision.safeMode !== undefined) params.safeMode = decision.safeMode    // ★ Mine/Salvage ✓
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
// ★★ 护航 rendezvous（2026-10-17，主人要的"旅行"能力 ✓）
// ---------------------------------------------------------------------------
//
// 主人的原话：
//   「当一艘船需要护卫时，可以把空闲战斗舰调到目标舰星系，再发起指令。」
//
// 游戏规则（硬，2026-10-17 更正 ✗→✓）：护航只要求**在自己一跳航程之内** ✓（**不要求同星区** ✓，
//   不能穿裂隙的还要与行动船同处屏障环一侧 ✓）。所以"把船调到同一星区/附近"仍是最稳的做法 ✓，
//   但**不是唯一**可行的 ✓ —— 别再把"必须同星系"当硬规则 ✗。
// 但 Travel 是**异步**的：船离开后要好一阵才到 ✓，而"目标星系没有护航"这个条件
// 在它到达前**一直成立** ✗ → 每轮 decide 都会想再派一艘 ✓。
// 所以下面留了一张**记忆表**：同一艘行动船，30 分钟内只派一次 ✓（无论成功在途还是被游戏拒 ✓）。

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
 * ★ 判断"这一轮的 tradePlan 是不是**真的缺一艘护航**" ✓
 *
 * 只**读**游戏给的字段，不改扫描逻辑 ✓：
 *   recommendation 非空        → 已经有能出海的推荐 → 不需要 ✓
 *   本星系已有护航候选          → 现有流程会处理 → 不需要 ✓
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
  if (sameSectorEscorts.length > 0) {
    return { needed: false, why: `本星系已有护航候选 ${sameSectorEscorts.join(',')}` }
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
  // ★ 优先用**游戏侧**算好的带护航概率 ✓（那是原版机制 ✓）；它缺失时才退到经验系数 ✓
  const withEscort = best.withEscorts ?? (best.risk * ESCORT_RISK_FACTOR)
  if (best.risk <= gate) {
    return { needed: false, why: `最好候选「${best.name}」本来就在门槛内（${fmtPct(best.risk)}）`, gate }
  }
  if (withEscort > gate) {
    return {
      needed: false,
      why: `最好候选「${best.name}」伏击概率 ${fmtPct(best.risk)}，加一艘护航估约 ${fmtPct(withEscort)}` +
        ` 仍高于门槛 ${fmtPct(gate)} —— 派了也压不下来，不派 ✓`,
      route: best.name, risk: best.risk, riskWithEscort: withEscort, gate,
    }
  }
  return {
    needed: true,
    why: `最好候选「${best.name}」伏击概率 ${fmtPct(best.risk)} > 门槛 ${fmtPct(gate)}，` +
      `加一艘护航估约 ${fmtPct(withEscort)} ✓ —— 但本星系没有护航 → 需要考虑 rendezvous`,
    route: best.name, risk: best.risk, riskWithEscort: withEscort, gate,
  }
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

/**
 * ★ 已经在路上的 rendezvous 记忆表（船名 → 记录 ✓）。
 *
 * 没有它会怎样：Travel 异步 ✗ → 护航到达前的每一轮 decide 都看不见它 ✗ →
 *   同一艘船会被反复派（或被反复拒）✗。所以同一艘行动船 X 分钟内只派一次 ✓。
 */
const RENDEZVOUS_MEMO_MS = 30 * 60 * 1000
const rendezvousMemo = new Map<
  string,
  { escort: string; at: number; ok: boolean; why: string; x: number; y: number }
>()

// ---------------------------------------------------------------------------
// 插件入口：把 RPC 接起来
// ---------------------------------------------------------------------------

export function apply(ctx: CopilotCtx, config: CopilotConfig = {}): void {
  const cfg = {
    port: config.port ?? DEFAULTS.port,
    provider: config.provider ?? DEFAULTS.provider,
    model: config.model ?? DEFAULTS.model,
    maxTokens: config.maxTokens ?? DEFAULTS.maxTokens,
    temperature: config.temperature ?? DEFAULTS.temperature,
  }

  // 双写：控制台（人看 ✓）+ 文件（agent 读 ✓）
  const logger = {
    info: (m: string): void => { ctx.logger?.info?.(m); fileLog(m) },
    warn: (m: string): void => { ctx.logger?.warn?.(m); fileLog('WARN ' + m) },
  }
  fileLog(`=== 插件启动：监听 ${cfg.port}（模型 ${cfg.provider}/${cfg.model}）===`)

  const peer = new RpcPeer({
    port: cfg.port,
    logger,
    defaultTimeoutSec: 5,
  })

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
  peer.handle('decide', async (data: any) => {
    const req = (data ?? {}) as DecideRequest
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
  })

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

    // ★★ 按主人的架构：DSH **自己**用 RPC 去拉数据 ✓✓（游戏侧只给船名 ✗）
    const goalR = await ask(peer, 'query', { what: 'goal', ship }, 10)
    if (!goalR.ok) {
      logger.warn(`avorion-copilot: 拉目标失败 ${goalR.why ?? ''}`)
      return [false, 'GOAL_QUERY_FAILED', goalR.why ?? 'unknown']
    }
    const cardR = await ask(peer, 'query', { what: 'ship', ship }, 10)
    if (!cardR.ok) {
      logger.warn(`avorion-copilot: 拉能力卡失败 ${cardR.why ?? ''}`)
      return [false, 'CARD_QUERY_FAILED', cardR.why ?? 'unknown']
    }

    const gd = (goalR.data ?? {}) as Record<string, unknown>
    const facts: DecideFacts = {
      ship,
      goalText: typeof gd.text === 'string' ? gd.text : '',
      goalOptions: Array.isArray(gd.options) ? (gd.options as string[]) : [],
      card: cardR.data ?? {},
    }
    // ★★ 贸易船额外拉一份**真实路线表** ✓✓（这样模型才能选对货 ✓）
    const nameList: string[] = Array.isArray((facts.card as Record<string, unknown>).actionNames)
      ? ((facts.card as Record<string, unknown>).actionNames as string[])
      : []
    const wantsTrade = nameList.includes('Trade') &&
      (facts.goalOptions.length === 0 || facts.goalOptions.includes('Trade'))
    // ★★ 2026-10-17：Mine / Salvage 也要拉**真实计划** ✓✓（原来它们是瞎猜的 ✗ —— 见 buildPrompt 的注释）
    //   与 wantsTrade 同一套判断：卡片有这能力 ✓ 且（没限动作 或 动作被允许）✓
    const wantsMine = nameList.includes('Mine') &&
      (facts.goalOptions.length === 0 || facts.goalOptions.includes('Mine'))
    const wantsSalvage = nameList.includes('Salvage') &&
      (facts.goalOptions.length === 0 || facts.goalOptions.includes('Salvage'))
    const jobWants: Array<{ action: 'Mine' | 'Salvage'; what: string }> = []
    if (wantsMine) jobWants.push({ action: 'Mine', what: 'minePlan' })
    if (wantsSalvage) jobWants.push({ action: 'Salvage', what: 'salvagePlan' })
    // ★ 两份都要算时，把候选区域收窄到**最近的 5 个** ✓ ——
    //   游戏侧 jobPlan 是**同步**算的（会占住游戏主循环 ✓），每个 ≈ 一个 tradePlan 的开销 ✓。
    //   两份各扫 9 区就是两倍开销；各扫 5 区仍然覆盖船周围的 3×3/十字范围 ✓，够用 ✓。
    const jobAreaCap = jobWants.length > 1 ? 5 : undefined
    // ★★ rendezvous 要用的**原始数据**（不改喂给模型的那份 ✓ —— 见下面的 rendezvous 段 ✓）
    let planRaw: Record<string, unknown> | undefined
    let fleetShips: Record<string, unknown>[] = []
    let pilotedName = ''
    if (wantsTrade || jobWants.length > 0) {
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
          fleetShips = ships                        // ★ rendezvous 的候选池（**别的**星系 ✓）
          pilotedName = String(fd.piloted ?? '')    // ★ 玩家在开的那条永不碰 ✓
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
            if (hs.canPassRifts === false) { conservative.push(nm + '(不能穿裂隙,环侧判不准)'); continue }
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

    // ★★ Mine / Salvage：拉游戏侧算好的真实计划 ✓✓（多区域 × 参数 × 层级加权 ✓）
    if (jobWants.length > 0) {
      const planned: Array<{ action: string; plan: Record<string, unknown> }> = []
      const planFails: Array<{ what: string; why: string }> = []
      for (const jw of jobWants) {
        const q: Record<string, unknown> = { what: jw.what, ship, escorts: facts.escortCandidates ?? [] }
        if (jobAreaCap !== undefined) q.maxAreas = jobAreaCap
        let jr = await ask(peer, 'query', q, 120)
        if (!jr.ok) {
          // ★ 重试一次 ✓（实测: 游戏侧重连会打断在途请求 ✗ → "connection replaced by a newer one" ✓）
          live(`  ├ ${jw.what} 拉取失败（${String(jr.why ?? '')}）→ 重试一次 ✓`)
          await new Promise((r) => setTimeout(r, 1500))
          jr = await ask(peer, 'query', q, 120)
          if (jr.ok) live(`  ├ ${jw.what} 重试成功 ✓`)
        }
        // ★★ 空载荷也必须当"没取到" ✗✓（2026-10-17 实测: 六个计划分支少返回一个 true ✗
        //    → RPC 的 payload=nil → 工具层看到 `{}` ✓ —— 而模型会把它读成"没有候选" ✗✓✓）
        const emptyPayload = jr.ok
          && (jr.data === undefined || jr.data === null
            || (typeof jr.data === 'object' && !Array.isArray(jr.data)
              && Object.keys(jr.data as Record<string, unknown>).length === 0))
        if (!jr.ok || emptyPayload) {
          const why = jr.ok ? '游戏回了空载荷（★ 这不代表"没有候选" ✗✓）' : String(jr.why ?? 'unknown')
          logger.warn(`avorion-copilot: ${ship} 拉 ${jw.what} 失败 ${why}`)
          live(`  ├ ${jw.what} **没取到** ✗（${why}）`)
          planFails.push({ what: jw.what, why })
          continue
        }
        const jd = (jr.data ?? {}) as Record<string, unknown>
        const rec0 = jd.recommendation as Record<string, unknown> | null | undefined
        if (rec0 !== undefined && rec0 !== null) {
          // ★ 主人要看的核心数字：**采到最高阶什么**（Mine）/ **多少件装备**（Salvage）
          const head = jw.action === 'Mine'
            ? `最高矿 ${String(rec0.topMaterial ?? '?')}（层级 ${String(rec0.topTier ?? '?')}）价值 ${String(rec0.valueLow ?? '?')}~${String(rec0.valueHigh ?? '?')}`
            : `${String((rec0.items as Record<string, unknown> | undefined)?.to ?? '?')} 件装备 × E[层级] ${String(rec0.rarityTier ?? '?')} = ${String(rec0.valueHigh ?? '?')}`
          live(`  ├ ${jw.action} 推荐「${String(rec0.tag)}」${head}` +
            ` 伏击 ${fmtPct(toNum(rec0.attackChance))}（扫 ${String(jd.areasScanned ?? '?')} 区 / ${String(jd.scanMs ?? '?')}ms）` +
            `${rec0.safeMode === true ? ' [安全模式]' : ''}` +
            `${Array.isArray(rec0.escorts) && (rec0.escorts as unknown[]).length > 0 ? ' [护航 ' + (rec0.escorts as string[]).join(',') + ']' : ''}`)
        } else if (typeof jd.riskWarning === 'string' && jd.riskWarning !== '') {
          live(`  ├ ${jw.action} 无推荐：${jd.riskWarning.slice(0, 160)}`)
        }
        planned.push({ action: jw.action, plan: compactJobPlan(jd) })
        logger.info(
          `avorion-copilot: ${ship} 已取到 ${jw.what}（扫 ${String(jd.areasScanned ?? 0)} 区 / ` +
          `${String(jd.scanMs ?? 0)}ms，推荐=${rec0 ? String(rec0.tag) : 'none'}）`,
        )
      }
      if (planned.length > 0) facts.jobPlans = planned
      if (planFails.length > 0) facts.planFetchFailures = planFails

    // ★★ 船上有货 → 拉一份 Sell 计划 ✓✓（Issue B：被伏击召回后必须先变现才能再贸易 ✓）
    const cardObj = (facts.card ?? {}) as Record<string, unknown>
    const holdHasGoods = cardObj.holdHasGoods === true
    const canSell = nameList.includes('Sell') || true          // 所有商业船卡都有 Sell ✓
    if (holdHasGoods && canSell) {
  // 勘察计划：能勘察的船都拉一份
  if (nameList.includes('Scout') || true) {
    const cr = await ask(peer, 'query', { what: 'scoutPlan', ship }, 120)
    if (cr.ok) {
      facts.scoutPlan = cr.data as Record<string, unknown>
      const sd = cr.data as Record<string, unknown>
      const cov = (sd.coverage ?? {}) as Record<string, unknown>
      const cen = (sd.centre ?? {}) as Record<string, unknown>
      live('  ├ Scout 事实：未探索 ' + String(cov.unknown ?? '?') + '/' + String(cov.total ?? '?') + '，离中心 ' + String(cen.distance ?? '?') + '，扫 ' + String(sd.areasScanned ?? '?') + ' 区 / ' + String(sd.scanMs ?? '?') + 'ms（推荐 ' + (sd.recommendation ? '有' : '无') + '）')
    }
  }
      const sr = await ask(peer, 'query', { what: 'sellPlan', ship }, 120)
      if (sr.ok) {
        facts.sellPlan = sr.data as Record<string, unknown>
        const sd = (sr.data ?? {}) as Record<string, unknown>
        const rec = sd.recommendation as Record<string, unknown> | undefined
        live(`  ├ 船上有货（${String(cardObj.cargoUsed ?? '?')} 单位）→ Sell 计划：` +
          (rec !== undefined
            ? `期望 C${String(rec.netProfitLow ?? '?')}~${String(rec.netProfitHigh ?? '?')}，伏击 ${String(rec.attackChance ?? '?')}`
            : `无推荐（${String(sd.riskWarning ?? 'hold empty?')}）`))
      } else {
        logger.warn(`avorion-copilot: ${ship} 拉卖货计划失败 ${sr.why ?? ''}`)
      }
    }
    }

    if (wantsTrade) {
      const planR = await ask(peer, 'query', { what: 'tradePlan', ship, escorts: facts.escortCandidates ?? [] }, 120)
      if (planR.ok) {
        const pd = (planR.data ?? {}) as Record<string, unknown>
        planRaw = pd                               // ★ rendezvous 只看它 ✓（喂模型的仍是下面那份 ✓）
        // ★★ 多区域 tradePlan 的结论也进实时流水 ✓（人要看"为什么不推荐" ✓）
        const plan0 = pd.recommendation as Record<string, unknown> | null | undefined
        if (plan0 !== undefined && plan0 !== null) {
          live(`  ├ tradePlan 推荐「${String(plan0.goodName)}」伏击 ${fmtPct(toNum(plan0.attackChance))}` +
            `（扫 ${String(pd.areasScanned ?? '?')} 区 / ${String(pd.scanMs ?? '?')}ms）`)
        } else if (typeof pd.riskWarning === 'string' && pd.riskWarning !== '') {
          live(`  ├ tradePlan 无推荐：${pd.riskWarning.slice(0, 140)}`)
        }
        // 只给模型有用的部分：候选表 + 最优计划 ✓（area 里那 289 个坐标太占 token ✗）
        // ★★ 把**三维搜索**的结果都喂给模型 ✓✓（2026-10-16 修 e3 —— 子代理指出：
        //   此前只喂了旧的 candidates/best/planReason ✗，于是新加的
        //   recommendation / areaRanking / orderHint **模型完全看不到** ✗✓，
        //   多区域搜索白做了 ✓。）
        //   areaRanking 会裁剪到关键字段，免得把 RPC 响应原样灌进 prompt 撑爆上下文 ✓。
        const rank = Array.isArray(pd.areaRanking) ? (pd.areaRanking as Record<string, unknown>[]) : []
        facts.tradeRoutes = {
          recommendation: pd.recommendation ?? null,
          riskWarning: pd.riskWarning ?? null,
          orderHint: pd.orderHint ?? null,
          scanMs: pd.scanMs ?? null,
          areasScanned: pd.areasScanned ?? null,
          areas: rank.slice(0, 9).map((a) => ({
            offset: (a.area as Record<string, unknown> | undefined)?.offset,
            bestRouteName: a.bestRouteName,
            netProfitLow: a.netProfitLow,
            netProfitHigh: a.netProfitHigh,
            attackChance: a.attackChance,
            attackChanceWithEscorts: a.attackChanceWithEscorts ?? null,
            profitPerSize: a.profitPerSize,
            flights: a.flights,
            deposit: a.deposit,
            escortsNeeded: a.escortsNeeded ?? null,
            acceptable: a.acceptable,
          })),
          candidates: pd.candidates,
        }
        logger.info(`avorion-copilot: ${ship} 已取到 ${String(pd.routeCount ?? 0)} 条贸易候选 ✓`)
      } else {
        logger.warn(`avorion-copilot: ${ship} 拉贸易候选失败 ${planR.why ?? ''}`)
      }
    }

    // ★ 记录②"输入"（主人要看的 ✓）
    rec.goalText = facts.goalText
    rec.goalOptions = facts.goalOptions
    rec.card = facts.card
    rec.routes = facts.tradeRoutes
    live(`  ├ 事实  目标=[${facts.goalText}] 允许=[${facts.goalOptions.join(',') || '不限'}]`)
    if (facts.tradeRoutes !== undefined) {
      const cand = (facts.tradeRoutes as Record<string, unknown>).candidates
      live(`  ├ 贸易候选 ${Array.isArray(cand) ? cand.length : '?'} 条已喂给模型`)
    }
    logger.info(
      `avorion-copilot: ${ship} 目标=[${facts.goalText}] 允许=${facts.goalOptions.join(',') || '(不限)'}`,
    )

    // ★★ 护航 rendezvous（2026-10-17 ✓）--------------------------------------
    //   主人：「当一艘船需要护卫时，可以把空闲战斗舰调到目标舰星系，再发起指令。」
    //   触发：tradePlan 真的缺护航 ✓ + 本星系没有护航候选 ✓ + 别的星系有闲置战斗船 ✓
    //   → 先派船 Travel 过去 ✓；**本轮不下单** ✓（等它到位，下一轮就看得见护航了 ✓）。
    if (wantsTrade && planRaw !== undefined) {
      const need = escortNeedOf(planRaw, facts.escortCandidates ?? [])
      live(`  ├ 护航需求：${need.needed ? '缺护航' : '不需要'} —— ${need.why}`)
      if (need.needed) {
        const target = ((facts.card as Record<string, unknown>).sector ?? {}) as { x?: number; y?: number }
        const prev = rendezvousMemo.get(ship)
        const fresh = prev !== undefined && (Date.now() - prev.at) < RENDEZVOUS_MEMO_MS
        if (prev !== undefined && fresh) {
          // ★ 已经派过（在途 / 被拒）→ **不重复派** ✓（Travel 是异步的，护航没到之前条件一直成立 ✗）
          const mins = Math.round((Date.now() - prev.at) / 60000)
          const reason = prev.ok
            ? `护航 ${prev.escort} 已在飞往 (${prev.x},${prev.y}) 的路上（${mins} 分钟前派出），本轮不下单，` +
              `等它到位后下一轮再带上它出海`
            : `上一轮派 ${prev.escort} 去 (${prev.x},${prev.y}) 被游戏拒绝（${prev.why}），` +
              `${Math.round(RENDEZVOUS_MEMO_MS / 60000)} 分钟内不重复派，本轮不出海`
          live(`  ├ rendezvous 已记录（${mins} 分钟前，${prev.ok ? '在途' : '被拒'}）→ 不重复派 ✓`)
          const answer: DecideAnswer = { action: 'None', params: { escort: prev.escort, x: prev.x, y: prev.y }, reason }
          return [true, answer]
        }

        const pick = pickRendezvousEscort(fleetShips, ship, pilotedName, target)
        if (pick === null) {
          live('  └ 别的星系没有空闲的、有船长的战斗船 → 派不出去（照常交给模型判断 ✓）')
        } else if (target.x === undefined || target.y === undefined) {
          live('  └ 读不到行动船的星区坐标 → 不敢乱派（照常交给模型判断 ✓）')
        } else {
          live(`  ├ 选中护航 ${pick.name}（在 ${pick.sector.x},${pick.sector.y}；${pick.basis}）`)
          live(`  ├ 下单 Travel：${pick.name} → (${target.x},${target.y})（目的地必须 ≥2 跳，太近游戏会拒 ✓）`)
          const ord = await ask(peer, 'order', { ship: pick.name, action: 'Travel', x: target.x, y: target.y }, 30)
          const why = ord.ok ? '' : (ord.why ?? 'unknown')
          rendezvousMemo.set(ship, {
            escort: pick.name, at: Date.now(), ok: ord.ok, why, x: target.x, y: target.y,
          })
          rec.orderResult = ord.ok ? ord.data : { failed: why }
          if (ord.ok) {
            live('  └ Travel 已接受 ✓ 本轮不下单（等它到位 → 下一轮它就在护航候选里 ✓）')
          } else {
            live(`  └ Travel 被游戏拒绝 ✗ ${why} —— 本轮不出海，记下不盲目重试 ✓`)
          }
          const reason = ord.ok
            ? `已派护航 ${pick.name} 前往本星系 (${target.x},${target.y})，本轮不下单，等它到位后下一轮再出海`
            : `想派护航 ${pick.name} 前往 (${target.x},${target.y})，但被游戏拒绝（${why}），本轮不出海`
          const answer: DecideAnswer = { action: 'None', params: { escort: pick.name, x: target.x, y: target.y }, reason }
          logger.info(`avorion-copilot: ${ship} 护航 rendezvous → ${pick.name} Travel (${target.x},${target.y}) accepted=${String(ord.ok)}`)
          return [true, answer]
        }
      }
    }

    // ★★ 增量 2：结算**上一次**任务（busy→idle 转换 ✓）
    //   游戏侧没有把产出回灌给 Lua 的干净通道 ✗（见提交说明），所以这里记录的是
    //   **可得到的弱信号**：它忙了多久 / 是否远早于申请时长结束（远早 ≈ 被伏击或召回 ✓）。
    const cardSec = (facts.card as Record<string, unknown>).sector as { x?: number; y?: number } | undefined
    const memSectors: string[] = []
    if (cardSec !== undefined) memSectors.push(String(cardSec.x) + "," + String(cardSec.y))
    const hint = (facts.tradeRoutes as Record<string, unknown> | undefined)?.orderHint as
      { x?: number; y?: number } | undefined
    if (hint !== undefined && hint.x !== undefined && hint.y !== undefined) {
      memSectors.push(String(hint.x) + "," + String(hint.y))
    }
    const sectorKey = memSectors.length > 0 ? memSectors[memSectors.length - 1] : ""

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
    const memoryBlock = "【你自己的记忆 —— 仅供参考 ✓；若与下面新算出的游戏数据冲突，以游戏数据为准 ✗】"
      + String.fromCharCode(10) + mem.text

    let result: StreamResult
    try {
      rawKind = null                                  // 每次调用重新分段 ✓
      liveRaw('reasoning', '')
      result = await askModel(ctx, cfg, buildPrompt(facts), liveRaw, [memoryBlock])
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error)
      logger.warn(`avorion-copilot: 模型调用异常 ${message}`)
      return [false, 'MODEL_ERROR', message]
    }
    if (result.failure !== undefined) {
      logger.warn(`avorion-copilot: 模型调用失败 ${result.failure}`)
      return [false, 'MODEL_FAILED', result.failure]
    }

    // ★ 记录③"推理"（含思维链 ✓✓ —— 这是主人最想看的一段 ✓）
    rec.modelText = result.text
    rec.reasoning = result.reasoning
    rec.truncated = result.truncated
    live(`  ├ 模型回复 正文 ${result.text.length} 字 / 思维链 ${result.reasoning.length} 字${result.truncated ? "  ⚠️被maxTokens截断" : ""}`)
    for (const line of result.reasoning.trim().split('\n')) {   // ★ 不再截断（主人要看原始全过程 ✓）
      if (line.trim() !== '') live(`  │ ${line.trim()}`)     // ★ 思维链**逐行**进流水 ✓✓
    }

    const decision = parseDecision(result.text)
    const answer = toAnswer(decision, facts, result.text)
    if (typeof answer === 'string') {
      logger.warn(`avorion-copilot: 决策无法解析 —— ${answer}`)
      return [false, 'BAD_MODEL_REPLY', answer]
    }
    // ★ 记录④"结论"（先记下，⑤ 结果随后补 ✓）
    rec.answer = answer
    live(`  ├ 决策 ${answer.action} ${JSON.stringify(answer.params)}  (${answer.reason ?? ''})`)

    logger.info(
      `avorion-copilot: ${ship} -> ${answer.action} ${JSON.stringify(answer.params)}` +
      (answer.reason !== undefined ? `  (${answer.reason})` : '') +
      (result.truncated ? '  [被 maxTokens 截断]' : '') +
      (result.reasoning.length > 0 ? `\n--- 思维链 ---\n${result.reasoning.trim()}` : ''),
    )

    // ★ 真下单：DSH 主动调游戏的 order ✓✓（游戏侧会走两段式 ✓）
    if (answer.action !== 'None') {
      const ord = await ask(peer, 'order', { ship, action: answer.action, ...answer.params }, 30)
      // ★ 记录⑤"结果"（下单回执 ✓）
      rec.orderResult = ord.ok ? ord.data : { failed: ord.why ?? 'unknown' }
      if (ord.ok) {
        // ★ 增量 2：把"我们交给它的活"记下来 ✓ —— 下一轮它变空闲时就能结算 ✓✓
        rememberStart(ship, answer.action, answer.params, sectorKey)
        const hours = typeof answer.params.duration === 'number' ? answer.params.duration : undefined
        pendingJobs.set(ship, {
          atMs: Date.now(), action: answer.action,
          goodName: typeof answer.params.goodName === 'string' ? answer.params.goodName : undefined,
          hours, sector: sectorKey,
        })
      }
      if (ord.ok) {
        logger.info(`avorion-copilot: 已下单 ${ship} -> ${answer.action} → ${JSON.stringify(ord.data)}`)
      } else {
        logger.warn(`avorion-copilot: 下单失败 ${ord.why ?? ''}`)
      }
    }

    return [true, answer]
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

  // ★ 把游戏能力暴露成 DSH 工具（主人要的"会话接管"就靠它们 ✓✓）
  registerFleetTools(ctx, peer, decisionLog)

  // 供将来从 DSH 侧主动操作（例如命令面板、定时巡检）使用 ✓
  void queryShip
  void order
  void reload
}
