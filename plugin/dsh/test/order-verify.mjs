/**
 * order-verify.mjs —— 「回执带预检 + 实测」插件侧自检 ✓ 2026-10-17
 *
 * 主人原话（这一轮的唯一需求）：
 *   「你下的指令似乎你都不知道是有没有正常执行啊，回执没法带结果吗？」
 *
 * 本文件**驱动真代码**（lib/ 的 apply → 注册的 fleet_order / fleet_query 工具 → 真 RPC），
 * 假的东西只有两样：**游戏**（回放夹具）与**进程环境** ✓。
 *
 * 断言（任务书第 4 条 ✓）：
 *   a. fleet_order 回执**原样透传** preflight/verify ✓（游戏给什么就有什么 ✓）；
 *   b. 有 orderId 时插件会**再问一次** orderStatus（拿到真证据 ✓），
 *      并把「实测：…」渲染成人话 ✓（`已到 ✓` / `货舱 -1369 ✓` / `实测 ✗ …` ✓）；
 *   c. 预检不过 → **不说 ordered** ✗✓（输出以 `NOT ordered` 开头 + `预检 ✗ CODE`），
 *      而且**一次 orderStatus 都不问** ✓（没下单就没有实测 ✓）；
 *   d. renderPrevResult（"你上一单的结果"那行 ✓）：实测失败时**不许**写「成功」✗✓；
 *      预检失败时写「预检 ✗ CODE」✓。
 *
 * 跑法: node test/order-verify.mjs      （退出码 0 = 全过 ✓）
 */

import net from 'node:net'
import { registerHooks } from 'node:module'

// 离线跑：把 DSH 的两个包指到本地桩 ✓（与兄弟测试同一套 ✓）
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

process.env.HOMEPATH = ''
process.env.USERPROFILE = process.env.TEMP ?? ''

const { apply, preflightText, verifyText, renderPrevResult } = await import('../lib/index.js')

const PORT = 18813 // ★ 与别的测试分开 ✓
const SHIP = 'Salvager-00001'
const HERE = { x: -381, y: 57 }

let failures = 0
let checks = 0
function check(name, ok, extra) {
  checks += 1
  if (ok) {
    console.log(`  PASS  ${name}`)
  } else {
    failures += 1
    console.log(`  FAIL  ${name}   -> ${typeof extra === 'string' ? extra : JSON.stringify(extra)}`)
  }
}

// ---------------------------------------------------------------------------
// 假游戏：order 回执 / orderStatus 轮询都记下来 ✓
// ---------------------------------------------------------------------------

const game = {
  orderStatusCalls: 0,
  /** pending 次数：前 N 次 orderStatus 回 pending（证明插件真的在**轮询** ✓） */
  pendingTimes: 1,
  /** 下一次 order 的回执（测试逐段改它 ✓） */
  nextOrder: null,
  queries: [],
}

function finalVerify() {
  return {
    at: '2026-10-17T23:59:00Z',
    started: true,
    startCommandQueued: true,
    ok: true,
    evidence: 'cargoUsedDecreased',
    busy: false,
    position: { ...HERE },
    positionBefore: { ...HERE },
    moved: false,
    cargoUsed: 1520,
    cargoUsedBefore: 2889,
    cargoUsedDelta: -1369,
    cargoKinds: 23,
    cargoKindsBefore: 24,
    holdHasGoods: true,
  }
}

function reply(cmd, data) {
  if (cmd === 'hello') return { side: 'game', ver: 2, caps: ['query', 'order', 'recall', 'reload'] }
  if (cmd === 'order') {
    return game.nextOrder ?? {
      accepted: true, executed: true,
      ship: data.ship, action: data.action, orderId: 7,
      preflight: {
        ok: true,
        checks: [{ name: 'SHIP_STATE', ok: true }, { name: 'MIN_DISTANCE', ok: true }],
        warnings: [],
      },
      verify: { pending: true, etaSeconds: 1 },
      note: 'area analysis started; startCommand is queued ~6s later',
    }
  }
  if (cmd !== 'query') return {}
  const what = data?.what
  game.queries.push(String(what))
  if (what === 'list') return { ships: [] }
  if (what === 'fleet') return { ships: [] }
  if (what === 'goal') return { ship: data?.ship, text: '', hasGoal: false, options: [] }
  if (what === 'orderStatus') {
    game.orderStatusCalls += 1
    if (game.orderStatusCalls <= game.pendingTimes) {
      return {
        orderId: data?.orderId, ship: data?.ship, action: 'Sell', accepted: true,
        started: false,
        verify: { pending: true, etaSeconds: 0.2, note: 'sample not due' },
      }
    }
    return {
      orderId: data?.orderId, ship: data?.ship, action: 'Sell', accepted: true,
      started: true, startCommandQueued: true,
      verify: finalVerify(),
    }
  }
  return {}
}

function encode(msg) {
  const body = Buffer.from(JSON.stringify(msg), 'utf8')
  const head = Buffer.alloc(4)
  head.writeUInt32LE(body.length, 0)
  return Buffer.concat([head, body])
}

// ---------------------------------------------------------------------------
// 起插件（假 ctx，**接住工具定义** ✓）+ 假的游戏对端 ✓
// ---------------------------------------------------------------------------

const disposers = []
const tools = new Map()

const ctx = {
  logger: { info: () => {}, warn: (m) => console.log(`   [plugin warn] ${m}`) },
  effect(fn) {
    const d = fn()
    if (typeof d === 'function') disposers.push(d)
  },
  tools: {
    register(tool) {
      tools.set(tool.name, tool)
    },
  },
  llm: {
    async *stream() {
      yield { type: 'text-delta', index: 1, text: '（假模型）不做决策' }
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
    }
  }
})

const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
await sleep(200)

const orderTool = tools.get('fleet_order')
const queryTool = tools.get('fleet_query')
check('① 插件注册了 fleet_order ✓', orderTool !== undefined, 'missing')
check('① 插件注册了 fleet_query ✓', queryTool !== undefined, 'missing')

// ---------------------------------------------------------------------------
// A：有 orderId → 插件**再问** orderStatus（轮询到定稿 ✓）+ 渲染人话 ✓
// ---------------------------------------------------------------------------
console.log('== A: fleet_order 透传 preflight + 轮询实测 ✓ ==')
game.orderStatusCalls = 0
game.pendingTimes = 1
game.queries = []
const outA = await orderTool.execute({ ship: SHIP, action: 'Sell', x: HERE.x, y: HERE.y, size: 15 })
check('A 输出以 ordered 开头（预检通过 ✓）', outA.startsWith(`ordered: ${SHIP} -> Sell`), outA.slice(0, 80))
check('A ★ 输出里有「实测：」人话 ✓', outA.includes('实测：'), outA.slice(0, 400))
check('A ★ 实测人话 = 货舱 -1369 ✓', outA.includes('货舱 -1369 ✓'), outA.slice(0, 400))
check('A ★ 回执 JSON 里 verify.ok=true ✓', outA.includes('"ok": true') && outA.includes('"verify"'), outA.slice(-600))
check('A ★ 回执 JSON 里 verify.cargoUsedDelta=-1369 ✓', outA.includes('"cargoUsedDelta": -1369'), '')
check('A ★ 回执 JSON 里 preflight 原样透传 ✓', outA.includes('"preflight"') && outA.includes('"MIN_DISTANCE"'), '')
check('A ★ 插件轮询了 orderStatus（pending 一次后拿到定稿 ✓）', game.orderStatusCalls >= 2, game.orderStatusCalls)

// ---------------------------------------------------------------------------
// B：预检不过 → **不是** ordered ✓ + 一次 orderStatus 都不问 ✓
// ---------------------------------------------------------------------------
console.log('== B: 预检不过 → NOT ordered（且不问实测 ✓）==')
game.orderStatusCalls = 0
game.queries = []
game.nextOrder = {
  accepted: false,
  executed: false,
  orderId: undefined,
  ship: SHIP,
  action: 'Travel',
  preflight: {
    ok: false,
    code: 'MIN_DISTANCE',
    reason: "the destination is reachable in ONE jump (jump route = 2 sectors, so hops = 1) — vanilla TravelCommand:initialize refuses it: 'This route is too short.' (travelcommand.lua:75-77)",
    detail: 'travelcommand.lua:75-77',
    checks: [{ name: 'MIN_DISTANCE', ok: false }],
  },
  error: 'MIN_DISTANCE: This route is too short.',
  note: 'This route is too short.',
}
const outB = await orderTool.execute({ ship: SHIP, action: 'Travel', x: -374, y: 64 })
check('B ★ 输出以 NOT ordered 开头 ✓（不许说下单了 ✗）', outB.startsWith(`NOT ordered: ${SHIP} -> Travel`), outB.slice(0, 120))
check('B ★ 输出里有「预检 ✗ MIN_DISTANCE」✓', outB.includes('预检 ✗ MIN_DISTANCE'), outB.slice(0, 300))
check('B ★ 输出里有「没有下单」✓', outB.includes('没有下单'), '')
check('B ★ 一次 orderStatus 都没问 ✓（没下单就没有实测 ✓）', game.orderStatusCalls === 0, game.orderStatusCalls)
game.nextOrder = null

// ---------------------------------------------------------------------------
// C：fleet_query what=orderStatus 也能直接取实测 ✓
// ---------------------------------------------------------------------------
console.log('== C: fleet_query{what:orderStatus} 取实测 ✓ ==')
game.orderStatusCalls = 0
game.pendingTimes = 0 // 直接给定稿 ✓（这里验的是"能取到"，不是轮询 ✓）
const outC = await queryTool.execute({ what: 'orderStatus', orderId: 7 })
check('C 输出里带 verify ✓', outC.includes('"verify"'), outC.slice(0, 200))
check('C 输出里带 evidence ✓', outC.includes('cargoUsedDecreased'), outC.slice(0, 400))

// ---------------------------------------------------------------------------
// D：渲染函数（人话口径 ✓）
// ---------------------------------------------------------------------------
console.log('== D: 渲染口径 ✓ ==')
check('D preflightText：ok=false → 「预检 ✗ CODE」✓',
  (preflightText({ ok: false, code: 'MIN_DISTANCE', reason: 'x' }) ?? '').includes('预检 ✗ MIN_DISTANCE'), '')
check('D preflightText：ok=true → undefined（成功不废话 ✓）',
  preflightText({ ok: true }) === undefined, '')
check('D verifyText：pending → 「实测待回」✓',
  (verifyText({ pending: true, etaSeconds: 8 }) ?? '').includes('实测待回（~8s 后）'), verifyText({ pending: true, etaSeconds: 8 }))
check('D verifyText：atDestination → 「已到 ✓」✓',
  verifyText({ ok: true, evidence: 'atDestination' }) === '已到 ✓', verifyText({ ok: true, evidence: 'atDestination' }))
check('D verifyText：busy（Sell）→ 「在跑 ✓（货舱要跑完才结算）」✓',
  (verifyText({ ok: true, evidence: 'busy', note: '货舱要等命令跑完才结算' }) ?? '').includes('在跑 ✓'), '')
check('D verifyText：ok=false → 「实测 ✗ —— 理由」✓',
  (verifyText({ ok: false, reason: '货舱没少、也不在后台运行（busy=false）' }) ?? '').startsWith('实测 ✗'), '')
const recFail = renderPrevResult({
  at: '2026-10-17T00:00:00Z',
  ship: SHIP,
  goalText: '',
  goalOptions: [],
  ok: true,
  source: 'session',
  answer: { action: 'Sell', params: { x: 1, y: 2 } },
  receipt: {
    at: '2026-10-17T00:00:00Z',
    accepted: true,
    executed: true,
    verify: { ok: false, reason: '货舱没少、也不在后台运行（busy=false）' },
  },
})
check('D renderPrevResult：实测失败**不许**写「成功」✗✓', !recFail.includes('成功'), recFail)
check('D renderPrevResult：实测失败写「下单 ✓｜实测 ✗」✓',
  recFail.includes('下单 ✓') && recFail.includes('实测 ✗'), recFail)
const recPf = renderPrevResult({
  at: '2026-10-17T00:00:00Z',
  ship: SHIP,
  goalText: '',
  goalOptions: [],
  ok: false,
  source: 'session',
  answer: { action: 'Travel', params: { x: 1, y: 2 } },
  receipt: {
    at: '2026-10-17T00:00:00Z',
    accepted: false,
    executed: false,
    preflight: { ok: false, code: 'MIN_DISTANCE', reason: 'This route is too short.' },
  },
})
check('D renderPrevResult：预检失败 → 「预检 ✗ MIN_DISTANCE」✓', recPf.includes('预检 ✗ MIN_DISTANCE'), recPf)

// ---------------------------------------------------------------------------
for (const d of disposers) {
  try { d() } catch { /* ignore */ }
}
sock.destroy()

console.log(`== 共 ${checks} 项断言，失败 ${failures} 项 ==`)
if (failures === 0) {
  console.log('orderVerifySelfTest: OK')
  process.exit(0)
} else {
  console.log('orderVerifySelfTest: FAILED')
  process.exit(1)
}
