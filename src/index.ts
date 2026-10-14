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
import { registerFleetTools } from './tools.js'

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

const DEFAULTS = {
  port: 8765,
  provider: 'deepseek-official',
  model: 'deepseek-flash',
  maxTokens: 700,
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
- Trade   按贸易路线买卖商品赚钱。区域 17x17 / 29x11 / 11x29，船必须已经在该区域内，且船长职业必须是 Merchant。
- Travel  跃迁到指定星区。区域 1x1，即单个目标星区，目的地至少要 2 跳远。

判断依据：
- attackChance 是整段任务期间遭遇伏击的概率（0~1）。0.20 以上在原版里就是"应该派护卫"的分档。
- 被伏击 = 命令被强制召回，拿不到结束时的最终大额产出，只能按已完成进度部分结算。所以风险对期望收益的影响是非线性的。
- 派一艘"自身够硬"的护卫大约把伏击基础概率乘 0.75，但护卫本身占用了另一艘船。
- 任务时长越长风险越高：超过 1 小时后，每多 1 小时伏击概率再增加约 40%。收益随时长增加，但边际有限。
- 收益区间（yield）已经是"含可选护卫"的预估。

只回复下面这几行，不要任何多余文字：
choice=<候选编号，只写数字，例如 choice=1（不要写成 choice=opt1）>
duration=<小时，可选；不填则用候选里的默认值>
escorts=<逗号分隔的船名，可选；不派就留空>
reason=<一句话理由，用中文>`

interface Decision {
  choice?: number
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
 * 解析候选编号。模型经常写成 `opt1` 而不是 `1`（实测第一次就踩到了），
 * 所以只取其中的数字：`opt1` / `OPT 2` / `选项3` / `1` 都能认。
 * ★ 原样保留 ✓。
 */
function parseChoice(raw: string): number | undefined {
  const match = /(\d+)/.exec(raw)
  if (match === null) return undefined
  const value = Number(match[1])
  return Number.isFinite(value) ? value : undefined
}

/** 表示"没有"的几种写法，别当成船名。★ 原样保留 ✓ */
const NONE_WORDS = new Set(['', '-', 'none', 'null', 'n/a', 'na', '无', '没有', '否'])

/** 解析模型回复。解析不出 choice 就算失败，交给游戏按错误处理。★ 原样保留 ✓ */
function parseDecision(text: string): Decision {
  const decision: Decision = {}

  const rawChoice = field(text, 'choice')
  if (rawChoice !== undefined) {
    const choice = parseChoice(rawChoice)
    if (choice !== undefined) decision.choice = choice
  }

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

  if (decision.choice === undefined) {
    const seen = rawChoice === undefined ? 'no choice line' : JSON.stringify(rawChoice)
    decision.error = `model reply contained no usable choice (saw: ${seen})`
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
async function askModel(ctx: CopilotCtx, cfg: Required<Pick<CopilotConfig, 'provider' | 'model' | 'maxTokens' | 'temperature'>>, prompt: string): Promise<StreamResult> {
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
    } else if (chunk.type === 'reasoning-delta') {
      reasoning += chunk.text
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

interface DecideRequest {
  ship?: string
  card?: unknown
  options?: unknown
}

interface DecideAnswer {
  action: string
  params: Record<string, unknown>
  reason?: string
  raw?: string
}

/**
 * 组一份给模型看的请求：能力卡 + 候选命令 + 明确的输出格式要求。
 * 候选来自**游戏侧的 orderSchema** ✓ —— 所以模型只能在合法命令里选 ✓✓。
 */
function buildPrompt(req: DecideRequest): string {
  const lines: string[] = []
  lines.push(`船：${req.ship ?? '(unknown)'}`)
  lines.push('')
  lines.push('这艘船的事实（能力卡）：')
  lines.push(JSON.stringify(req.card ?? {}, null, 2))
  lines.push('')
  lines.push('候选方案（只能从里面选，编号从 1 开始）：')
  const options = Array.isArray(req.options) ? req.options : []
  if (options.length === 0) {
    lines.push('(没有候选 —— 请回复 choice=0 表示本轮什么都不做)')
  } else {
    options.forEach((opt, i) => lines.push(`${i + 1}. ${JSON.stringify(opt)}`))
  }
  lines.push('')
  lines.push('请按系统提示的格式回复。')
  return lines.join('\n')
}

/** 把模型的 choice 映射回游戏给的候选（这才是要回给游戏的答案 ✓） */
function toAnswer(req: DecideRequest, decision: Decision, raw: string): DecideAnswer | string {
  if (decision.error !== undefined) return decision.error

  const options = Array.isArray(req.options) ? req.options : []
  const choice = decision.choice ?? 0

  if (choice === 0 || options.length === 0) {
    return { action: 'None', params: {}, reason: decision.reason ?? 'model chose to do nothing', raw }
  }
  if (choice < 1 || choice > options.length) {
    return `model chose out-of-range option ${choice} (1..${options.length})`
  }

  const picked = options[choice - 1] as Record<string, unknown>
  const params: Record<string, unknown> = { ...picked }
  if (decision.duration !== undefined) params.duration = decision.duration
  if (decision.escorts !== undefined && decision.escorts.length > 0) params.escorts = decision.escorts

  const action = typeof picked.action === 'string' ? picked.action : 'Unknown'
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
  peer.handle('decide', async (data: any) => {
    const req = (data ?? {}) as DecideRequest
    logger.info(`avorion-copilot: 为 ${req.ship} 决策中…`)

    let result: StreamResult
    try {
      result = await askModel(ctx, cfg, buildPrompt(req))
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error)
      logger.warn(`avorion-copilot: 模型调用异常 ${message}`)
      return [false, 'MODEL_ERROR', message] as [boolean, any, string]
    }

    if (result.failure !== undefined) {
      logger.warn(`avorion-copilot: 模型调用失败 ${result.failure}`)
      return [false, 'MODEL_FAILED', result.failure] as [boolean, any, string]
    }

    const decision = parseDecision(result.text)
    const answer = toAnswer(req, decision, result.text)

    if (typeof answer === 'string') {
      logger.warn(`avorion-copilot: 决策无法解析 —— ${answer}`)
      return [false, 'BAD_MODEL_REPLY', answer] as [boolean, any, string]
    }

    // 决策记录（含思维链），便于事后回看模型在想什么 ✓
    logger.info(
      `avorion-copilot: ${req.ship} -> ${answer.action}` +
      (answer.reason !== undefined ? `  (${answer.reason})` : '') +
      (result.truncated ? '  [回复被 maxTokens 截断]' : '') +
      (result.reasoning.length > 0 ? `\n--- 思维链 ---\n${result.reasoning.trim()}` : ''),
    )

    return [true, answer] as [boolean, any]
  })

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
  registerFleetTools(ctx, peer)

  // 供将来从 DSH 侧主动操作（例如命令面板、定时巡检）使用 ✓
  void queryShip
  void order
  void reload
}
