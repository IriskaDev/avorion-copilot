/**
 * 护航 rendezvous 的离线自测（**不起服务器、不进游戏** ✓）。
 *
 * 只测两个纯函数：
 *   escortNeedOf        —— 这一轮的 tradePlan 是不是**真的缺一艘护航** ✓
 *   pickRendezvousEscort —— 从舰队快照里挑哪艘船飞过去 ✓（硬规矩全在这里 ✓）
 *
 *   node test/rendezvous.mjs
 *
 * 为什么值得测：这两个函数决定「派不派船、派谁」，派错了会白白占掉一艘战斗舰 ✓，
 * 而全流程（decide → Travel → 下一轮带上护航下单）要开游戏才能验 ✗。
 */
import { registerHooks } from 'node:module'

// npm 装好的包脱离 DSH 加载不了（传递依赖 cordis 在 npm 包里是空目录），用本地桩顶替。
// 只影响本进程，不动插件产物。
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

const { escortNeedOf, pickRendezvousEscort } = await import('../lib/index.js')

// ---------------------------------------------------------------------------
// 造数据：形状照抄游戏侧 link_in.lua 的 tradePlan 回包（多区域版 ✓）
// ---------------------------------------------------------------------------

function plan(overrides = {}) {
  return {
    ship: 'Trader-00001',
    recommendation: null,
    riskWarning: '没有任何路线通过风险闸门（伏击概率 ≤ 10%）✗ —— 本鱼**不推荐**下单 ✓',
    areasScanned: 9,
    scanMs: 3200,
    scan: { maxAttackChance: 0.1, shipSector: { x: -399, y: 81 } },
    areaRanking: [
      {
        area: { offset: { x: 0, y: 0 } },
        routeCount: 4,
        bestRouteName: 'Antigrav Unit',
        netProfitLow: 120000,
        netProfitHigh: 140000,
        attackChance: 0.13,
        attackChanceBase: 0.13,
        escortsNeeded: [],
        acceptable: false,
      },
    ],
    orderHint: { x: -399, y: 81, goodName: 'Antigrav Unit', deposit: 752000, escorts: [] },
    ...overrides,
  }
}

function okPlan() {
  return plan({
    recommendation: { goodName: 'Oxygen', attackChance: 0.04, x: -399, y: 81 },
    riskWarning: null,
  })
}

const checks = []
function check(label, actual, expected) {
  const pass = JSON.stringify(actual) === JSON.stringify(expected)
  checks.push({ label, pass, actual, expected })
}

// ---------------------------------------------------------------------------
// escortNeedOf
// ---------------------------------------------------------------------------

check('① 已有推荐 → 不需要护航', escortNeedOf(okPlan(), []).needed, false)
check('② 没有 tradePlan 数据 → 不需要', escortNeedOf(undefined, []).needed, false)

{
  // 0.13 × 0.75 = 0.0975 ≤ 0.10 ✓ → 一艘护卫就够 → 值得派人过去
  const need = escortNeedOf(plan(), [])
  check('③ 最好候选 0.13、本星系无护航 → 缺护航', need.needed, true)
  check('③ 估算加护航后 < 门槛', (need.riskWithEscort ?? 9) <= 0.1, true)
  check('③ 指出是哪条路线', need.route, 'Antigrav Unit')
}
check('④ 本星系已有护航候选 → 交给现有流程', escortNeedOf(plan(), ['Combat-00001']).needed, false)
check('⑤ 风险太高、护航也压不下来 → 不派人（别白跑一趟）', escortNeedOf(plan({
  areaRanking: [{
    bestRouteName: 'Risky', netProfitLow: 5, attackChance: 0.4, attackChanceBase: 0.4, acceptable: false,
  }],
}), []).needed, false)
check('⑥ 一条路线都没有 → 护航救不了', escortNeedOf(plan({
  riskWarning: '扫了 9 个区域，一条贸易路线都没有 ✗',
  areaRanking: [{ bestRouteName: null, routeCount: 0, acceptable: false }],
}), []).needed, false)
check('⑦ 门槛从 scan.maxAttackChance 读（0.05 时 0.06 也值得派）', escortNeedOf(plan({
  scan: { maxAttackChance: 0.05 },
  areaRanking: [{ bestRouteName: 'X', netProfitLow: 1, attackChance: 0.06, attackChanceBase: 0.06, acceptable: false }],
}), []).needed, true)
check('⑦ 门槛 0.05 时 0.10 派了也没用', escortNeedOf(plan({
  scan: { maxAttackChance: 0.05 },
  areaRanking: [{ bestRouteName: 'X', netProfitLow: 1, attackChance: 0.1, attackChanceBase: 0.1, acceptable: false }],
}), []).needed, false)
check('⑧ 老形状（单区域 candidates）也认', escortNeedOf(plan({
  riskWarning: undefined,
  areaRanking: undefined,
  candidates: [{ name: 'Drill', attackChance: 0.12 }],
}), []).needed, true)
check('⑨ 达标的区域不算缺护航', escortNeedOf(plan({
  areaRanking: [{ bestRouteName: 'X', netProfitLow: 1, attackChance: 0.08, attackChanceBase: 0.08, acceptable: true }],
}), []).needed, false)

// ---------------------------------------------------------------------------
// pickRendezvousEscort
// ---------------------------------------------------------------------------

const FLEET = [
  { name: 'Trader-00001', sector: { x: -399, y: 81 }, busy: false, hasCaptain: true, turretCount: 1 },   // 行动船自己
  { name: 'Scout-00001', sector: { x: -399, y: 81 }, busy: false, hasCaptain: true, turretCount: 1 },    // 同星系
  { name: 'Combat-00001', sector: { x: -391, y: 77 }, busy: false, hasCaptain: true, turretCount: 1 },   // ★ 首选
  { name: 'Miner-00001', sector: { x: -400, y: 90 }, busy: false, hasCaptain: true, turretCount: 6 },    // 有炮塔，名字不像
  { name: 'Trader-00002', sector: { x: -380, y: 60 }, busy: true, hasCaptain: true, turretCount: 8 },     // 忙
  { name: 'Raven-00002', sector: { x: -350, y: 30 }, busy: false, hasCaptain: false, turretCount: 9 },   // 没船长
  { name: 'Player-00001', sector: { x: -300, y: 20 }, busy: false, hasCaptain: true, turretCount: 12 },  // 玩家在开
  { name: 'Scout-00009', sector: { x: -200, y: 10 }, busy: false, hasCaptain: true, turretCount: 0 },    // 没炮、名字不像
]

check('⑩ 首选名字像战斗舰的那艘',
  pickRendezvousEscort(FLEET, 'Trader-00001', 'Player-00001', { x: -399, y: 81 })?.name, 'Combat-00001')

check('⑪ 只有"有炮塔但名字不像"的船时也会被派',
  pickRendezvousEscort(FLEET.filter((s) => s.name !== 'Combat-00001'), 'Trader-00001', 'Player-00001', { x: -399, y: 81 })?.name,
  'Miner-00001')

check('⑫ 名字像战斗舰、但 turretCount 读不到（探针失败）也认',
  pickRendezvousEscort([
    { name: 'Raven-00002', sector: { x: -350, y: 30 }, busy: false, hasCaptain: true },
  ], 'Trader-00001', 'Player-00001', { x: -399, y: 81 })?.name, 'Raven-00002')

check('⑬ 同星系的不算 rendezvous 候选',
  pickRendezvousEscort([
    { name: 'Scout-00001', sector: { x: -399, y: 81 }, busy: false, hasCaptain: true, turretCount: 1 },
  ], 'Trader-00001', 'Player-00001', { x: -399, y: 81 }), null)

check('⑭ 忙船 / 没船长 / 玩家在开 / 没炮又不像战斗舰 → 一个都不派',
  pickRendezvousEscort([
    { name: 'Trader-00002', sector: { x: -380, y: 60 }, busy: true, hasCaptain: true, turretCount: 8 },
    { name: 'Raven-00002', sector: { x: -350, y: 30 }, busy: false, hasCaptain: false, turretCount: 9 },
    { name: 'Player-00001', sector: { x: -300, y: 20 }, busy: false, hasCaptain: true, turretCount: 12 },
    { name: 'Scout-00009', sector: { x: -200, y: 10 }, busy: false, hasCaptain: true, turretCount: 0 },
  ], 'Trader-00001', 'Player-00001', { x: -399, y: 81 }), null)

check('⑮ 空快照 → null（不做假设）',
  pickRendezvousEscort([], 'Trader-00001', 'Player-00001', { x: -399, y: 81 }), null)

// ---------------------------------------------------------------------------

let failed = 0
for (const c of checks) {
  if (!c.pass) failed++
  console.log(`${c.pass ? '  ✓' : '  ✗'} ${c.label}` +
    (c.pass ? '' : `\n      期望 ${JSON.stringify(c.expected)} / 实际 ${JSON.stringify(c.actual)}`))
}
console.log(`\n${checks.length - failed}/${checks.length} 通过`)
process.exit(failed === 0 ? 0 : 1)
