/**
 * single-shot-no-plans.mjs —— ★★ 单发兜底的「**无计划**」回环联测（2026-10-24 ✓✓）
 *
 * 它钉住主人这次点名的改动 ✗✓（原话：「去掉吧，是旧的那套 JOB 之前直接扫区域，
 * 而非你去决策扫是吧」）：
 *
 *   ① 单发那一轮**一个 legacy 计划都不许查** ✗
 *      （tradePlan|minePlan|salvagePlan|sellPlan|scoutPlan|jobPlan|dossier）——
 *      它们全在游戏**主循环里同步**扫 67~71 个区域并自排序 ✓
 *      （真机 rpc_trace 2026-10-24 01:35：jobPlan 828/884 ms、scoutPlan 1321 ms、
 *       sellPlan 8248 ms、tradePlan 12633~15415 ms ✓）。
 *   ② **不许替她派船** ✗ —— 旧的「护航 rendezvous」会自动给战斗舰下 Travel 单；
 *      它只靠 legacy tradePlan 判"缺护航"，已随预取一并移除 ✓（触发块见 index.ts）。
 *   ③ 模型收到的档案必须**明说**「无计划（已移除预扫描）」✓ ——
 *      沉默会被读成"那里没有候选" ✗✓（那是本仓库踩过的血案 ✓）。
 *   ④ 名单仍是**原子事实** ✓：舰队名单里的护航候选照旧送达 ✓（一次 roster 读、不扫区域 ✓）。
 *   ⑤ 没有计划也能给 None ✓✓（这就是这次改动的前提 ✓）。
 *
 * 本文件的前身是 `rendezvous-flow.mjs`（自动派护航的回环联测 ✓）——
 * rendezvous 的**触发**随 legacy tradePlan 预取一起移除后，那条回环已不存在 ✓，
 * 所以同一套假游戏脚手架改成钉**新的不变量** ✓。
 * （`escortNeedOf` / `pickRendezvousEscort` 两个纯函数仍在 ✓，`test/rendezvous.mjs` 仍钉它们 ✓。）
 *
 * 跑法：node test/single-shot-no-plans.mjs
 *
 * ⚠️ 只用 127.0.0.1 + 高位端口（18799），跑完立刻关掉 ✓；不碰游戏那个 8765 端口 ✓。
 * ⚠️ 日志（live / decisions）会写到**临时目录** ✓ —— 绝不污染主人真实的那几份日志 ✓：
 *    插件在 import 时就用 os.homedir() 算好日志路径，所以下面**先**改 USERPROFILE 再 import ✓
 *    （Windows 上 os.homedir() 认的就是 USERPROFILE ✓）。
 */
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import net from 'node:net'
import { registerHooks } from 'node:module'

registerHooks({
  resolve(specifier, context, next) {
    if (specifier === '@deepseek-ai/dsh-llm') {
      return { url: new URL('./llm-stub.mjs', import.meta.url).href, shortCircuit: true }
    }
    if (specifier === '@deepseek-ai/dsh-tools') {
      return { url: new URL('./tools-stub.mjs', import.meta.url).href, shortCircuit: true }
    }
    return next(specifier, context)
  },
})

const sandboxHome = fs.mkdtempSync(path.join(os.tmpdir(), 'copilot-noplans-home-'))
process.env.USERPROFILE = sandboxHome
process.env.HOMEDRIVE = ''
process.env.HOMEPATH = ''

const { apply } = await import('../lib/index.js')

const PORT = 18799
const ACTION_SHIP = 'Trader-00001'
const TARGET_SECTOR = { x: -399, y: 81 }
/** 旧版每次自动预取的那几个（一个都不许再出现 ✓） */
const LEGACY_PLANS = ['tradePlan', 'minePlan', 'salvagePlan', 'sellPlan', 'scoutPlan', 'jobPlan', 'dossier']

// ---------------------------------------------------------------------------
// 假游戏：按 what 回数据；把 query 与 order **逐条记下来** ✓
//   ★ 计划一律回空载荷 —— 走不到那里才对 ✓（走到了就会被 queries 记下来 ✗）
// ---------------------------------------------------------------------------

const game = {
  goal: { text: '在附近跑贸易赚钱，优先低风险的短途路线', options: ['Trade'], hasGoal: true },
  shipCard: {
    name: ACTION_SHIP, sector: { ...TARGET_SECTOR }, busy: false, hasCaptain: true,
    captainClass: 'Merchant', turretCount: 1, freeCargoSpace: 3393,
    cargoUsed: 100, cargoCapacity: 5000, holdHasGoods: true,
    actionNames: ['Mine', 'Salvage', 'Trade', 'Travel', 'Sell', 'Scout'],
    hyperspace: { reach: 12, canPassRifts: true },
  },
  fleet: {
    designated: 4,
    piloted: 'Player-00001',
    ships: [
      { name: ACTION_SHIP, sector: { ...TARGET_SECTOR }, busy: false, hasCaptain: true, turretCount: 1 },
      { name: 'Scout-00001', sector: { x: -395, y: 70 }, busy: false, hasCaptain: true, turretCount: 1 },
      // ★ 隔壁星区、一跳之内 → 原版判据下就是**合法护航候选** ✓（名单要送达 ✓）
      {
        name: 'Combat-00001', sector: { x: -391, y: 77 }, busy: false, hasCaptain: true,
        turretCount: 8, hyperspace: { reach: 12, canPassRifts: true },
      },
      { name: 'Miner-00001', sector: { x: -400, y: 90 }, busy: true, hasCaptain: true, turretCount: 6 },
      { name: 'Player-00001', sector: { x: -300, y: 20 }, busy: false, hasCaptain: true, turretCount: 12 },
    ],
  },
  queries: [],
  orders: [],
}

function reply(cmd, data) {
  if (cmd === 'hello') return { side: 'game', ver: 2, caps: ['query', 'order', 'recall', 'reload'] }
  if (cmd === 'order') {
    game.orders.push(data)
    return { accepted: true, executed: true, ...data, note: 'stub: queued startCommand' }
  }
  if (cmd !== 'query') return {}
  const what = data?.what
  game.queries.push(String(what))
  if (what === 'goal') return game.goal
  if (what === 'ship') return game.shipCard
  if (what === 'fleet') return game.fleet
  // ★ 计划：**回空载荷** ✓（真跑到了也不会崩，而且 queries 里已经记下它 ✗）
  return {}
}

function encode(msg) {
  const body = Buffer.from(JSON.stringify(msg), 'utf8')
  const head = Buffer.alloc(4)
  head.writeUInt32LE(body.length, 0)
  return Buffer.concat([head, body])
}

// ---------------------------------------------------------------------------
// 起插件（假 ctx）→ 连上去 → 当"游戏"发 decide ✓
// ---------------------------------------------------------------------------

const disposers = []
let modelCalls = 0
const seenPrompts = []

const ctx = {
  logger: { info: () => {}, warn: (m) => console.log(`   [plugin warn] ${m}`) },
  effect(fn) {
    const d = fn()
    if (typeof d === 'function') disposers.push(d)
  },
  tools: { register: () => {} },
  llm: {
    async *stream(options) {
      modelCalls += 1
      // ★ 把该次调用的**全部**消息拼起来收 ✓（单发档案 + 记忆块可能分成多条 ✓）
      seenPrompts.push(
        (options.messages ?? [])
          .map((m) => (m.content?.[0]?.text ?? ''))
          .join('\n'),
      )
      yield { type: 'reasoning-delta', index: 0, text: '（假模型）没有计划框心，不编。' }
      yield { type: 'text-delta', index: 1, text: 'action=None\nreason=本次没有计划数据，不凭空编框心 ✓\n' }
      yield { type: 'finish', reason: { kind: 'stop' } }
    },
  },
}

await apply(ctx, { port: PORT })

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
if (sock === null) {
  console.log('✗ 连不上插件的回环端口 —— 测试无法进行')
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
      // DSH 调游戏（query / order）→ 立刻回 ✓
      sock.write(encode({ id: msg.id, type: 'response', cmd: msg.cmd, ok: true, data: reply(msg.cmd, msg.data) }))
    } else if (msg.type === 'response') {
      const p = pending.get(msg.id)
      if (p !== undefined) {
        pending.delete(msg.id)
        p(msg)
      }
    }
  }
})

function call(cmd, data, timeoutMs = 20000) {
  const id = ++nextId
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      pending.delete(id)
      reject(new Error(`timeout waiting for ${cmd}`))
    }, timeoutMs)
    pending.set(id, (msg) => {
      clearTimeout(timer)
      resolve(msg)
    })
    sock.write(encode({ id, type: 'request', cmd, data }))
  })
}

const checks = []
function check(label, cond, actual) {
  checks.push({ label, pass: cond === true, actual })
}

try {
  // 握手会先来一次 fleet 快照（onConnected ✓）—— 等它落账后再记 qBefore ✓
  await new Promise((r) => setTimeout(r, 150))
  const qBefore = game.queries.length
  const r1 = await call('decide', { ship: ACTION_SHIP, hasGoal: true })
  const qDuring = game.queries.slice(qBefore)
  const legacy = qDuring.filter((w) => LEGACY_PLANS.includes(w))
  const prompt = seenPrompts.join('\n')

  console.log(`\n单发 decide 期间的 query: ${qDuring.join(', ') || '(空)'}`)
  console.log(`模型收到的档案 ${prompt.length} 字；下单 ${game.orders.length} 张`)

  check('① decide 成功', r1.ok === true, r1)
  check('① ★ 没有查任何 legacy 计划（扫 67~71 区的那批 ✗）',
    legacy.length === 0, legacy.join(','))
  check('① ★ 只拉轻量原子事实（goal + ship + fleet ✓，别的都不要 ✓）',
    qDuring.length > 0 && qDuring.every((w) => w === 'goal' || w === 'ship' || w === 'fleet'), qDuring.join(','))
  check('① 船卡与舰队名单都取到了 ✓',
    qDuring.includes('ship') && qDuring.includes('fleet'), qDuring.join(','))
  check('② ★ 没有替她派船（旧自动护航已移除 ✗）',
    game.orders.length === 0, JSON.stringify(game.orders))
  check('③ ★ 档案**明说**「无计划（已移除预扫描）」✓',
    prompt.includes('无计划（已移除预扫描）'), prompt.slice(0, 300))
  check('③ 档案里没有旧 tradePlan 的候选表 ✗',
    !/★★ Trade/.test(prompt) && !/候选框（共 \d+ 个/.test(prompt), '')
  check('④ ★ 名单仍送达（护航候选里有 Combat-00001 ✓）',
    /护航候选[^\n]*Combat-00001/.test(prompt), prompt.slice(0, 800))
  check('⑤ ★ 没有计划也能给 None ✓（而且问过模型 ✓）',
    r1.data?.action === 'None' && modelCalls === 1, `${String(r1.data?.action)} calls=${modelCalls}`)
} catch (error) {
  check(`回环流程抛错：${String(error)}`, false, String(error))
}

// ---------------------------------------------------------------------------

let failed = 0
for (const c of checks) {
  if (!c.pass) failed++
  console.log(`${c.pass ? '  ✓' : '  ✗'} ${c.label}` + (c.pass ? '' : `   ← 实际 ${JSON.stringify(c.actual)}`))
}
console.log(`\n${checks.length - failed}/${checks.length} 通过`)

for (const d of disposers) d()
sock.destroy()
if (failed === 0) {
  fs.rmSync(sandboxHome, { recursive: true, force: true })
} else {
  console.log(`\n（有失败项 → 插件日志留在临时目录供排查：${sandboxHome}）`)
}
process.exit(failed === 0 ? 0 : 1)
