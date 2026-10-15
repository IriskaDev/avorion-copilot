/**
 * 护航 rendezvous 的**回环联测**（不碰游戏、不碰 DSH ✓）。
 *
 * 做法：在本地随便挑一个空闲端口，把插件 apply() 起来当"DSH 侧"，
 * 再用一个假游戏客户端连上去，按 PROTOCOL v2 的帧格式收发 JSON ✓。
 * 这样就可以**完整**验主人要的那条链：
 *
 *   ① 贸易计划"缺护航" + 本星系没有护航候选 + 别的星系有闲置战斗船
 *      → DSH 派 Combat-00001 飞过去（Travel，坐标 = 目标船的星区）
 *      → **本轮 action=None**，而且**根本不问模型**（问了就可能硬下单 ✗）
 *   ② 紧接着再来一轮（护航还在路上）
 *      → **不重复派**（Travel 是异步的，否则每轮都会多派一艘 ✗）
 *   ③ 护航到位后再来一轮（tradePlan 有推荐了）
 *      → 这回才问模型，并把 Trade 单连同 escorts 一起下出去 ✓
 *
 *   node test/rendezvous-flow.mjs
 *
 * ⚠️ 只用 127.0.0.1 + 高位端口，跑完立刻关掉 ✓；不会碰游戏那个 8765 端口 ✓。
 * ⚠️ 日志（live / decisions）会写到 **临时目录** ✓ —— 绝不污染主人真实的那几份日志 ✓：
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

const sandboxHome = fs.mkdtempSync(path.join(os.tmpdir(), 'copilot-flow-home-'))
process.env.USERPROFILE = sandboxHome
process.env.HOMEDRIVE = ''
process.env.HOMEPATH = ''

const { apply } = await import('../lib/index.js')

const PORT = 18799
const ACTION_SHIP = 'Trader-00001'
const TARGET_SECTOR = { x: -399, y: 81 }

// ---------------------------------------------------------------------------
// 假游戏：按 cmd 回数据，并把 order 记下来 ✓
// ---------------------------------------------------------------------------

const TRADE_ROUTES = [
  { name: 'Antigrav Unit', attackChance: 0.13, attackChanceBase: 0.13, escortsNeeded: [], acceptable: false, netProfitLow: 120000 },
]

function tradePlanMissingEscort() {
  return {
    ship: ACTION_SHIP,
    recommendation: null,
    riskWarning: '没有任何路线通过风险闸门（伏击概率 ≤ 10%）✗ —— 本鱼**不推荐**下单 ✓',
    areasScanned: 9,
    scanMs: 3200,
    scan: { maxAttackChance: 0.1, shipSector: { ...TARGET_SECTOR } },
    areaRanking: TRADE_ROUTES.map((r) => ({ ...r, bestRouteName: r.name, netProfitHigh: r.netProfitLow })),
    orderHint: { x: TARGET_SECTOR.x, y: TARGET_SECTOR.y, goodName: 'Antigrav Unit', deposit: 752000, escorts: [] },
  }
}

function tradePlanWithEscort() {
  return {
    ...tradePlanMissingEscort(),
    recommendation: {
      goodName: 'Antigrav Unit', x: TARGET_SECTOR.x, y: TARGET_SECTOR.y, deposit: 752000,
      attackChance: 0.0975, attackChanceBase: 0.13, escorts: ['Combat-00001'], netProfitLow: 120000,
    },
    riskWarning: null,
    escortsOffered: ['Combat-00001'],
    orderHint: { x: TARGET_SECTOR.x, y: TARGET_SECTOR.y, goodName: 'Antigrav Unit', deposit: 752000, escorts: ['Combat-00001'] },
  }
}

const game = {
  goal: { text: '在附近跑贸易赚钱，优先低风险的短途路线', options: ['Trade'], hasGoal: true },
  shipCard: {
    name: ACTION_SHIP, sector: { ...TARGET_SECTOR }, busy: false, hasCaptain: true,
    captainClass: 'Merchant', turretCount: 1, freeCargoSpace: 3393,
    actionNames: ['Mine', 'Salvage', 'Trade', 'Travel'],
  },
  fleet: {
    designated: 4,
    piloted: 'Player-00001',
    ships: [
      // ★ 目标船所在星系里**一艘能护航的都没有** ✓（这是 rendezvous 的前提 ✓）
      { name: ACTION_SHIP, sector: { ...TARGET_SECTOR }, busy: false, hasCaptain: true, turretCount: 1 },
      { name: 'Scout-00001', sector: { x: -395, y: 70 }, busy: false, hasCaptain: true, turretCount: 1 },
      { name: 'Combat-00001', sector: { x: -391, y: 77 }, busy: false, hasCaptain: true, turretCount: 1 },
      { name: 'Miner-00001', sector: { x: -400, y: 90 }, busy: true, hasCaptain: true, turretCount: 6 },
      { name: 'Player-00001', sector: { x: -300, y: 20 }, busy: false, hasCaptain: true, turretCount: 12 },
    ],
  },
  tradePlan: tradePlanMissingEscort(),
  orders: [],
}

function reply(cmd, data) {
  if (cmd === 'hello') return { side: 'game', ver: 2, caps: ['query', 'order', 'recall', 'reload'] }
  if (cmd !== 'query' && cmd !== 'order') return {}
  if (cmd === 'order') {
    game.orders.push(data)
    return { accepted: true, executed: true, ...data, note: 'stub: queued startCommand' }
  }
  const what = data?.what
  if (what === 'goal') return game.goal
  if (what === 'ship') return game.shipCard
  if (what === 'fleet') return game.fleet
  if (what === 'tradePlan') return game.tradePlan
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
let modelReply = 'action=Trade\nx=-399\ny=81\ngoodName=Antigrav Unit\nduration=1\nescorts=Combat-00001\nreason=护航到位，出海\n'

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
      // ★ 2026-10-17 修：原来只收**第一条**消息 ✗ → 加了"每船记忆"后，
      //   第一条变成记忆块 ✗，于是"护航候选"的断言误报失败 ✓。
      //   改为把该次调用的**全部**消息拼起来收 ✓（模型实际看到的就是这些 ✓✓）。
      seenPrompts.push(
        (options.messages ?? [])
          .map((m) => (m.content?.[0]?.text ?? ''))
          .join('\n'),
      )
      yield { type: 'reasoning-delta', index: 0, text: '（假模型）风险已达标，出海。' }
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
  // ---- ① 缺护航的一轮 ------------------------------------------------------
  const r1 = await call('decide', { ship: ACTION_SHIP, hasGoal: true })
  check('① decide 成功', r1.ok === true, r1)
  check('① 本轮 action=None（不硬下单）', r1.data?.action === 'None', r1.data?.action)
  check('① 没有问模型（问了就可能硬出海）', modelCalls === 0, modelCalls)
  check('① 派了一艘 Travel', game.orders.length === 1, game.orders)
  check('① 派的是战斗舰 Combat-00001', game.orders[0]?.ship === 'Combat-00001', game.orders[0]?.ship)
  check('① 动作是 Travel', game.orders[0]?.action === 'Travel', game.orders[0]?.action)
  check('① 目的地 = 行动船的星区',
    game.orders[0]?.x === TARGET_SECTOR.x && game.orders[0]?.y === TARGET_SECTOR.y,
    `${game.orders[0]?.x},${game.orders[0]?.y}`)
  check('① reason 说明了在等护航', /护航/.test(r1.data?.reason ?? ''), r1.data?.reason)

  // ---- ② 护航还在路上：不能重复派 ------------------------------------------
  const r2 = await call('decide', { ship: ACTION_SHIP, hasGoal: true })
  check('② 仍是 action=None', r2.data?.action === 'None', r2.data?.action)
  check('② 没有重复派船（还是只有 1 张 Travel 单）', game.orders.length === 1, game.orders.length)
  check('② 没有问模型', modelCalls === 0, modelCalls)
  check('② reason 说明护航已在路上', /已在飞往|在途|路上/.test(r2.data?.reason ?? ''), r2.data?.reason)

  // ---- ③ 护航到位：这回才出海 ---------------------------------------------
  game.tradePlan = tradePlanWithEscort()
  game.fleet.ships = game.fleet.ships.map((s) => (s.name === 'Combat-00001'
    ? { ...s, sector: { ...TARGET_SECTOR } }        // ★ 它到了 ✓
    : s))
  const r3 = await call('decide', { ship: ACTION_SHIP, hasGoal: true })
  check('③ 问了模型', modelCalls === 1, modelCalls)
  // ★ 2026-10-17 修：加了"每船记忆"之后，模型收到的是**多条**消息 ✗ →
  //   记忆块现在排在**第一条** ✓，事实块（含护航候选）在后面 ✓。
  //   所以断言必须扫**全部**消息 ✓（原来只看 seenPrompts[0] ✗ → 误报失败 ✓✓）
  const seenAll = (seenPrompts ?? []).join('\n')
  check('③ 模型看到的同星系护航候选里有 Combat-00001',
    /同星系护航候选.*Combat-00001/.test(seenAll), seenAll.slice(0, 300))
  check('③ action=Trade（真的出海了）', r3.data?.action === 'Trade', r3.data?.action)
  check('③ 第二张单是 Trade', game.orders[1]?.action === 'Trade', game.orders[1])
  check('③ 带上同星系护航', JSON.stringify(game.orders[1]?.escorts) === JSON.stringify(['Combat-00001']),
    game.orders[1]?.escorts)
  check('③ 一共只下了两张单（Travel + Trade）', game.orders.length === 2, game.orders.length)
} catch (error) {
  check(`回环流程抛错：${String(error)}`, false, String(error))
}

// ---------------------------------------------------------------------------

let failed = 0
for (const c of checks) {
  if (!c.pass) failed++
  console.log(`${c.pass ? '  ✓' : '  ✗'} ${c.label}` + (c.pass ? '' : `   ← 实际 ${JSON.stringify(c.actual)}`))
}
console.log('\n下单流水：')
for (const o of game.orders) console.log(`   ${o.ship} -> ${o.action} (${o.x},${o.y}) ${o.escorts ? 'escorts=' + o.escorts.join(',') : ''}`)
console.log(`\n${checks.length - failed}/${checks.length} 通过`)

for (const d of disposers) d()
sock.destroy()
if (failed === 0) {
  fs.rmSync(sandboxHome, { recursive: true, force: true })
} else {
  console.log(`\n（有失败项 → 插件日志留在临时目录供排查：${sandboxHome}）`)
}
process.exit(failed === 0 ? 0 : 1)
