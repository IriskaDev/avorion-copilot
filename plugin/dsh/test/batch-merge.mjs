/**
 * batch-merge.mjs —— ★★ A/B/C 三项的**离线 + 插件级**联测（2026-10-18 ✓）
 *
 * 主人的原话（这是本次要治的病 ✓）：
 *   「我感觉你总是会漏，尤其是多个决策同时来的时候」
 *
 * 已确认的机制事实（真机日志 2026-10-18 08:50:58，逐字 ✓）：
 *   ▶ 收到 decide  ship=Scout-00001        ← 同一秒
 *   ▶ 收到 decide  ship=Trader-00001       ← 同一秒
 *   [session] 投递任务 t-805bcccf → 会话      （第一条投出去了）
 *   [ladder] 投递会话**正忙**（主人在聊 / 在别的任务上）
 *   [ladder] ★ 指挥官会话在线但本轮没答成（SESSION_BUSY）→ 兜底 = None（fallbackNone）
 *   ├ 待命裁定：Trader-00001 … 冷却 20 分钟   ← ★ 这艘船静默 20 分钟 ✗✗
 *   → decisions.log 里 `fallbackNone` 17 条 ✓（与会话里被打断/漏答对得上 ✓）
 *
 * 本文件验三件事：
 *   A. **合并投递**：3 艘同时空闲 → **只投一次** ✓；块里列出 3 艘 ✓；解析器吃下 3 组答案 ✓；
 *      单船单条**向后兼容**（块与校验器逐字不变 ✓）。
 *   B. **未答重发**：某条没答到 → 记 `unanswered` ✓ → 短间隔后**重新投递** ✓ →
 *      而且**不进** 20 分钟冷却 ✓（真机症状消失 ✓）。连续 3 次没答才落 None ✓。
 *   C. **冷却分级**：`fallbackNone`（漏）用短冷却 ✓；决策者**明确写 action=None** 才用长冷却 ✓。
 *
 * 跑法: node test/batch-merge.mjs   （退出码 0 = 全过 ✓）
 */
import net from 'node:net'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { registerHooks } from 'node:module'

registerHooks({
  resolve(spec, _ctx, next) {
    if (spec === '@deepseek-ai/dsh-llm') {
      return { url: new URL('./llm-stub.mjs', import.meta.url).href, shortCircuit: true }
    }
    if (spec === '@deepseek-ai/dsh-tools') {
      return { url: new URL('./tools-stub.mjs', import.meta.url).href, shortCircuit: true }
    }
    return next(spec, _ctx)
  },
})

const sandboxHome = fs.mkdtempSync(path.join(os.tmpdir(), 'copilot-batch-merge-'))
process.env.USERPROFILE = sandboxHome
process.env.HOMEDRIVE = ''
process.env.HOMEPATH = ''

const checks = []
const check = (label, pass, actual) => checks.push({ label, pass: pass === true, actual })
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

// ---------------------------------------------------------------------------
// ⓪ 纯函数层：块渲染 + 多组解析器 + 冷却分级（不必起插件 ✓）
// ---------------------------------------------------------------------------
{
  const { renderTaskBatchBlock, renderTaskBlock, validateAnswers, validateAnswer } =
    await import('../lib/task.js')
  const { recordStandby, standbyVerdict, resetStandbyCache } = await import('../lib/standby.js')

  const item = (i, ship, opts = []) => ({
    taskId: `t-1a2b3c0${i}`, ship, goalText: '在附近挖矿', goalOptions: opts, deadlineHintSec: 20,
  })
  const one = item(1, 'Miner-00001')
  const three = [item(1, 'Miner-00001'), item(2, 'Trader-00002', ['Trade']), item(3, 'Scout-00003')]

  // A-① 向后兼容：1 条 = 与 renderTaskBlock **逐字相同** ✓
  check('A. 1 条时合并块 === 单船块（逐字相同 ✓）',
    renderTaskBatchBlock({ items: [one] }) === renderTaskBlock(one), '')

  // A-② 3 艘：一个块、列出 3 艘 + 3 个任务号、仍然 < 2 KB ✓、不带数据 ✓
  const b3 = renderTaskBatchBlock({ items: three })
  const bytes3 = Buffer.byteLength(b3, 'utf8')
  check('A. 3 艘合并成一个块（只有一段 <fleet_task> ✓）',
    (b3.match(/<fleet_task/g) ?? []).length === 1 && (b3.match(/<\/fleet_task>/g) ?? []).length === 1, '')
  check('A. 块里列出**全部 3 艘**船 ✓',
    three.every((t) => b3.includes(t.ship)), b3.slice(0, 160))
  check('A. 块里列出**全部 3 个**任务号 ✓',
    three.every((t) => b3.includes(t.taskId)), '')
  check('A. ★ 3 艘块仍然 < 2000 字节（2 KB 契约 ✓）', bytes3 < 2000, bytes3)
  check('A. 块里**没有**船卡/计划数据（只告知 ✓）',
    !b3.includes('cargoCapacity') && !b3.includes('actionNames'), '')
  check('A. 块里写明"可以一次回多组" + 按 task= 对上号 ✓',
    /多组/.test(b3) && /task=/.test(b3), '')

  // A-③ 解析器：3 组答案（每组 action + task）→ 3 条各自正确 ✓
  const reply3 = [
    'action=Mine', 'task=t-1a2b3c01', 'x=-399', 'y=81', 'size=15', '',
    'action=Trade', 'task=t-1a2b3c02', 'x=-385', 'y=65', 'sizeX=17', 'sizeY=17', 'deposit=200000', '',
    'action=Scout', 'task=t-1a2b3c03', 'x=-319', 'y=110', 'size=21', '',
    '两组半都答完了，主人～',
  ].join('\n')
  const specs = three.map((t) => ({ taskId: t.taskId, ship: t.ship, allowedActions: ['Mine', 'Trade', 'Scout'] }))
  const multi = validateAnswers(reply3, specs)
  check('A. 解析器吃到 **3 组** ✓', multi.groups === 3 && multi.echoedGroups === 3, multi)
  check('A. 每艘船拿到**自己那条**动作 ✓（按 task id 匹配，不是按顺序猜 ✗）',
    multi.verdicts.get('t-1a2b3c01')?.ok === true && multi.verdicts.get('t-1a2b3c01').answer.action === 'Mine'
    && multi.verdicts.get('t-1a2b3c02')?.answer.action === 'Trade'
    && multi.verdicts.get('t-1a2b3c03')?.answer.action === 'Scout', '')
  check('A. 每艘船的参数也跟着**对号** ✓（Trade 的框/本金只落在 Trader 身上）',
    multi.verdicts.get('t-1a2b3c02').answer.params.deposit === 200000
    && multi.verdicts.get('t-1a2b3c01').answer.params.size === 15
    && multi.verdicts.get('t-1a2b3c03').answer.params.size === 21, '')

  // A-④ 组顺序乱也认 ✓（按 task= 匹配）
  const shuffled = ['action=Scout', 'task=t-1a2b3c03', 'size=21', '',
    'action=Mine', 'task=t-1a2b3c01', 'size=15', '',
    'action=Trade', 'task=t-1a2b3c02', 'deposit=1000'].join('\n')
  const m2 = validateAnswers(shuffled, specs)
  check('A. 组顺序打乱也按 task= 对号 ✓',
    m2.verdicts.get('t-1a2b3c01')?.answer.action === 'Mine'
    && m2.verdicts.get('t-1a2b3c02')?.answer.action === 'Trade'
    && m2.verdicts.get('t-1a2b3c03')?.answer.action === 'Scout', '')

  // A-⑤ 只答了 2 组 → 第 3 艘**没有**结论（= 没答到 ✓，交给 B 重投 ✓）
  const partial = ['action=Mine', 'task=t-1a2b3c01', 'size=15', '', 'action=Trade', 'task=t-1a2b3c02'].join('\n')
  const m3 = validateAnswers(partial, specs)
  check('A. 只答 2 组 → 第 3 艘**没有**结论（= 没答到 ✓）',
    m3.verdicts.get('t-1a2b3c01')?.ok === true && m3.verdicts.get('t-1a2b3c02')?.ok === true
    && m3.verdicts.get('t-1a2b3c03') === undefined, [...m3.verdicts.keys()])

  // A-⑥ 别船的 task= **绝不采纳** ✓（记 stray，不配给任何船）
  const stray = ['action=Mine', 'task=t-99999999', 'size=15'].join('\n')
  const m4 = validateAnswers(stray, specs)
  check('A. 未知/别船的 task= 记 stray、**绝不**配给本批的船 ✓',
    m4.stray.includes('t-99999999') && m4.verdicts.size === 0, m4.stray)
  // 单条语义**逐字不变** ✓（回显写错仍是 TASK_MISMATCH ✓）
  check('A. 单条向后兼容：回显写错仍判 TASK_MISMATCH ✓',
    validateAnswer('action=Mine\ntask=t-2', 't-1', ['Mine']).code === 'TASK_MISMATCH', '')

  // C：冷却**分级** ✓
  resetStandbyCache()
  const fp = 'goal|Mine'
  // C-① 明确 None → 长冷却（20 分钟 ✓）
  recordStandby('S-1', 'session', '她判了待命', fp, Date.now(), { kind: 'none' })
  const v1 = standbyVerdict('S-1', 'goal', ['Mine'], 20 * 60_000, Date.now() + 60_000, 3 * 60_000)
  check('C. 明确 None → 20 分钟冷却（1 分钟后仍在冷却 ✓）',
    v1.kind === 'standby' && v1.entry.kind === 'none' && v1.minsLeft >= 18, v1)

  // C-② 漏答（fallbackNone）→ **短**冷却 ✓
  recordStandby('S-2', 'fallbackNone', '会话忙', fp, Date.now(), { kind: 'unanswered', misses: 1 })
  const v2 = standbyVerdict('S-2', 'goal', ['Mine'], 20 * 60_000, Date.now() + 60_000, 3 * 60_000)
  check('C. 漏答 → 短冷却（3 分钟 ✓，1 分钟后仍冷却 ✓）',
    v2.kind === 'standby' && v2.entry.kind === 'unanswered' && v2.cooldownMs === 3 * 60_000, v2)
  const v2b = standbyVerdict('S-2', 'goal', ['Mine'], 20 * 60_000, Date.now() + 4 * 60_000, 3 * 60_000)
  check('C. ★ 漏答 3 分钟后就**恢复征询**（不再静默 20 分钟 ✓✓）', v2b.kind === 'consult', v2b)

  // C-③ 连续 3 次漏答 → 才落到 None + 长冷却 ✓
  resetStandbyCache()
  recordStandby('S-3', 'fallbackNone', 'x', fp, Date.now(), { kind: 'unanswered', misses: 1 })
  recordStandby('S-3', 'fallbackNone', 'x', fp, Date.now(), { kind: 'unanswered', misses: 2 })
  const v3a = standbyVerdict('S-3', 'goal', ['Mine'], 20 * 60_000, Date.now(), 3 * 60_000)
  check('C. 第 2 次漏答仍是短冷却 ✓（还没落 None ✓）',
    v3a.kind === 'standby' && v3a.entry.kind === 'unanswered', v3a)
  const e3 = recordStandby('S-3', 'fallbackNone', 'x', fp, Date.now(), { kind: 'unanswered', misses: 3 })
  const v3b = standbyVerdict('S-3', 'goal', ['Mine'], 20 * 60_000, Date.now() + 60_000, 3 * 60_000)
  check('C. ★ 连续 3 次漏答 → 落到 None（20 分钟 ✓，避免无限刷 ✓）',
    e3.kind === 'none' && v3b.kind === 'standby' && v3b.entry.kind === 'none' && v3b.minsLeft >= 18, v3b)
  resetStandbyCache()
}

// ---------------------------------------------------------------------------
// ① 插件级：假游戏 TCP + 假「投递会话」agent（真 apply ✓）
// ---------------------------------------------------------------------------
const PORT = 18941
const HERE = { x: -399, y: 81 }
const ALLOWED = ['Mine', 'Salvage', 'Trade', 'Sell', 'Scout', 'Travel']

const game = { goal: { text: '在附近挖矿', options: [], hasGoal: true }, shipCard: null, fleet: null, orders: [] }
const SHIPS = ['Miner-00001', 'Trader-00002', 'Scout-00003']
game.shipCard = (name) => ({
  name, sector: { ...HERE }, busy: false, hasCaptain: true, actionNames: [],
})
game.fleet = () => ({ designated: 3, piloted: 'Player-00001', ships: SHIPS.map((n) => ({ name: n, sector: { ...HERE }, busy: false, hasCaptain: true })) })

function reply(cmd, data) {
  if (cmd === 'hello') return { side: 'game', ver: 2, caps: ['query', 'order', 'recall', 'reload'] }
  if (cmd === 'order') { game.orders.push(data); return { accepted: true, executed: true, ...data } }
  if (cmd !== 'query') return {}
  if (data?.what === 'goal') {
    const ship = data.ship
    return { ship, ...game.goal }
  }
  if (data?.what === 'ship') return game.shipCard(data.ship)
  if (data?.what === 'fleet') return game.fleet()
  return {}
}

function encode(msg) {
  const body = Buffer.from(JSON.stringify(msg), 'utf8')
  const head = Buffer.alloc(4)
  head.writeUInt32LE(body.length, 0)
  return Buffer.concat([head, body])
}

// ---- 假「投递会话」：收到块 → 按脚本回几组答案 → turn/end ✓
const sessionId = 'session-cmdr-test'
// ★ 插件侧的监听器签名是 `(session, event)`（见 index.ts 的 `ctx.on('session/event', …)` ✓）——
//   所以派发事件时**必须**带上 `{ id }` 这个第一参数 ✓（否则插件按 sessionId 路由时就把它筛掉了 ✗）。
const SESSION = { id: sessionId }
const agentState = { status: 'idle', inbox: [], deliveries: 0, replyFn: () => [] }
const eventListeners = new Set()

const agent = {
  id: sessionId,
  get status() { return agentState.status },
  set status(v) { agentState.status = v },
  followup(message) {
    const text = (message?.content ?? []).map((b) => b?.text ?? '').join('')
    agentState.inbox.push(text)
    agentState.deliveries += 1
    agent.status = 'running'
    setTimeout(() => {
      const roundIndex = agentState.deliveries
      const groups = agentState.replyFn(roundIndex, text) || []
      for (const g of groups) {
        for (const fn of [...eventListeners]) {
          fn(SESSION, { type: 'assistant/message', data: { message: { role: 'assistant', content: [{ type: 'text', text: g }] } } })
        }
      }
      for (const fn of [...eventListeners]) fn(SESSION, { type: 'turn/end', data: { reason: { kind: 'completed' } } })
      agent.status = 'idle'
    }, 120)
  },
  whenIdle() { return Promise.resolve() },
  cancel() { agent.status = 'idle' },
}
const registry = { get: (id) => (id === sessionId ? agent : undefined), list: () => [agent] }

const disposers = []
const ctx = {
  logger: { info: () => {}, warn: (m) => console.log(`   [plugin warn] ${m}`) },
  effect(fn) { const d = fn(); if (typeof d === 'function') disposers.push(d) },
  tools: { register: () => {} },
  get: (n) => (n === 'agents' ? registry : undefined),
  on: (ev, fn) => { eventListeners.add(fn); return () => eventListeners.delete(fn) },
  llm: {
    async *stream() {
      yield { type: 'text-delta', index: 0, text: 'action=None\nreason=（测试里不该走到单发 ✓）' }
      yield { type: 'finish', reason: { kind: 'stop' } }
    },
  },
}
// ctx.on('session/event', (session, event)) —— 插件按 session.id 路由 ✓
{
  const origOn = ctx.on
  ctx.on = (ev, fn) => origOn(ev, function (session, event) {
    if (session?.id !== sessionId) return
    return fn(session, event)
  })
}

const { apply, decisionLog } = await import('../lib/index.js')

const MERGE_MS = 300
const RETRY_MS = 600
await apply(ctx, {
  port: PORT,
  commanderSession: sessionId,
  decideMode: 'live',
  noneCooldownMs: 60_000,
  mergeWindowMs: MERGE_MS,
  unansweredRetryMs: RETRY_MS,
  unansweredMaxMisses: 3,
})

let sock = null
for (let i = 0; i < 40 && sock === null; i++) {
  const s = net.connect(PORT, '127.0.0.1')
  const opened = await new Promise((resolve) => {
    s.once('connect', () => resolve(true))
    s.once('error', () => resolve(false))
  })
  if (opened) sock = s
  else s.destroy()
  if (sock === null) await sleep(50)
}
if (sock === null) {
  console.log('✗ 连不上插件端口 —— 测试无法进行')
  process.exit(1)
}

let rx = Buffer.alloc(0)
let nextId = 0
const pending = new Map()
sock.on('data', (chunk) => {
  rx = Buffer.concat([rx, chunk])
  for (;;) {
    if (rx.length < 4) return
    const len = rx.readUInt32LE(0)
    if (rx.length < 4 + len) return
    const msg = JSON.parse(rx.subarray(4, 4 + len).toString('utf8'))
    rx = rx.subarray(4 + len)
    if (msg.type === 'request') {
      sock.write(encode({ id: msg.id, type: 'response', cmd: msg.cmd, ok: true, data: reply(msg.cmd, msg.data) }))
    } else if (msg.type === 'response') {
      const p = pending.get(msg.id)
      if (p !== undefined) { pending.delete(msg.id); p(msg) }
    }
  }
})

function call(cmd, data, timeoutMs = 30000) {
  const id = ++nextId
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => { pending.delete(id); reject(new Error(`timeout waiting for ${cmd}`)) }, timeoutMs)
    pending.set(id, (msg) => { clearTimeout(timer); resolve(msg) })
    sock.write(encode({ id, type: 'request', cmd, data }))
  })
}

/** 从块里取出这条块**要求**的任务号（block 头或逐条行 ✓） */
function taskIdsIn(block) {
  const ids = []
  for (const m of block.matchAll(/task=(t-[0-9a-f]{8})/g)) ids.push(m[1])
  for (const m of block.matchAll(/id="(t-[0-9a-f]{8})"/g)) ids.push(m[1])
  return [...new Set(ids)]
}
const answerFor = (id, ship, action = 'Mine') => [
  `action=${action}`, `task=${id}`, 'x=-399', 'y=81', 'size=15', 'reason=测试答案',
].join('\n')

try {
  await sleep(150)

  // ---- A：3 艘同时空闲 → **只投一次**、一个块列出 3 艘、解析器吃下 3 组 ✓ ----
  agentState.replyFn = (_round, block) => {
    const ids = taskIdsIn(block)
    const acts = ['Mine', 'Trade', 'Scout']
    return ids.map((id, i) => answerFor(id, SHIPS[i], acts[i % acts.length]))
  }
  const beforeA = agentState.deliveries
  const [r1, r2, r3] = await Promise.all([
    call('decide', { ship: SHIPS[0], hasGoal: true }),
    call('decide', { ship: SHIPS[1], hasGoal: true }),
    call('decide', { ship: SHIPS[2], hasGoal: true }),
  ])
  const deliveriesA = agentState.deliveries - beforeA
  const blockA = agentState.inbox[agentState.inbox.length - 1]
  console.log('\n=== A：3 艘同时空闲 — 合并块的原文 ===')
  console.log(blockA)
  check('A. ★ 3 艘同时空闲 → 只投递了 **1 次** ✓', deliveriesA === 1, deliveriesA)
  check('A. ★ 块里列出全部 3 艘船 ✓', SHIPS.every((n) => blockA.includes(n)), '')
  check('A. ★ 块里列出 3 个任务号 ✓', taskIdsIn(blockA).length === 3, taskIdsIn(blockA))
  check('A. 3 条 decide 都拿到了自己的答案 ✓（一条都没漏 ✓）',
    [r1, r2, r3].every((r) => r.ok === true && typeof r.data?.action === 'string' && r.data.action !== 'None'),
    [r1.data, r2.data, r3.data])
  check('A. 三条答案**各不相同**（说明是按 task= 对号分发的 ✓）',
    new Set([r1.data?.action, r2.data?.action, r3.data?.action]).size === 3,
    [r1.data?.action, r2.data?.action, r3.data?.action])
  check('A. 三条都真的下单了（orders 里有 3 艘船 ✓）',
    SHIPS.every((n) => game.orders.some((o) => o.ship === n)), game.orders.map((o) => o.ship))

  // ---- B：某条没答到 → 短间隔后**重投**，且**不进** 20 分钟冷却 ✓ ----
  // 第 1 轮只答前两艘；第 2 轮（重投）答那一艘 ✓
  let bRound = 0
  agentState.replyFn = (_round, block) => {
    const ids = taskIdsIn(block)
    bRound += 1
    if (bRound === 1 && ids.length >= 3) return ids.slice(0, 2).map((id) => answerFor(id, 'x'))
    return ids.map((id) => answerFor(id, 'x', 'Salvage'))
  }
  const beforeB = agentState.deliveries
  const ordersBeforeB = game.orders.length
  const b1 = await Promise.all([
    call('decide', { ship: SHIPS[0], hasGoal: true }),
    call('decide', { ship: SHIPS[1], hasGoal: true }),
    call('decide', { ship: SHIPS[2], hasGoal: true }),
  ])
  const missed = [b1[0], b1[1], b1[2]].filter((r) => r.data?.action === 'None')
  check('B. 有一艘本轮没答到 → 它这一轮是 None（本来就会这样 ✓）', missed.length === 1, b1.map((r) => r.data?.action))
  const deliveredImmediately = agentState.deliveries - beforeB
  check('B. ★ 没答到**没有**立刻把三艘都判掉（只有 1 艘是 None ✓）', deliveredImmediately === 1, deliveredImmediately)

  // 等短重投（RETRY_MS=600ms；心跳=200ms ✓）—— 绝不等到 20 分钟 ✓
  const t0 = Date.now()
  let retried = false
  for (let i = 0; i < 60 && !retried; i++) {
    await sleep(100)
    if (agentState.deliveries - beforeB >= 2) retried = true
  }
  const retryAfterMs = Date.now() - t0
  const blockB2 = agentState.inbox[agentState.inbox.length - 1]
  check('B. ★ 没答到的船被**重新投递**了 ✓（第 2 次投递真的发生 ✓）', retried, { deliveries: agentState.deliveries - beforeB })
  check('B. ★ 重投发生在**短间隔**内（远小于 20 分钟 ✓）', retryAfterMs < 5000, retryAfterMs)
  check('B. 重投的块里只列那艘没答到的船 ✓（不是又投一遍全部 ✗）',
    taskIdsIn(blockB2).length === 1, taskIdsIn(blockB2))
  await sleep(600)
  const newOrders = game.orders.slice(ordersBeforeB)
  check('B. ★ 重投后这艘船**真的拿到了动作并下单** ✓（不再静默 ✓）',
    newOrders.length >= 2, newOrders.map((o) => `${o.ship}:${o.action}`))
  check('B. ★ 重投**没有**触发 20 分钟待命冷却 ✓（下一次 decide 仍会投递 ✓）', (() => {
    const standbyHit = decisionLog.slice(-4).some((r) => /待命裁定/.test(String(r.message ?? r.code ?? '')))
    return standbyHit === false
  })(), decisionLog.slice(-3).map((r) => r.answer?.action))

  // ---- B/C：连续 3 次没答到 → 才落 None ✓ ----
  agentState.replyFn = () => []   // 一次都不答 ✓
  const beforeC = agentState.deliveries
  // 每轮都只答 0 组 → 每轮都会"没答到"，短重投会自己累加 ✓
  await call('decide', { ship: SHIPS[0], hasGoal: true })   // 第 1 次漏
  await sleep(900)
  await sleep(900)
  // 到这一步：至少 2~3 次漏答已发生（浏览器定时器每 200ms 一跳，重投 600ms 一次 ✓）
  const missedRounds = agentState.deliveries - beforeC
  check('B. 一直答不上来时会**多次重投**（不是一次就静默 ✓）', missedRounds >= 2, missedRounds)
  await sleep(1500)
  const afterLimit = agentState.deliveries
  await sleep(1200)
  const stopped = agentState.deliveries === afterLimit
  check('B. ★ 连续 3 次没答到后**停止重投**（绝不无限刷 ✓）', stopped, agentState.deliveries - beforeC)

  // ---- C：决策者**明确 None** → 仍按原（长）冷却 ✓ ----
  agentState.replyFn = (_round, block) => {
    const ids = taskIdsIn(block)
    return ids.map((id) => [`action=None`, `task=${id}`, 'reason=本鱼判它待命 ✓'].join('\n'))
  }
  const beforeD = agentState.deliveries
  const d1 = await call('decide', { ship: 'Miner-None-1', hasGoal: true })
  check('C. 明确 None 的 decide 成功 ✓', d1.ok === true && d1.data?.action === 'None', d1.data)
  const deliveriesAfterNone = agentState.deliveries - beforeD
  const d2 = await call('decide', { ship: 'Miner-None-1', hasGoal: true })
  check('C. ★ 明确 None 之后，冷却期内**不再投递**（长冷却 ✓）',
    agentState.deliveries - beforeD === deliveriesAfterNone, {
      deliveries: agentState.deliveries - beforeD, expected: deliveriesAfterNone,
    })
  check('C. 冷却期内的 decide 仍是 None 且理由写明待命裁定 ✓',
    d2.data?.action === 'None' && /待命裁定/.test(String(d2.data?.reason ?? '')), d2.data?.reason)

  // ---- 日志可见性（B 的"unanswered 可见" ✓） ----
  const liveLog = path.join(sandboxHome, 'AppData', 'Roaming', 'Avorion', 'moddata', 'copilot', 'decisions.live.log')
  const logText = fs.existsSync(liveLog) ? fs.readFileSync(liveLog, 'utf8') : ''
  check('B. 流水里能看到「漏答（不是决策」✓', /漏答（不是决策/.test(logText), '')
  check('B. 流水里能看到「后重投」✓', /后重投/.test(logText), '')
  check('A. 流水里能看到「合并投递」✓', /合并投递/.test(logText), '')
} catch (error) {
  check(`回环流程抛错：${String(error)}`, false, error?.stack ?? String(error))
}

const failed = checks.filter((c) => !c.pass)
for (const c of checks) console.log(`${c.pass ? '  ✓' : '  ✗'} ${c.label}${c.pass ? '' : `  ← 实际 ${JSON.stringify(c.actual)}`}`)
// ★ 失败时把流水尾部打出来（排查靠证据，不靠猜 ✓）
if (failed.length > 0) {
  const liveLog = path.join(sandboxHome, 'AppData', 'Roaming', 'Avorion', 'moddata', 'copilot', 'decisions.live.log')
  if (fs.existsSync(liveLog)) {
    console.log('\n--- decisions.live.log 末尾 ---')
    console.log(fs.readFileSync(liveLog, 'utf8').split('\n').slice(-40).join('\n'))
  }
}
console.log(`\n== 共 ${checks.length} 项断言，失败 ${failed.length} 项 ==`)
console.log(`== 投递会话共收到 ${agentState.deliveries} 个块（合并 + 重投 ✓） ==`)

for (const d of disposers) { try { d() } catch { /* noop */ } }
try { sock.destroy() } catch { /* noop */ }
if (failed.length === 0) {
  try { fs.rmSync(sandboxHome, { recursive: true, force: true }) } catch { /* noop */ }
}
process.exit(failed.length === 0 ? 0 : 1)
