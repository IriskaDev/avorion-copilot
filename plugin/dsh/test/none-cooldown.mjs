/**
 * none-cooldown.mjs —— ★★ 「尊重 None」的待命裁定回环联测（2026-10-17 主人要求 ✓✓）
 *
 * 主人的话：「决策者判某船"待命（None）"后，不要几分钟就再问同一艘船。」
 *
 * 验三件事（对应任务要求 (c) ✓）：
 *   ① 决策者判 None 后，同船在冷却期内**不再被征询**（模型调用次数不再增长 ✓）；
 *   ② 记录里能看到 decider 来源（首轮 single-shot、待命轮 fallbackNone ✓）；
 *   ③ 状态变化（玩家改动目标）后**恢复征询**（模型再次被调用 ✓）。
 *
 * 用单发路径（没有会话服务）驱动 apply ✓ —— 与 rendezvous-flow.mjs 同一套假游戏骨架 ✓。
 *
 * 跑法: node test/none-cooldown.mjs   （退出码 0 = 全过 ✓）
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

const sandboxHome = fs.mkdtempSync(path.join(os.tmpdir(), 'copilot-none-cooldown-'))
process.env.USERPROFILE = sandboxHome
process.env.HOMEDRIVE = ''
process.env.HOMEPATH = ''

const { apply, decisionLog } = await import('../lib/index.js')

const PORT = 18931 // ★ 与其他测试端口错开 ✓
const SHIP = 'Miner-00003'
const HERE = { x: -399, y: 81 }

const game = {
  goal: { text: '在附近挖矿', options: [], hasGoal: true },
  shipCard: {
    name: SHIP, sector: { ...HERE }, busy: false, hasCaptain: true,
    // ★ 空能力清单 → prefetch 不拉任何 legacy 计划（只有 goal + ship 两次查询 ✓）
    actionNames: [],
  },
  fleet: { designated: 1, piloted: 'Player-00001', ships: [{ name: SHIP, sector: { ...HERE }, busy: false, hasCaptain: true }] },
  orders: [],
}

function reply(cmd, data) {
  if (cmd === 'hello') return { side: 'game', ver: 2, caps: ['query', 'order', 'recall', 'reload'] }
  if (cmd === 'order') { game.orders.push(data); return { accepted: true, executed: true, ...data } }
  if (cmd !== 'query') return {}
  if (data?.what === 'goal') return game.goal
  if (data?.what === 'ship') return game.shipCard
  if (data?.what === 'fleet') return game.fleet
  return {}
}

function encode(msg) {
  const body = Buffer.from(JSON.stringify(msg), 'utf8')
  const head = Buffer.alloc(4)
  head.writeUInt32LE(body.length, 0)
  return Buffer.concat([head, body])
}

// ---------------------------------------------------------------------------
// 起插件（假 ctx，无 agents → 单发路径）→ 连上去 → 当"游戏"发 decide ✓
// ---------------------------------------------------------------------------

const disposers = []
let modelCalls = 0
const ctx = {
  logger: { info: () => {}, warn: (m) => console.log(`   [plugin warn] ${m}`) },
  effect(fn) { const d = fn(); if (typeof d === 'function') disposers.push(d) },
  tools: { register: () => {} },
  llm: {
    async *stream() {
      modelCalls += 1
      yield { type: 'reasoning-delta', index: 0, text: '（假模型）本鱼判这艘船待命。' }
      yield { type: 'text-delta', index: 1, text: 'action=None\nreason=本鱼判它待命 ✓' }
      yield { type: 'finish', reason: { kind: 'stop' } }
    },
  },
}

await apply(ctx, { port: PORT, noneCooldownMs: 60_000 })

let sock = null
for (let i = 0; i < 40 && sock === null; i++) {
  const s = net.connect(PORT, '127.0.0.1')
  const opened = await new Promise((resolve) => {
    s.once('connect', () => resolve(true))
    s.once('error', () => resolve(false))
  })
  if (opened) sock = s
  else s.destroy()
  if (sock === null) await new Promise((r) => setTimeout(r, 50))
}
if (sock === null) { console.log('✗ 连不上插件端口 —— 测试无法进行'); process.exit(1) }

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

function call(cmd, data, timeoutMs = 20000) {
  const id = ++nextId
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => { pending.delete(id); reject(new Error(`timeout waiting for ${cmd}`)) }, timeoutMs)
    pending.set(id, (msg) => { clearTimeout(timer); resolve(msg) })
    sock.write(encode({ id, type: 'request', cmd, data }))
  })
}

const checks = []
const check = (label, cond, actual) => checks.push({ label, pass: cond === true, actual })

try {
  await new Promise((r) => setTimeout(r, 150))   // 等握手 fleet 快照落账 ✓

  // ---- ① 首轮：单发判 None → 记待命 ✓ ----
  const r1 = await call('decide', { ship: SHIP, hasGoal: true })
  check('① decide 成功', r1.ok === true, r1)
  check('① 首轮 action=None', r1.data?.action === 'None', r1.data?.action)
  check('① 首轮问了模型一次（单发 ✓）', modelCalls === 1, modelCalls)
  check('① 记录 decider = single-shot', decisionLog[decisionLog.length - 1]?.decider === 'single-shot',
    decisionLog[decisionLog.length - 1]?.decider)

  // ---- ② 冷却期内再问 → 待命裁定，**不再征询模型** ✓ ----
  const r2 = await call('decide', { ship: SHIP, hasGoal: true })
  check('② 冷却期内 decide 成功', r2.ok === true, r2)
  check('② 仍是 action=None', r2.data?.action === 'None', r2.data?.action)
  check('② ★ 冷却期内**没有**再问模型（modelCalls 仍是 1 ✓）', modelCalls === 1, modelCalls)
  check('② reason 说明是待命裁定', /待命裁定/.test(r2.data?.reason ?? ''), r2.data?.reason)
  check('② 记录 decider = fallbackNone', decisionLog[decisionLog.length - 1]?.decider === 'fallbackNone',
    decisionLog[decisionLog.length - 1]?.decider)

  // ---- ③ 玩家改了目标 → 恢复征询 ✓ ----
  game.goal = { text: '改为跑贸易', options: [], hasGoal: true }
  const r3 = await call('decide', { ship: SHIP, hasGoal: true })
  check('③ 目标改变后 decide 成功', r3.ok === true, r3)
  check('③ ★ 状态变化后**恢复征询**（模型再次被调用 ✓）', modelCalls === 2, modelCalls)
  check('③ 这轮又是 None（单发判的）', r3.data?.action === 'None', r3.data?.action)
} catch (error) {
  check(`回环流程抛错：${String(error)}`, false, error?.stack ?? String(error))
}

const failed = checks.filter((c) => !c.pass)
for (const c of checks) console.log(`${c.pass ? '  ✓' : '  ✗'} ${c.label}${c.pass ? '' : `  ← 实际 ${JSON.stringify(c.actual)}`}`)
console.log(`\n== 共 ${checks.length} 项断言，失败 ${failed.length} 项 ==`)
console.log(`== 模型调用共 ${modelCalls} 次（预期 2 次：首轮 + 目标改变后的恢复轮 ✓） ==`)

for (const d of disposers) { try { d() } catch { /* noop */ } }
try { sock.destroy() } catch { /* noop */ }
if (failed.length === 0) {
  try { fs.rmSync(sandboxHome, { recursive: true, force: true }) } catch { /* noop */ }
}
process.exit(failed.length === 0 ? 0 : 1)
