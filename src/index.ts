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
import type { GenerateOptions, StreamChunk } from '@deepseek-ai/dsh-llm/types'
import { RpcPeer } from './rpc.js'
import { registerFleetTools, ask } from './tools.js'

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

const DEFAULTS = {
  port: 8765,
  provider: 'deepseek-official',
  model: 'deepseek-flash',
  maxTokens: 2000,   // ★ 700 不够：模型会把额度烧在思维链上，正文被截断 → 解析失败 ✗
  temperature: 0.2,
}

/**
 * 系统提示词。放的是「模型必须知道、但请求里不必重复」的领域知识：
 * 四条命令的语义、区域规则，以及伏击概率为什么是非线性代价。
 *
 * ★ 一字未改，从文件桥版本原样搬来 ✓。
 */
const SYSTEM_PROMPT = `你是 Avorion 舰队的运营大脑。玩家把若干艘船交给你自动运营，现在需要你为其中一艘空闲的船决定下一步做什么。

可用命令（都属"后台命令"：船长带队离开玩家所在星区，在指定区域自动作业，期间联系不上）：
- Mine    采矿，产出矿石。区域 15x15，且船必须已经在该区域内。
- Salvage 打捞残骸，产出资源与装备。区域 15x15，船必须已经在该区域内。
- Trade   按贸易路线买卖商品赚钱。船必须已经在区域内，且船长职业必须是 Merchant。（区域尺寸**以能力卡里的 actions.Trade.areaSize 为准** ✓，别按这里猜 ✗）
- Travel  跃迁到指定星区。区域 1x1，即单个目标星区，目的地至少要 2 跳远。

判断依据：
- ★ **风险口径（玩家定的规矩，最高优先级 ✓）**：attackChance 是整段任务期间遭遇伏击的概率（0~1）。
     · **低于 0.10 才出海** ✓；**越低越好** ✓。
     · 若偏高（≥0.10）→ ★ **先加护航**（只能从"同星系护航候选"里选 ✓）把它压到 0.10 以下 ✓。
     · 加了护航仍压不下去 → 换一个区域（换 x/y 会得到另一张候选表 ✓），或**回 action=None** 不出海 ✓。
- 被伏击 = 命令被强制召回，拿不到结束时的最终大额产出，只能按已完成进度部分结算。所以风险对期望收益的影响是非线性的。
- ★ 若这艘船**本来就没有合适的商业动作**（例如纯武装船、没有货舱也没有采矿设备），
     就回 action=None 并说明理由 ✓ —— **这是合法且常见的决策** ✓，不要硬凑一个动作 ✗。
- 派一艘"自身够硬"的护卫大约把伏击基础概率乘 0.75，但护卫本身占用了另一艘船。
- 任务时长越长风险越高：超过 1 小时后，每多 1 小时伏击概率再增加约 40%。收益随时长增加，但边际有限。
- 收益区间（yield）已经是"含可选护卫"的预估。

只回复下面这几行，不要任何多余文字：
action=<Mine | Salvage | Trade | Travel | None，只写这一个词>
x=<目标星区 x 坐标，整数；action=None 时省略>
y=<目标星区 y 坐标，整数；action=None 时省略>
escorts=<护航舰船名，逗号分隔，可选；**只能从上面给出的同星系候选里选**>
duration=<小时，可选>
reason=<一句话理由，用中文>`

interface Decision {
  action?: string
  /** ★ Trade 专用：模型选中的货物名（2026-10-16 补 ✓） */
  goodName?: string
  x?: number
  y?: number
  duration?: number
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

/** 解析模型回复。解析不出 action 就算失败，交给游戏按错误处理 ✓ */
function parseDecision(text: string): Decision {
  const decision: Decision = {}

  const rawAction = field(text, 'action')
  if (rawAction !== undefined) {
    // 容忍 `action=Mine` / `action: mine` / `**action = Mine**` ✓
    const word = rawAction.replace(/[`*"'。，,]/g, '').trim()
    const known = ['Mine', 'Salvage', 'Trade', 'Travel', 'None']
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
async function askModel(ctx: CopilotCtx, cfg: Required<Pick<CopilotConfig, 'provider' | 'model' | 'maxTokens' | 'temperature'>>, prompt: string, onDelta?: (kind: 'reasoning' | 'text', delta: string) => void): Promise<StreamResult> {
  let text = ''
  let reasoning = ''
  let failure: string | undefined
  let truncated = false

  const messages = [createUserMessage({ content: [{ type: 'text', text: prompt }], source: { kind: 'user' } })]

  const stream = ctx.llm.stream({
    provider: cfg.provider,
    model: cfg.model,
    system: SYSTEM_PROMPT,
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
  /** ★ 同星系的护航候选（贸易风险高时用来压低伏击概率 ✓✓ —— 主人 ⑧ 教的 ✓） */
  escortCandidates?: string[]
  /** ★ 贸易候选（只有 Trade 船才有）：游戏算出来的真实路线表 ✓ */
  tradeRoutes?: unknown
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
  lines.push(f.goalOptions.length > 0 ? f.goalOptions.join(', ') : '(玩家没有限制 —— 你可以从 Mine/Salvage/Trade/Travel 里选)')
  lines.push('')
  lines.push('这艘船的现状（能力卡）：')
  lines.push(JSON.stringify(f.card ?? {}, null, 2))
  lines.push('')
  if (f.tradeRoutes !== undefined) {
    // ★★ 把游戏算出来的**真实贸易路线表**给模型 ✓✓（2026-10-16 补）
    //   之前不给 ✗ → 模型只能猜"就地贸易"，完全不知道有更赚钱的货可选 ✗。
    //   注意让模型按 **profitPerSize（每体积绝对利润 ✓）** 比较，而不是百分比 ✓。
    lines.push('本区域的贸易候选（★ 按 profitPerSize = 每体积绝对利润 比较，越大越好；')
    lines.push('  同时看 attackChance 伏击概率，必须低于 10%）：')
    lines.push(JSON.stringify(f.tradeRoutes, null, 2))
    lines.push('')
    if (f.escortCandidates !== undefined && f.escortCandidates.length > 0) {
      lines.push(`同星系护航候选（★ 硬规则：只能从这些里选，它们与行动船**在同一星系**）：${f.escortCandidates.join(', ')}`)
      lines.push('  若候选路线的伏击概率偏高，就选 1~2 艘护航来压低它 ✓（这是主人教的正当手段 ✓）。')
      lines.push('')
    } else {
      lines.push('同星系护航候选：无（没有能护航的船 —— 此时只能靠换区域或不出海来降风险）')
      lines.push('')
    }
    lines.push('★ 候选里的 `attackChanceWithEscorts` = **带上上面那些护航之后**的伏击概率 ✓；')
    lines.push('  `attackChance` = 不带护航的概率 ✓。请据此判断：加护航能否压到 10% 以下 ✓。')
    lines.push('')
    lines.push('若选 action=Trade：goodName 必须**原样**取自上面的 name；')
    lines.push('x/y 请**直接填船当前的星区坐标**（区域必须以船为中心，挪走会让这张候选表作废）。')
    lines.push('')
  }
  lines.push('请按系统提示的格式回复。')
  return lines.join('\n')
}

/** 把模型的正文解析成 action + 坐标（这才是要回给游戏的答案 ✓） */
function toAnswer(decision: Decision, f: DecideFacts, raw: string): DecideAnswer | string {
  if (decision.error !== undefined) return decision.error

  const action = decision.action ?? 'None'
  const allowed = f.goalOptions.length > 0 ? f.goalOptions : ['Mine', 'Salvage', 'Trade', 'Travel']

  // "None" 永远合法（什么都不做 ✓）
  if (action !== 'None' && !allowed.includes(action)) {
    return `model picked '${action}' which is not allowed here (allowed: ${allowed.join(', ')}, plus None)`
  }

  const params: Record<string, unknown> = {}
  if (decision.goodName !== undefined) params.goodName = decision.goodName   // ★ Trade 的选货 ✓
  if (decision.x !== undefined) params.x = decision.x
  if (decision.y !== undefined) params.y = decision.y
  if (decision.duration !== undefined) params.duration = decision.duration
  if (decision.escorts !== undefined && decision.escorts.length > 0) params.escorts = decision.escorts

  return { action, params, reason: decision.reason, raw }
}

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
    if (wantsTrade) {
      // ★★ 先算**同星系护航候选** ✓✓（主人 ⑧ 的硬规则：护航必须与行动船同星系 ✓）
      //   缺了这一步，模型手里就没有"降低伏击概率"这张牌 ✗ →
      //   实测它只能一遍遍答 None（"every route is above the attack-chance limit" ✓）。
      try {
        const fr = await ask(peer, 'query', { what: 'fleet' }, 10)
        if (fr.ok) {
          const fd = (fr.data ?? {}) as Record<string, unknown>
          const shipSector = ((facts.card as Record<string, unknown>).sector ?? {}) as { x?: number; y?: number }
          const ships = Array.isArray(fd.ships) ? (fd.ships as Record<string, unknown>[]) : []
          const cands: string[] = []
          for (const s of ships) {
            const nm = typeof s.name === 'string' ? s.name : ''
            const sec = (s.sector ?? {}) as { x?: number; y?: number }
            if (nm === '' || nm === ship) continue
            if (nm === String(fd.piloted ?? '')) continue
            if (s.busy === true) continue
            if (sec.x === shipSector.x && sec.y === shipSector.y) cands.push(nm)
          }
          facts.escortCandidates = cands
          live(`  ├ 同星系护航候选 ${cands.length} 艘${cands.length > 0 ? ': ' + cands.join(',') : ''}`)
        }
      } catch { /* 拿不到护航候选不影响决策 ✓ */ }
      const planR = await ask(peer, 'query', { what: 'tradePlan', ship, escorts: facts.escortCandidates ?? [] }, 120)
      if (planR.ok) {
        const pd = (planR.data ?? {}) as Record<string, unknown>
        // 只给模型有用的部分：候选表 + 最优计划 ✓（area 里那 289 个坐标太占 token ✗）
        facts.tradeRoutes = {
          candidates: pd.candidates,
          best: (pd.plan as Record<string, unknown> | undefined)?.route,
          planReason: (pd.plan as Record<string, unknown> | undefined)?.reason,
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

    let result: StreamResult
    try {
      rawKind = null                                  // 每次调用重新分段 ✓
      liveRaw('reasoning', '')
      result = await askModel(ctx, cfg, buildPrompt(facts), liveRaw)
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
