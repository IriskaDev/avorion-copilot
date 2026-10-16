/**
 * ★ 运行时端到端：**决策 → toAnswer → 发出去的 order 载荷** ✓✓
 *
 * 为什么要有它（2026-10-17，pro 审查指出的缺口 ✓）：
 *   `actions-consistency.mjs` 是**静态**的 —— 它只证明「提示词广告的动作集 == ALL_ACTIONS ==
 *   游戏侧 COMMAND_TYPES」三份清单一致 ✓，但**没有**证明某条决策真的能**走完下单路径** ✗。
 *   而现实里恰恰栽过：`Scout` / `Sell` 在三份清单里都有 ✓，却不在解析器/白名单里 ✗
 *   → 端到端根本发不出去 ✓✓（是 pro 审查读源码才发现的 ✓）。
 *
 * 所以这个文件**驱动真代码**（lib/index.js 的 apply → decide → 真解析 → 真下单）✓，
 * 假的东西只有三样：LLM 的回复 ✓、游戏的 RPC 对端 ✓、进程环境 ✓。
 * 断言点就是**假游戏收到的 order 载荷** ✓✓（= 插件真正发给游戏的东西 ✓）。
 *
 * 用例（对应任务要求 a–e ✓）:
 *   a. action=Scout            → 载荷带 action=Scout + 绝对坐标 ✓
 *   b. action=Sell             → 载荷带 action=Sell + 绝对坐标 ✓
 *   c. Trade + goodName+deposit → 载荷带 goodName 与 **deposit** ✓
 *   d. Mine + 合法护航          → 载荷带该护航 ✓；★ 非法名字必须**被丢掉** ✓
 *   e. goalOptions 限制         → 圈外的动作**被拒** ✓，圈内的**放行** ✓
 *
 * 跑法: node test/order-payload.mjs      （退出码 0 = 全过 ✓）
 */

import net from 'node:net'
import { registerHooks } from 'node:module'

// 本测试**离线**跑：DSH 的两个包在 npm 里解析不了（缺 @deepseek-ai/cordis ✗），
// 所以按兄弟测试的路子把它们指到本地桩 ✓（不新增任何依赖 ✓）。
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

// 让插件把日志写到临时位置，别碰真实玩家目录 ✓
process.env.HOMEPATH = ''
process.env.USERPROFILE = process.env.TEMP ?? ''

const { apply } = await import('../lib/index.js')

const PORT = 18811 // ★ 与 rendezvous-flow 的 18799 分开，免得并行跑冲突 ✓
const SHIP = 'Miner-00001'
const ESCORT = 'Combat-00001'
const HERE = { x: -399, y: 81 }

// ---------------------------------------------------------------------------
// 假游戏：按 what 回夹具，并把 order **原样记下来** ✓✓
// ---------------------------------------------------------------------------

function area(offset) {
  return { lower: { x: HERE.x + offset.x - 7, y: HERE.y + offset.y - 7 }, upper: { x: HERE.x + offset.x + 7, y: HERE.y + offset.y + 7 }, offset }
}

/** Mine 的计划：候选里**含船**、有一个达标档、并给出护航候选 ✓ */
function minePlan() {
  return {
    ship: SHIP,
    action: 'Mine',
    area: area({ x: 0, y: 0 }),
    size: 15,
    recommendation: {
      tag: 'default', duration: 1, safeMode: false, escorts: [],
      attackChance: 0.06, acceptable: true, valueLow: 12000, valueHigh: 15000,
      topTier: 2, topMaterial: 'Titanium',
    },
    riskWarning: null,
    areasScanned: 1,
    scanMs: 90,
    orderHint: { ship: SHIP, action: 'Mine', x: HERE.x, y: HERE.y, size: 15, duration: 1, safeMode: false, escorts: [] },
    areaRanking: [{
      area: area({ x: 0, y: 0 }), bestTag: 'default', valueLow: 12000, valueHigh: 15000,
      attackChance: 0.06, acceptable: true, duration: 1, safeMode: false, escorts: [],
    }],
    note: 'stub',
  }
}

/** Trade 的计划：带上原版算好的最优预付金 deposit ✓（用例 c 要断言它传下去 ✓） */
function tradePlan() {
  return {
    ship: SHIP,
    recommendation: {
      goodName: 'Antigrav Unit', x: HERE.x, y: HERE.y, deposit: 752000,
      attackChance: 0.07, attackChanceBase: 0.07, acceptable: true, netProfitLow: 761638,
    },
    riskWarning: null,
    areasScanned: 1,
    scanMs: 120,
    orderHint: { x: HERE.x, y: HERE.y, goodName: 'Antigrav Unit', deposit: 752000, escorts: [] },
  }
}

const game = {
  goal: { text: '在附近挖矿', options: [], hasGoal: true },
  shipCard: {
    name: SHIP,
    sector: { ...HERE },
    busy: false,
    hasCaptain: true,
    captainClass: 'Miner',
    turretCount: 6,
    freeCargoSpace: 0,
    // ★ 动作清单里**必须**有 Scout/Sell（这两条正是白名单栽过的地方 ✓✓）
    actionNames: ['Mine', 'Salvage', 'Trade', 'Travel', 'Sell', 'Scout'],
    // ★ 护航可用性判据用原版的"一跳航程" ✓（插件侧据此算候选 ✓）
    hyperspace: { reach: 12, canPassRifts: true },
    cargoState: 'full',
    holdHasGoods: false,
  },
  fleet: {
    designated: 2,
    piloted: 'Player-00001',
    ships: [
      { name: SHIP, sector: { ...HERE }, busy: false, hasCaptain: true, turretCount: 6 },
      // ★ 在**隔壁星区**（不是同星区 ✗）→ 走的是**原版"一跳航程"**那条分支 ✓✓
      //   ⚠️ 陷阱（本鱼踩过 ✓）：`hyperspace` 必须写在这条 **fleet 条目自己**身上 ✗ ——
      //     写在船卡上没用 ✓（index.ts:986 读的是 `s.hyperspace` ✓）。
      //     漏了它 → reach=undefined → 这艘船落进"保守未收" ✗ → 候选为空 ✓
      //     → 清洗会把**合法**的护航名也丢掉 ✗（本鱼第一次跑就是这么误报的 ✗✓）。
      {
        name: ESCORT, sector: { x: HERE.x + 1, y: HERE.y }, busy: false, hasCaptain: true,
        turretCount: 8, hyperspace: { reach: 12, canPassRifts: true },
      },
    ],
  },
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
  if (what === 'goal') return game.goal
  if (what === 'ship') return game.shipCard
  if (what === 'fleet') return game.fleet
  if (what === 'minePlan' || what === 'jobPlan') return minePlan()
  if (what === 'tradePlan') return tradePlan()
  if (what === 'sellPlan' || what === 'salvagePlan' || what === 'scoutPlan') return {}
  return {}
}

// 分帧协议：4 字节小端长度 + JSON ✓（与 PROTOCOL.md 一致 ✓，抄自 rendezvous-flow ✓）
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
let modelReply = ''

const ctx = {
  logger: { info: () => {}, warn: (m) => console.log(`   [plugin warn] ${m}`) },
  effect(fn) {
    const d = fn()
    if (typeof d === 'function') disposers.push(d)
  },
  tools: { register: () => {} },
  llm: {
    async *stream() {
      modelCalls += 1
      yield { type: 'reasoning-delta', index: 0, text: '（假模型）' }
      yield { type: 'text-delta', index: 1, text: modelReply }
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
function show(payload) {
  return JSON.stringify(payload)
}

/** 跑一轮 decide，返回 { rpc, order }（order = 新产生的那张单 ✓，没有则 null ✓） */
async function decideOnce(replyText, goalOptions) {
  modelReply = replyText
  game.goal = { ...game.goal, options: goalOptions ?? [] }
  const before = game.orders.length
  const r = await call('decide', { ship: SHIP, hasGoal: true })
  const order = game.orders.length > before ? game.orders[game.orders.length - 1] : null
  return { rpc: r, order }
}

try {
  // ---- a. action=Scout --------------------------------------------------------
  {
    const { rpc, order } = await decideOnce(`action=Scout\nx=${HERE.x}\ny=${HERE.y}\nreason=开图\n`)
    console.log(`\n[a] order 载荷: ${show(order)}`)
    check('a. Scout: decide 成功', rpc.ok === true, rpc)
    check('a. Scout: 真下了一张单', order !== null, game.orders.length)
    check('a. Scout: 载荷 action=Scout', order?.action === 'Scout', order?.action)
    check('a. Scout: 载荷带绝对坐标',
      order?.x === HERE.x && order?.y === HERE.y, `${order?.x},${order?.y}`)
    check('a. Scout: 载荷带船名', order?.ship === SHIP, order?.ship)
  }

  // ---- b. action=Sell --------------------------------------------------------
  {
    const { rpc, order } = await decideOnce(`action=Sell\nx=${HERE.x}\ny=${HERE.y}\nreason=卖货\n`)
    console.log(`\n[b] order 载荷: ${show(order)}`)
    check('b. Sell: decide 成功', rpc.ok === true, rpc)
    check('b. Sell: 真下了一张单', order !== null, game.orders.length)
    check('b. Sell: 载荷 action=Sell', order?.action === 'Sell', order?.action)
    check('b. Sell: 载荷带绝对坐标',
      order?.x === HERE.x && order?.y === HERE.y, `${order?.x},${order?.y}`)
  }

  // ---- b2. Sell + goodsToSell（2026-10-17 主人截图实证 ✓✓：原版窗口是**逐货勾选** ✓，
  //          **不勾货命令就起不来** ✗ → 我们必须能把选货透传下去 ✓）------------------
  {
    const { rpc, order } = await decideOnce(`action=Sell\ngoodsToSell=小麦:100,原油:120\nx=${HERE.x}\ny=${HERE.y}\nreason=卖一部分\n`)
    console.log(`\n[b2] order 载荷: ${show(order)}`)
    check('b2. Sell+选货: decide 成功', rpc.ok === true, rpc)
    check('b2. Sell+选货: ★ 载荷带 goodsToSell ✓✓',
      Array.isArray(order?.goodsToSell) && order.goodsToSell.length === 2, JSON.stringify(order?.goodsToSell))
    check('b2. Sell+选货: 货名/数量解析正确',
      order?.goodsToSell?.[0]?.goodName === '小麦' && order?.goodsToSell?.[0]?.amount === 100
      && order?.goodsToSell?.[1]?.goodName === '原油' && order?.goodsToSell?.[1]?.amount === 120,
      JSON.stringify(order?.goodsToSell))
  }

  // ---- b3. Sell + goodsToSell=all（★ 不该把这个**字符串**回传 ✗ ——
  //          游戏侧"没给 goodsToSell"本来就是**默认全卖** ✓，给字符串反被它按表判空 ✗）----
  {
    const { rpc, order } = await decideOnce(`action=Sell\ngoodsToSell=all\nx=${HERE.x}\ny=${HERE.y}\n`)
    console.log(`\n[b3] order 载荷: ${show(order)}`)
    check('b3. Sell=all: decide 成功', rpc.ok === true, rpc)
    check('b3. Sell=all: ★ 不回传字符串（交给游戏侧的"默认全卖" ✓）',
      order !== null && order.goodsToSell === undefined, JSON.stringify(order?.goodsToSell))
  }

  // ---- c. Trade + goodName + deposit -----------------------------------------
  {
    const { rpc, order } = await decideOnce(`action=Trade\ngoodName=Antigrav Unit\nx=${HERE.x}\ny=${HERE.y}\ndeposit=752000\nreason=跑货\n`)
    console.log(`\n[c] order 载荷: ${show(order)}`)
    check('c. Trade: decide 成功', rpc.ok === true, rpc)
    check('c. Trade: 载荷 action=Trade', order?.action === 'Trade', order?.action)
    check('c. Trade: 载荷带 goodName', order?.goodName === 'Antigrav Unit', order?.goodName)
    check('c. Trade: ★ 载荷带 deposit（此前完全没透传 ✗）',
      order?.deposit === 752000, order?.deposit)
    check('c. Trade: 载荷带绝对坐标',
      order?.x === HERE.x && order?.y === HERE.y, `${order?.x},${order?.y}`)
  }

  // ---- d. Mine + 护航（合法保留 / 非法丢掉 ✓）--------------------------------
  {
    const { rpc, order } = await decideOnce(`action=Mine\nx=${HERE.x}\ny=${HERE.y}\nduration=1\nescorts=${ESCORT}\nreason=挖矿\n`)
    console.log(`\n[d1] order 载荷: ${show(order)}`)
    check('d1. Mine: decide 成功', rpc.ok === true, rpc)
    check('d1. Mine: 载荷 action=Mine', order?.action === 'Mine', order?.action)
    check('d1. Mine: 合法护航被保留',
      JSON.stringify(order?.escorts) === JSON.stringify([ESCORT]), order?.escorts)
  }
  {
    const { rpc, order } = await decideOnce(`action=Mine\nx=${HERE.x}\ny=${HERE.y}\nduration=1\nescorts=Frankly-Not-A-Ship\nreason=挖矿\n`)
    console.log(`\n[d2] order 载荷: ${show(order)}`)
    check('d2. Mine: decide 成功', rpc.ok === true, rpc)
    check('d2. Mine: ★ 非法护航名被丢掉（不清洗就会把垃圾发下去 ✗）',
      order !== null && (order.escorts === undefined || order.escorts.length === 0), order?.escorts)
  }

  // ---- e. goalOptions 限制（圈外拒绝 / 圈内放行 ✓）---------------------------
  {
    const { rpc, order } = await decideOnce(`action=Scout\nx=${HERE.x}\ny=${HERE.y}\nreason=开图\n`, ['Mine'])
    console.log(`\n[e1] 目标只允许 Mine，模型答 Scout → order: ${show(order)}  rpc: ${JSON.stringify(rpc.data ?? rpc)}`)
    check('e1. 目标只允许 Mine 时，Scout **被拒**（不下单）', order === null, order)
  }
  {
    const { rpc, order } = await decideOnce(`action=Mine\nx=${HERE.x}\ny=${HERE.y}\nduration=1\nreason=挖矿\n`, ['Mine'])
    console.log(`\n[e2] 目标只允许 Mine，模型答 Mine → order: ${show(order)}`)
    check('e2. 目标只允许 Mine 时，Mine **放行**', order !== null && order?.action === 'Mine', order?.action)
    check('e2. Mine 放行的 rpc 也 ok', rpc.ok === true, rpc)
  }
} catch (err) {
  console.log(`\n✗ 测试抛异常: ${err?.stack ?? err}`)
  process.exit(1)
}

// ---------------------------------------------------------------------------
// 汇总 ✓（任何一项失败就**大声**失败 ✓，绝不静默通过 ✓）
// ---------------------------------------------------------------------------

const failed = checks.filter((c) => !c.pass)
console.log(`\n== 共 ${checks.length} 项断言，失败 ${failed.length} 项 ==`)
for (const f of failed) console.log(`  ✗ ${f.label}  → 实际: ${JSON.stringify(f.actual)}`)
console.log(failed.length === 0 ? 'orderPayloadSelfTest: OK' : 'orderPayloadSelfTest: FAILED')
for (const d of disposers) {
  try {
    d()
  } catch {
    /* 清理失败不影响结论 ✓ */
  }
}
try {
  sock.destroy()
} catch {
  /* 同上 ✓ */
}
process.exit(failed.length === 0 ? 0 : 1)
