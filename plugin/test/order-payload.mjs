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

/** Trade 计划：★ 带**多个候选框**（含两种合法形状 ✓）—— 用来验"并排画出来"的渲染 ✓ */
function tradePlan() {
  return {
    ship: SHIP,
    recommendation: {
      goodName: 'Antigrav Unit', x: HERE.x, y: HERE.y, deposit: 752000, sizeX: 17, sizeY: 17,
      attackChance: 0.07, attackChanceBase: 0.07, acceptable: true, netProfitLow: 761638,
    },
    riskWarning: null,
    areasScanned: 9,
    boxesEvaluated: 33,
    scanMs: 120,
    orderHint: { x: HERE.x, y: HERE.y, goodName: 'Antigrav Unit', deposit: 752000, sizeX: 17, sizeY: 17, escorts: [] },
    // ★★ 形状与游戏侧一致：候选框在 **areaRanking** 里 ✓（插件从它映射成喂模型的 areas ✓）
    areaRanking: [
      { area: area({ x: 0, y: 0 }), x: HERE.x, y: HERE.y, shape: '17x17', sizeX: 17, sizeY: 17,
        origin: 'coarse', bestRouteName: 'Antigrav Unit', attackChance: 0.07,
        netProfitLow: 761638, netProfitHigh: 800000, bestCaseLow: 900000, bestCaseHigh: 950000,
        flights: 2, deposit: 752000, acceptable: true },
      { area: area({ x: 4, y: 0 }), x: HERE.x + 4, y: HERE.y, shape: '29x11', sizeX: 29, sizeY: 11,
        origin: 'fine', bestRouteName: 'Wide Good', attackChance: 0.04,
        netProfitLow: 700000, netProfitHigh: 740000, bestCaseLow: 820000, bestCaseHigh: 860000,
        flights: 2, deposit: 700000, acceptable: true },
    ],
    candidates: [{ name: 'Antigrav Unit' }],
    moveHint: { listIsOptions: true, statement: '多个候选框、框可以平移、Trade 形状可变 ✓' },
  }
}

const game = {
  goal: { text: '在附近挖矿', options: [], hasGoal: true },  shipCard: {
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
  queries: [],
}

/**
 * ★★ Sell 计划（2026-10-17 加 ✓）：主人的要求 —— **逐货数字**（舱里多少 / 预计卖多少 / 涨跌幅 ±%）
 *   必须真的送到模型眼前 ✓✓；这里就是"送到模型眼前"的那条链的**消费端**证明 ✓：
 *   插件把它**原样**塞进 facts.sellPlan ✓ → buildPrompt 会 JSON 出来 ✓。
 *   ★ 形状与游戏侧 sellPlan 的返回一致（recommendation.perGood / perGoodBest / hold ✓）。
 */
function sellPlan() {
  return {
    ship: SHIP,
    action: 'Sell',
    goodsToSell: [
      { goodName: 'Drill', amount: 100, stolen: false },
      { goodName: 'Oxygen', amount: 50, stolen: false },
    ],
    holdUsed: 150,
    holdKinds: 2,
    hold: {
      used: 150, kinds: 2, capacity: 5000, free: 4850, usedPercent: 3,
      isHoldFull: false, holdHasGoods: true, blocksTradeLoading: false,
    },
    recommendation: {
      x: HERE.x, y: HERE.y, size: 15, action: 'Sell',
      attackChance: 0.05, riskKind: 'sellAmbushChance(whole task, this box)',
      netProfitLow: 90000, netProfitHigh: 95000, profitBasis: 'sellYield(riskAdjusted)',
      duration: 2000,
      perGood: [
        { goodName: 'Drill', amount: 100, expectedRevenue: 2500, priceDeltaPercent: 50,
          expectedUnitPrice: 25, normalRevenueEstimate: 1666.7 },
        { goodName: 'Oxygen', amount: 50, expectedRevenue: 3000, priceDeltaPercent: -20,
          expectedUnitPrice: 60, normalRevenueEstimate: 3750 },
      ],
    },
    perGoodBest: [
      { goodName: 'Drill', amount: 100, expectedRevenue: 2500, priceDeltaPercent: 50,
        offset: { x: -4, y: 0 }, origin: 'coarse' },
      { goodName: 'Oxygen', amount: 50, expectedRevenue: 3000, priceDeltaPercent: -20,
        offset: { x: 0, y: 0 }, origin: 'coarse' },
    ],
    perGoodByArea: [
      { offset: { x: 0, y: 0 }, origin: 'coarse', goods: [
        { goodName: 'Drill', amount: 100, expectedRevenue: 2000, priceDeltaPercent: 10 },
      ] },
    ],
    areaRanking: [
      { area: area({ x: 0, y: 0 }), x: HERE.x, y: HERE.y, origin: 'coarse', shape: '15x15',
        netProfitLow: 90000, attackChance: 0.05, acceptable: true,
        perGood: [{ goodName: 'Drill', amount: 100, expectedRevenue: 2000, priceDeltaPercent: 10 }] },
      { area: area({ x: -4, y: 0 }), x: HERE.x - 4, y: HERE.y, origin: 'fine', shape: '15x15',
        netProfitLow: 85000, attackChance: 0.02, acceptable: true,
        perGood: [{ goodName: 'Drill', amount: 100, expectedRevenue: 2500, priceDeltaPercent: 50 }] },
    ],
    areasScanned: 9, boxesEvaluated: 33, scanMs: 400,
    orderHint: { ship: SHIP, action: 'Sell', x: HERE.x, y: HERE.y, size: 15,
      goodsToSell: [{ goodName: 'Drill', amount: 100 }], duration: 2000 },
    moveHint: { listIsOptions: true, statement: '框可以平移 ✓（多个候选 ✓）' },
    riskWarning: null,
  }
}

/**
 * ★★ `query {what:"dossier"}` 的替身（2026-10-17 ✓✓）
 *
 * 单发那条路的提示词**不再**由插件自己拼（`buildPrompt`）✗ —— 它现在走**有界档案** ✓：
 * 插件先 `query {what:"dossier"}` 拿一份预取 + 裁剪的载荷 ✓，再由 `dossier.ts` 渲染 ✓。
 * ★ 这个替身必须**把计划原样带进去** ✓ —— 否则测试验的就不是"数字真的送到眼前" ✓了
 *   （那正是 f/h 两组断言要钉住的东西 ✓）。
 */
function dossierStub() {
  const plans = []
  plans.push({ ...tradePlan(), action: 'Trade', ship: SHIP })
  plans.push({ ...minePlan(), action: 'Mine', ship: SHIP })
  const sell = sellPlan()
  plans.push({
    ...sell, action: 'Sell', ship: SHIP,
    // ★★ 游戏侧 `trim=true` 会给每个候选补 `origin`（粗扫/细扫 ✓）—— 替身照做 ✓，
    //   否则测的就不是"这条路真的把 origin 送到眼前" ✓了。
    areaRanking: (sell.areaRanking ?? []).map((a) => ({ ...a, origin: a.origin ?? 'coarse' })),
  })
  return {
    what: 'dossier', ship: SHIP, gate: 0.1,
    goal: game.goal, card: game.shipCard, plans,
    planFetchFailures: [{ what: 'salvagePlan', why: 'stub: 空载荷' }],
    note: '★ 这是有界档案 ✓（每个计划只回前几个候选、逐框只有标量 ✓）',
  }
}

function reply(cmd, data) {
  if (cmd === 'hello') return { side: 'game', ver: 2, caps: ['query', 'order', 'recall', 'reload'] }
  if (cmd === 'order') {
    game.orders.push(data)
    return { accepted: true, executed: true, ...data, note: 'stub: queued startCommand' }
  }
  if (cmd !== 'query') return {}
  const what = data?.what
  game.queries.push(String(what))            // ★ 每轮"取了多少次数"可审计 ✓（重试不许重取 ✓）
  if (what === 'goal') return game.goal
  if (what === 'ship') return game.shipCard
  if (what === 'fleet') return game.fleet
  if (what === 'dossier') return dossierStub()          // ★ 单发路径的预取 ✓
  if (what === 'minePlan' || what === 'jobPlan') return minePlan()
  if (what === 'tradePlan') return tradePlan()
  if (what === 'sellPlan') return sellPlan()
  if (what === 'salvagePlan' || what === 'scoutPlan') return {}
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
let retryReply = null                  // ★ 非 null → **第二次**调用用这一段（驱动重试路径 ✓）
const prompts = []                     // ★ 每次模型调用收到的**全部消息**（用来断言"数字真的送到眼前" ✓）
let queriesAtFirstModelCall = -1       // ★ 第一次调模型时已经取过多少事实（用来证明**重试不重取** ✓）

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
      if (modelCalls === 1) queriesAtFirstModelCall = game.queries.length
      prompts.push(
        (options?.messages ?? []).map((m) => (m.content?.[0]?.text ?? '')).join('\n'),
      )
      const text = (modelCalls === 2 && retryReply !== null) ? retryReply : modelReply
      yield { type: 'reasoning-delta', index: 0, text: '（假模型）推理……' }
      yield { type: 'text-delta', index: 1, text }
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

/** 跑一轮 decide，但让第一轮回复是 `first`、重试那一轮是 `retry`（用来驱动"重试恰好一次"✓） */
async function decideWithRetry(first, retry, goalOptions) {
  modelReply = first
  retryReply = retry
  game.goal = { ...game.goal, options: goalOptions ?? [] }
  const before = game.orders.length
  const qBefore = game.queries.length
  const r = await call('decide', { ship: SHIP, hasGoal: true })
  const order = game.orders.length > before ? game.orders[game.orders.length - 1] : null
  return { rpc: r, order, queriesDuring: game.queries.length - qBefore }
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
  // ---- e3. Trade + sizeX/sizeY（★ 29x11 / 11x29 **不是正方形** ✗ →
  //          两个边长必须能分别透传下去 ✓✓）-------------------------------------
  {
    const { rpc, order } = await decideOnce(
      `action=Trade\ngoodName=Wide Good\nx=${HERE.x}\ny=${HERE.y}\nshape=29x11\ndeposit=752000\nreason=宽框\n`)
    console.log(`\n[e3] order 载荷: ${show(order)}`)
    check('e3. Trade 形状: decide 成功', rpc.ok === true, rpc)
    check('e3. Trade 形状: ★ 载荷带 sizeX/sizeY（29x11 ✓ 不是正方形 ✓）',
      order?.sizeX === 29 && order?.sizeY === 11, JSON.stringify({ x: order?.sizeX, y: order?.sizeY }))
    check('e3. Trade 形状: x/y 也带上了', order?.x === HERE.x && order?.y === HERE.y,
      `${order?.x},${order?.y}`)
  }
  {
    const { rpc, order } = await decideOnce(
      `action=Trade\ngoodName=Tall Good\nx=${HERE.x}\ny=${HERE.y}\nsizeX=11\nsizeY=29\nreason=高框\n`)
    console.log(`\n[e4] order 载荷: ${show(order)}`)
    check('e4. Trade 形状: 分开写 sizeX/sizeY 也能透传（11x29 ✓）',
      rpc.ok === true && order?.sizeX === 11 && order?.sizeY === 29,
      JSON.stringify({ x: order?.sizeX, y: order?.sizeY }))
  }
  {
    // ★★ e5. Sell + size=15（正方形边长 ✓✓ 2026-10-17 补）——
    //   单发路径此前**漏解析 `size`** ✗ → 模型答 `size=15` 会被静默丢掉 → order 缺框被拒 ✗✓。
    //   这里端到端钉住：`size=15` 必须和会话回单路径一样透传到 order 载荷 ✓✓。
    const { rpc, order } = await decideOnce(
      `action=Sell\nx=${HERE.x}\ny=${HERE.y}\nsize=15\ngoodsToSell=all\nreason=卖货\n`)
    console.log(`\n[e5] order 载荷: ${show(order)}`)
    check('e5. Sell size=15: decide 成功', rpc.ok === true, rpc)
    check('e5. Sell size=15: ★ 载荷带 size=15（此前被静默丢掉 ✗）',
      order?.size === 15, order?.size)
    check('e5. Sell size=15: goodsToSell=all 不回传字符串（默认全卖 ✓）',
      order?.goodsToSell === undefined, JSON.stringify(order?.goodsToSell))
  }

  // ---- f. ★★ Sell 的**逐货数字**必须真的送到模型眼前（主人 2026-10-17 要求 ✓✓）----
  //   "送到眼前"= facts.sellPlan → buildPrompt 的 JSON 里**逐字**出现 ✓。
  //   （游戏侧 _sell_scan_selftest 的 S9 段证明这些数字**会被算出来** ✓；
  //     这里证明它们**不会被插件丢掉** ✓✓ —— 两边合起来才是完整的一条链 ✓。）
  {
    game.shipCard.holdHasGoods = true     // ★ 有货才会拉 Sell 计划 ✓（与游戏侧同一触发条件 ✓）
    modelCalls = 0
    prompts.length = 0
    const { rpc, order } = await decideOnce(`action=Sell\nx=${HERE.x}\ny=${HERE.y}\nreason=卖货\n`)
    const seen = prompts.join('\n')
    console.log(`\n[f] 模型看到的 Sell 计划片段: ${seen.includes('expectedRevenue') ? '含 expectedRevenue ✓' : '缺失 ✗'}`)
    check('f. Sell 逐货: decide 成功', rpc.ok === true, rpc)
    check('f. Sell 逐货: ★ 模型提示里出现 expectedRevenue ✓（预计卖多少 ✓✓）',
      seen.includes('expectedRevenue'), seen.slice(0, 200))
    check('f. Sell 逐货: ★ 出现 priceDeltaPercent ✓（涨跌幅 ±% ✓）',
      seen.includes('priceDeltaPercent'), '')
    check('f. Sell 逐货: ★ 出现 expectedUnitPrice / normalRevenueEstimate ✓（单位价与正常价都算好了 ✓）',
      seen.includes('expectedUnitPrice') && seen.includes('normalRevenueEstimate'), '')
    check('f. Sell 逐货: ★ 出现 perGoodBest ✓（跨框每种货最好的那个框 ✓）',
      seen.includes('perGoodBest'), '')
    check('f. Sell 逐货: ★ 出现"涨跌幅"两个方向的值（+50% / −20%，都是数字 ✓）',
      seen.includes('"priceDeltaPercent":50') || seen.includes('"priceDeltaPercent": 50'),
      '')
    check('f. Sell 逐货: ★ 出现"跨框最好"那条的数字（2500 ✓）',
      seen.includes('2500'), '')
    check('f. Sell 逐货: ★ 货舱状态 hold{} 也在（used/capacity/free/usedPercent/isHoldFull ✓）',
      seen.includes('isHoldFull') && seen.includes('usedPercent') && seen.includes('blocksTradeLoading'), '')
    check('f. Sell 逐货: ★ 每个候选框都带**绝对坐标** x/y 与 origin（模型不做算术 ✓）',
      seen.includes('"origin"'), '')
    check('f. Sell 逐货: 卖单照旧下得出去（x/y + goodsToSell ✓）',
      order !== null && order.action === 'Sell' && order.x === HERE.x && order.y === HERE.y,
      show(order))
  }

  // ---- g. ★★ 重试路径**驱动式**断言（2026-10-17 补 ✓✓ —— 之前只有静态断言 ✗）----
  //   规矩：首轮没有可用动作行 → **同一批事实**重试**恰好一次** ✓、**不重取数据** ✗、
  //         再失败就照旧失败（**不许有第三次** ✓）。
  {
    modelCalls = 0
    const before = game.orders.length
    // ★ "不重取数据"的**正确测法**：先自己发一个 query 做预检（把共享连接预热 ✓），
    //   然后看 decide 那一轮**自己**有没有额外的 query ✗✓。
    //   （直接数 query 总数会把"decide 一开始就该取的那批事实"也算进去 ✓ —— 那不是重取 ✓。）
    await call('query', { what: 'fleet' })
    const qBefore = game.queries.length
    const { order, rpc } = await decideWithRetry(
      '我先想了想，这艘船其实可以……（只有推理，没有 action 行）',
      `action=Scout\nx=${HERE.x}\ny=${HERE.y}\nreason=重试后给答案\n`,
    )
    const qDuring = game.queries.length - qBefore
    console.log(`\n[g] 重试：模型调用 ${modelCalls} 次；decide 轮内 query ${qDuring} 次；order=${show(order)}`)
    check('g. 重试: ★ 首轮无动作行 → **恰好重试一次**（模型共调用 2 次 ✓✓）',
      modelCalls === 2, modelCalls)
    check('g. 重试: ★ 没有第三次调用（不循环 ✓）', modelCalls < 3, modelCalls)
    check('g. 重试: ★ 重试**不重取数据**（模型两次调用之间 query 次数没变 ✓）',
      queriesAtFirstModelCall >= 0 && game.queries.length === queriesAtFirstModelCall,
      `first=${queriesAtFirstModelCall} now=${game.queries.length}`)
    check('g. 重试: 重试拿到动作行后**真的下单了** ✓',
      order !== null && order.action === 'Scout' && order.x === HERE.x && order.y === HERE.y,
      show(order))
    check('g. 重试: rpc 成功 ✓', rpc.ok === true, rpc)
  }
  {
    // ★ 两轮都不行 → 必须**失败**，而且**不许有第三次**（错误里要带两轮原因 ✓）
    modelCalls = 0
    await call('query', { what: 'fleet' })
    const qBefore = game.queries.length
    retryReply = '还是没有动作行，只有推理。'
    const r = await call('decide', { ship: SHIP, hasGoal: true })
    retryReply = null
    const qDuring = game.queries.length - qBefore
    console.log(`\n[g2] 两轮都无动作行 → ${JSON.stringify(r)}`)
    check('g2. 重试失败: 仍然**恰好两次**模型调用 ✓（不循环 ✓）', modelCalls === 2, modelCalls)
    check('g2. 重试失败: 不重取数据 ✓（两次调用之间没取新事实 ✓）',
      queriesAtFirstModelCall >= 0 && game.queries.length === queriesAtFirstModelCall,
      `first=${queriesAtFirstModelCall} now=${game.queries.length}`)
    check('g2. 重试失败: rpc 明确失败，且理由里带两轮信息 ✓',
      r.ok === false && /retry also failed/.test(String(r.message ?? '')),
      String(r.message ?? '').slice(0, 200))
  }
  // ---- h. ★★ 提示词里必须**看得见多个候选**（主人 2026-10-17 要求 ✓✓）----
  //   "她应该总是框选几块不同区域，看看情况再做决策" →
  //   所以提示词里要有**多个候选框并排摆出来**（不是"一个赢家 + 一句说明" ✗）。
  //   ★ 2026-10-17 起这段提示词由 `dossier.ts` 渲染（有界档案 ✓）——
  //     形状与旧 `renderCandidateTables` 的表格不同 ✓，但**要求一模一样** ✗：
  //     多个框、每个框的绝对坐标、形状、以及"框的位置可以平移"这条事实 ✓。
  {
    modelCalls = 0
    prompts.length = 0
    const { rpc } = await decideOnce(`action=Mine\nx=${HERE.x}\ny=${HERE.y}\nduration=1\nreason=挖矿\n`, [])
    const seen = prompts.join('\n')
    console.log(`\n[h] 提示词里的候选：${['候选框', 'Trade', '框的位置可以变'].filter((k) => seen.includes(k)).join(' / ') || '(无 ✗)'}`)
    check('h. 候选表: decide 成功', rpc.ok === true, rpc)
    check('h. 候选表: ★ 提示词里有 Trade 的**多个候选框**（并排摆开 ✓✓）',
      /★★ Trade/.test(seen) && /候选框（共 \d+ 个，这里列前 \d+ 个/.test(seen), '')
    check('h. 候选表: ★ 每个候选框都带**绝对星区坐标**（不是只有 offset ✓）',
      seen.includes(`${HERE.x},${HERE.y}`) && seen.includes(`${HERE.x + 4},${HERE.y}`), '')
    check('h. 候选表: ★ 表里能看到**两种合法形状**（17x17 与 29x11 ✓）',
      seen.includes('17x17') && seen.includes('29x11'), '')
    check('h. 候选表: ★ 说明里写明"框的位置可以变"（事实 ✓，不是建议 ✗）',
      seen.includes('框的位置可以变'), '')
    check('h. 候选表: ★ 说明里写明"x/y 是算好的绝对值、不要再加 offset" ✓',
      seen.includes('绝对星区坐标') && seen.includes('offset'), '')
    check('h. 候选表: ★ 没有"照抄第一行"之类的指令 ✗',
      !/照抄第一行|直接照抄/.test(seen), '')
  }

  // ---- i. ★★ 缺陷①：空舱且能 Scout 时也必须拉 scoutPlan ✓✓ ----
  //   之前 scoutPlan 被包在 holdHasGoods && canSell 里 → 侦察船通常空舱 → 永远拿不到 ✗
  {
    game.shipCard.holdHasGoods = false        // ★ 侦察船通常空舱 —— 正是缺陷①的场景 ✗
    const qBefore = game.queries.length
    const { rpc } = await decideOnce(`action=None\nreason=先看看\n`, ['Scout'])
    const qDuring = game.queries.slice(qBefore)
    console.log(`\n[i] 空舱 + 能 Scout（goal=Scout）时 decide 拉取的 query: ${qDuring.join(', ')}`)
    check('i. scoutPlan: ★ 空舱且能 Scout 时也必须拉 scoutPlan（不再被 holdHasGoods 挡住 ✓✓）',
      qDuring.includes('scoutPlan'), qDuring.join(','))
    check('i. scoutPlan: decide 成功', rpc.ok === true, rpc)
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
