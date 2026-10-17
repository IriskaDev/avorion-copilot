/**
 * session-no-prefetch.mjs —— ★★ 会话路径**不再预取计划**的回环联测（2026-10-17 ✓✓）
 *
 * 它钉住的是主人这次点名的不变量 ✗✓：
 *   「会话路径投递任务前的游戏侧总耗时必须是毫秒级」——
 *   也就是说，会话路径在投递 `<fleet_task>` 之前，**只允许**取 goal（毫秒级 ✓），
 *   船卡 / 舰队 / minePlan / salvagePlan / sellPlan / scoutPlan / tradePlan / dossier
 *   一个都不许取 ✓（那些全是游戏主线程同步算的重活，tradePlan 实测 20s+ ✓，
 *   正是"决策过程中不能操作舰船、像连接冻结"的真因 ✗✓）。
 *
 * 两条断言（对应任务的验收点 ✓）：
 *   A. 会话路径（live 模式 + 会话答成了）：decide 期间 `game.queries` 里**不含**
 *      任何 legacy 计划（tradePlan|minePlan|salvagePlan|jobPlan|sellPlan|scoutPlan|dossier）；
 *      只有 `goal`（毫秒级 ✓）。
 *   B. 单发路径（没有会话服务）：decide 期间 `game.queries` **仍含** legacy 计划，
 *      且**有界**（≤ 5 个计划查询：mine/salvage/sell/scout/trade ✓）。
 *
 * 跑法（仓库根或 plugin/ 下都行 ✓）：  node test/session-no-prefetch.mjs
 *
 * ⚠️ 只用 127.0.0.1 + 高位端口（18911 / 18922），跑完立刻关掉 ✓；不碰游戏 8765 ✓。
 * ⚠️ 日志写到临时目录 ✓（先改 USERPROFILE 再 import ✓）。
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

const sandboxHome = fs.mkdtempSync(path.join(os.tmpdir(), 'copilot-no-prefetch-'))
process.env.USERPROFILE = sandboxHome
process.env.HOMEDRIVE = ''
process.env.HOMEPATH = ''

const { apply } = await import('../lib/index.js')

const SHIP = 'Miner-00002'
const HERE = { x: -399, y: 81 }
const LEGACY_PLANS = ['tradePlan', 'minePlan', 'salvagePlan', 'jobPlan', 'sellPlan', 'scoutPlan', 'dossier']

// ---------------------------------------------------------------------------
// 假游戏：按 cmd 回数据，并把 query 的 `what` 逐条记下来（game.queries ✓）
// ---------------------------------------------------------------------------

function gameState() {
  return {
    goal: { text: '在附近挖矿/贸易，风险 <10%', options: [], hasGoal: true },
    shipCard: {
      name: SHIP, sector: { ...HERE }, busy: false, hasCaptain: true,
      captainClass: 'Miner', turretCount: 6, freeCargoSpace: 1000,
      cargoUsed: 100, cargoCapacity: 5000, holdHasGoods: true,
      actionNames: ['Mine', 'Salvage', 'Trade', 'Sell', 'Scout'],
      hyperspace: { reach: 12, canPassRifts: true },
    },
    fleet: {
      designated: 1,
      piloted: 'Player-00001',
      ships: [{ name: SHIP, sector: { ...HERE }, busy: false, hasCaptain: true }],
    },
    queries: [],
  }
}

function reply(game) {
  return (cmd, data) => {
    if (cmd === 'hello') return { side: 'game', ver: 2, caps: ['query', 'order', 'recall', 'reload'] }
    if (cmd === 'order') return { accepted: true, executed: true, ...data, note: 'stub' }
    if (cmd !== 'query') return {}
    const what = data?.what
    game.queries.push(String(what))
    if (what === 'goal') return game.goal
    if (what === 'ship') return game.shipCard
    if (what === 'fleet') return game.fleet
    // ★ 计划一律空载荷 {} —— 插件会按"没取到/无推荐"处理 ✓（不崩、且 query 已记下 ✓）
    return {}
  }
}

function encode(msg) {
  const body = Buffer.from(JSON.stringify(msg), 'utf8')
  const head = Buffer.alloc(4)
  head.writeUInt32LE(body.length, 0)
  return Buffer.concat([head, body])
}

/** 起一个假游戏客户端，连到插件端口；返回 { call, close } ✓ */
async function connectGame(port, game) {
  let sock = null
  for (let i = 0; i < 40 && sock === null; i++) {
    const s = net.connect(port, '127.0.0.1')
    const opened = await new Promise((resolve) => {
      s.once('connect', () => resolve(true))
      s.once('error', () => resolve(false))
    })
    if (opened) sock = s
    else s.destroy()
    if (sock === null) await new Promise((r) => setTimeout(r, 50))
  }
  if (sock === null) throw new Error(`连不上插件端口 ${port}`)

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
        sock.write(encode({ id: msg.id, type: 'response', cmd: msg.cmd, ok: true, data: reply(game)(msg.cmd, msg.data) }))
      } else if (msg.type === 'response') {
        const p = pending.get(msg.id)
        if (p !== undefined) { pending.delete(msg.id); p(msg) }
      }
    }
  })

  const call = (cmd, data, timeoutMs = 30000) => {
    const id = ++nextId
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => { pending.delete(id); reject(new Error(`timeout waiting for ${cmd}`)) }, timeoutMs)
      pending.set(id, (msg) => { clearTimeout(timer); resolve(msg) })
      sock.write(encode({ id, type: 'request', cmd, data }))
    })
  }
  return { call, close: () => sock.destroy() }
}

const checks = []
const check = (label, cond, actual) => checks.push({ label, pass: cond === true, actual })

// ---------------------------------------------------------------------------
// 场景 A：会话路径（live 模式 + 会话答成）—— 投递前绝不预取计划 ✓
// ---------------------------------------------------------------------------

async function scenarioSessionPath() {
  const game = gameState()
  const disposers = []
  const registry = {
    get(id) { return id === 'session-cmdr' ? agent : undefined },
    list() { return [agent] },
  }
  let sessionEventListener = null
  const agent = {
    id: 'session-cmdr',
    status: 'idle',
    inbox: [],
    followup(message) {
      agent.inbox.push(message)
      const text = Array.isArray(message?.content)
        ? message.content.map((b) => b?.text ?? '').join('')
        : ''
      const m = /id="([^"]+)"/.exec(text)
      const taskId = m ? m[1] : 't-unknown'
      // ★ 模拟"她会话自己查完、给结论" ✓（真正的查询由工具做，这里只回答案 ✓）
      setTimeout(() => {
        if (sessionEventListener === null) return
        sessionEventListener({ id: 'session-cmdr' }, {
          type: 'assistant/message',
          message: { role: 'assistant', content: [{ type: 'text', text: `action=None\ntask=${taskId}\nreason=会话路径测试：本鱼自己查 ✓` }] },
        })
        sessionEventListener({ id: 'session-cmdr' }, { type: 'turn/end', reason: { kind: 'stop' } })
      }, 5)
    },
    whenIdle() { return Promise.resolve() },
    cancel() {},
  }
  const ctx = {
    logger: { info: () => {}, warn: (m) => console.log(`   [A plugin warn] ${m}`) },
    effect(fn) { const d = fn(); if (typeof d === 'function') disposers.push(d) },
    tools: { register: () => {} },
    get(name) { return name === 'agents' ? registry : undefined },
    on(_event, listener) { sessionEventListener = listener },
    llm: { async *stream() { yield { type: 'finish', reason: { kind: 'stop' } } } },
  }

  await apply(ctx, { port: 18911, decideMode: 'live', commanderSession: 'session-cmdr' })
  const { call, close } = await connectGame(18911, game)

  // 握手会先来一次 fleet 快照（onConnected ✓）—— 等它落账后再记 qBefore，只关心 decide 期间的 query ✓
  await new Promise((r) => setTimeout(r, 150))
  const qBefore = game.queries.length
  const r = await call('decide', { ship: SHIP, hasGoal: true })
  const qDuring = game.queries.slice(qBefore)

  console.log(`\n[A] 会话路径 decide 期间的 query: ${qDuring.join(', ')}`)
  check('A. decide 成功', r.ok === true, r)
  check('A. 会话收到了任务块（followup 一次 ✓）', agent.inbox.length === 1, agent.inbox.length)
  check('A. 任务块是 <fleet_task>（只告知 ✓）',
    agent.inbox[0] !== undefined && /<fleet_task id="[^"]+" ship="Miner-00002"/.test(agent.inbox[0]?.content?.[0]?.text ?? ''), '')
  check('A. ★ decide 期间不含任何 legacy 计划（tradePlan/minePlan/…/dossier ✓✓）',
    qDuring.every((w) => !LEGACY_PLANS.includes(w)), qDuring.join(','))
  check('A. ★ decide 期间只有 goal（毫秒级 ✓）', qDuring.length === 1 && qDuring[0] === 'goal', qDuring.join(','))

  for (const d of disposers) { try { d() } catch { /* noop */ } }
  close()
}

// ---------------------------------------------------------------------------
// 场景 B：单发路径（没有会话服务）—— 仍预取计划，且**有界** ✓
// ---------------------------------------------------------------------------

async function scenarioSingleShotPath() {
  const game = gameState()
  const disposers = []
  const ctx = {
    logger: { info: () => {}, warn: (m) => console.log(`   [B plugin warn] ${m}`) },
    effect(fn) { const d = fn(); if (typeof d === 'function') disposers.push(d) },
    tools: { register: () => {} },
    llm: {
      async *stream() {
        yield { type: 'reasoning-delta', index: 0, text: '（假模型）推理……' }
        yield { type: 'text-delta', index: 1, text: 'action=None\nreason=单发路径测试 ✓' }
        yield { type: 'finish', reason: { kind: 'stop' } }
      },
    },
  }

  await apply(ctx, { port: 18922 })
  const { call, close } = await connectGame(18922, game)

  // 同上：等握手 fleet 快照落账 ✓
  await new Promise((r) => setTimeout(r, 150))
  const qBefore = game.queries.length
  const r = await call('decide', { ship: SHIP, hasGoal: true })
  const qDuring = game.queries.slice(qBefore)
  const legacyDuring = qDuring.filter((w) => LEGACY_PLANS.includes(w))

  console.log(`\n[B] 单发路径 decide 期间的 query: ${qDuring.join(', ')}`)
  check('B. decide 成功', r.ok === true, r)
  check('B. ★ 仍含 legacy 计划（单发没工具，必须预取 ✓）', legacyDuring.length > 0, legacyDuring.join(','))
  check('B. ★ legacy 计划查询**有界**（≤ 5 个：mine/salvage/sell/scout/trade ✓）',
    legacyDuring.length <= 5, `${legacyDuring.length} 个: ${legacyDuring.join(',')}`)

  for (const d of disposers) { try { d() } catch { /* noop */ } }
  close()
}

try {
  await scenarioSessionPath()
  await scenarioSingleShotPath()
} catch (error) {
  console.log(`\n✗ 测试抛异常: ${error?.stack ?? error}`)
  process.exit(1)
}

const failed = checks.filter((c) => !c.pass)
console.log(`\n== 共 ${checks.length} 项断言，失败 ${failed.length} 项 ==`)
for (const f of failed) console.log(`  ✗ ${f.label}  → 实际: ${JSON.stringify(f.actual)}`)
console.log(failed.length === 0 ? 'sessionNoPrefetch: OK' : 'sessionNoPrefetch: FAILED')
try { fs.rmSync(sandboxHome, { recursive: true, force: true }) } catch { /* noop */ }
process.exit(failed.length === 0 ? 0 : 1)
