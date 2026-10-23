/**
 * 护航 rendezvous 的离线自测（**不起服务器、不进游戏** ✓）。
 *
 * 测三组：
 *   escortNeedOf / escortNeedFor —— 这一单是不是**真的缺一艘护航** ✓
 *     · `escortNeedOf` = legacy plan 形状的适配器（2026-10-17 的语义 ✓，阈值只剩一份 ✓）
 *     · `escortNeedFor` = **纯数字**入口（2026-10-24 新判据 ✓：predict / 回执的数字 ✓）
 *   pickRendezvousEscort —— 从舰队快照里挑哪艘船飞过去 ✓（硬规矩全在这里 ✓）
 *   buildEscortHint      —— 投递块里那一行「护航建议」✓
 *     ★ 2026-10-24 主人点名的断言：判护航需求时**不发任何 `*Plan` 查询** ✓✓
 *
 *   node test/rendezvous.mjs
 *
 * 为什么值得测：这些函数决定「说不说、派不派、派谁」，判错了会白白占掉一艘战斗舰 ✓，
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

const {
  escortNeedOf, escortNeedFor, pickRendezvousEscort, buildEscortHint, ESCORT_OBS_TTL_MS,
} = await import('../lib/index.js')

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
// escortNeedFor —— **纯数字**判据（2026-10-24 新判据 ✓）
//   ★ 阈值语义与 escortNeedOf 是**同一份** ✓（下面几条用数字直接钉住 ✓）
// ---------------------------------------------------------------------------

check('⑯ 只有数字：0.13 → 缺护航（与 ③ 同一个阈值 ✓）',
  escortNeedFor({ ship: 'Trader-00001', baseAttackChance: 0.13 }).needed, true)
check('⑯ 加一艘估约 0.0975 ≤ 0.10',
  escortNeedFor({ ship: 'Trader-00001', baseAttackChance: 0.13 }).riskWithEscort <= 0.1, true)
check('⑰ 本来就在闸门内（0.08）→ 不需要',
  escortNeedFor({ ship: 'S', baseAttackChance: 0.08 }).needed, false)
check('⑱ 0.40 加一艘也压不下来 → 不派',
  escortNeedFor({ ship: 'S', baseAttackChance: 0.4 }).needed, false)
check('⑲ 游戏没算出来（known=false）→ 不判（绝不把未知当 0% ✗）',
  escortNeedFor({ ship: 'S', known: false }).needed, false)
check('⑳ known 但一个数字都没有 → 不判',
  escortNeedFor({ ship: 'S', known: true }).needed, false)
check('㉑ 同星系已有护航候选 → 不需要派人',
  escortNeedFor({ ship: 'S', baseAttackChance: 0.13, sameSectorEscorts: ['Combat-00001'] }).needed, false)
check('㉒ 门槛可传（0.05 时 0.06 值得派）',
  escortNeedFor({ ship: 'S', baseAttackChance: 0.06, gate: 0.05 }).needed, true)
check('㉓ 游戏给的真实带护航概率优先于 ×0.75 估计',
  escortNeedFor({ ship: 'S', baseAttackChance: 0.13, withEscortsRisk: 0.2 }).needed, false)
check('㉔ attackChance 兜底（Travel 只有一个数 ✓）',
  escortNeedFor({ ship: 'S', attackChance: 0.13 }).needed, true)

// ---------------------------------------------------------------------------
// buildEscortHint —— ★★ 判护航需求时**不发任何 `*Plan` 查询** ✓✓（2026-10-24 主人点名）
//   ★ 用桩 query 记下每一次 what ✓；`/plan/i` 正则与 G5 的断言同款 ✓
// ---------------------------------------------------------------------------

const NOW = Date.now()

/** 与 `predict` 回包同形的观测 ✓ */
function obsOf(over = {}) {
  return {
    atMs: NOW, ship: 'Trader-00001', action: 'Trade',
    baseAttackChance: 0.13, known: true, source: 'predict', ...over,
  }
}

const FLEET_LIST = {
  ships: [
    { name: 'Trader-00001', busy: false, hasCaptain: true, sector: { x: -399, y: 81 } },  // 行动船
    { name: 'Combat-00001', busy: false, hasCaptain: true, sector: { x: -391, y: 77 } },  // ★ 能打
    { name: 'Combat-00002', busy: true, hasCaptain: true, sector: { x: -391, y: 77 } },   // 忙 → 不该被查
    { name: 'Scout-00009', busy: false, hasCaptain: true, sector: { x: -380, y: 60 } },   // 没武器
  ],
}

/** 桩：记下每次 what ✓；答案按 what 给 ✓ */
function stubQuery(answers) {
  const calls = []
  const q = async (what, params) => {
    calls.push({ what, params })
    const a = answers[what]
    if (a === undefined) return { ok: false, why: 'stub: no answer for ' + what }
    return typeof a === 'function' ? a(params) : { ok: true, data: a }
  }
  return { q, calls }
}

/** ★ `ship{brief}` 的桩：Combat 能打 ✓、Scout 明确不能打 ✓（都是**游戏事实**的口径 ✓） */
const armed = (params) => ({
  ok: true,
  data: params.ship === 'Scout-00009'
    ? { name: params.ship, brief: true, canFight: false, canFightKnown: true, armedTurrets: 0, armedTurretsKnown: true }
    : { name: params.ship, brief: true, canFight: true, canFightKnown: true, armedTurrets: 2, armedTurretsKnown: true },
})

const LEGACY_PLAN = /plan/i

{
  const { q, calls } = stubQuery({ list: FLEET_LIST, ship: armed })
  const hint = await buildEscortHint(q, obsOf(), { nowMs: NOW })
  check('㉕ 缺护航 + 名单里有空闲战斗舰 → 给一行建议', typeof hint, 'string')
  check('㉕ 建议里点名那艘能打的船',
    typeof hint === 'string' && hint.includes('Combat-00001'), true)
  check('㉕ 没武器的船不进建议',
    typeof hint === 'string' && !hint.includes('Scout-00009'), true)
  check('㉕ 建议里带上那两份数字（13.0% / 9.8%）',
    typeof hint === 'string' && hint.includes('13.0%') && hint.includes('9.8%'), true)
  check('㉖ ★ 只查 list + ship', calls.map((c) => c.what), ['list', 'ship', 'ship'])
  check('㉖ ★★ 一次 `*Plan` 都没发 ✓✓',
    calls.every((c) => !LEGACY_PLAN.test(c.what)), true)
  check('㉖ 忙船没被查（它派不动 ✓）',
    calls.filter((c) => c.what === 'ship').every((c) => c.params.ship !== 'Combat-00002'), true)
}

{
  // 风险本来就在闸门内 → **0 次查询** ✓（连 list 都不发 ✓）
  const { q, calls } = stubQuery({ list: FLEET_LIST, ship: armed })
  const hint = await buildEscortHint(q, obsOf({ baseAttackChance: 0.08 }), { nowMs: NOW })
  check('㉗ 不需要护航 → 没有建议', hint, undefined)
  check('㉗ ★ 而且一次查询都不发', calls.length, 0)
}

{
  // 已经带了护航 → 不再建议 ✓（那件事已经做了 ✓）
  const { q, calls } = stubQuery({ list: FLEET_LIST, ship: armed })
  const hint = await buildEscortHint(q, obsOf({ escortsGiven: ['Raven-00001'] }), { nowMs: NOW })
  check('㉘ 下单已带护航 → 不再建议', hint, undefined)
  check('㉘ 且 0 次查询', calls.length, 0)
}

{
  // 过了有效期 → 旧数不当数 ✓
  const { q, calls } = stubQuery({ list: FLEET_LIST, ship: armed })
  const hint = await buildEscortHint(q, obsOf({ atMs: NOW - ESCORT_OBS_TTL_MS - 1 }), { nowMs: NOW })
  check('㉙ 观测过期（>15 分钟）→ 不建议', hint, undefined)
  check('㉙ 且 0 次查询', calls.length, 0)
}

{
  // 名单里只有"明确没武装"的船 → 老实说没有，别硬派 ✓
  const { q, calls } = stubQuery({
    list: { ships: [
      { name: 'Trader-00001', busy: false, hasCaptain: true, sector: { x: -399, y: 81 } },
      { name: 'Scout-00009', busy: false, hasCaptain: true, sector: { x: -380, y: 60 } },
    ] },
    ship: (params) => ({
      ok: true,
      data: {
        name: params.ship, brief: true,
        canFight: false, canFightKnown: true, armedTurrets: 0, armedTurretsKnown: true,
      },
    }),
  })
  const hint = await buildEscortHint(q, obsOf(), { nowMs: NOW })
  check('㉚ 名单里没有能打的 → 明说（别硬派）',
    typeof hint === 'string' && hint.includes('没有空闲战斗舰'), true)
  check('㉚ 仍不发任何 `*Plan`', calls.every((c) => !LEGACY_PLAN.test(c.what)), true)
}

{
  // 同星系就有一艘可用的 → 现有流程就够（原语义 ✓），不建议 rendezvous ✓
  const { q, calls } = stubQuery({ list: { ships: [
    { name: 'Trader-00001', busy: false, hasCaptain: true, sector: { x: -399, y: 81 } },
    { name: 'Combat-00001', busy: false, hasCaptain: true, sector: { x: -399, y: 81 } },
  ] }, ship: armed })
  const hint = await buildEscortHint(q, obsOf(), { nowMs: NOW })
  check('㉛ 同星系已有护航候选 → 不建议 rendezvous', hint, undefined)
  check('㉛ 只查了 list（没查 brief）', calls.map((c) => c.what), ['list'])
}

// ---------------------------------------------------------------------------
// 投递块里的那一行（`task.ts` 的 `escortHint`）—— **只告知** ✓
// ---------------------------------------------------------------------------

{
  const { renderTaskBlock } = await import('../lib/task.js')
  const base = {
    taskId: 't-abc123', ship: 'Trader-00001', goalText: '', goalOptions: ['Trade'], deadlineHintSec: 90,
  }
  const withHint = renderTaskBlock({
    ...base,
    escortHint: '你上次量的这单伏击 13.0% > 闸门 10.0%（加一艘约 9.8% ✓）—— 名单里有空闲战斗舰 Combat-00001',
  })
  check('㉜ 投递块里带上那一行', withHint.includes('★ 护航建议（只告知，派不派你定 ✓）'), true)
  check('㉜ 且点了名', withHint.includes('Combat-00001'), true)
  check('㉜ 没有观测时块里没有这一行', renderTaskBlock(base).includes('护航建议'), false)
  check('㉝ 超预算的建议行不加（块体积契约 ✓）',
    renderTaskBlock({ ...base, escortHint: '护'.repeat(400) }).includes('护航建议'), false)
}

// ---------------------------------------------------------------------------

let failed = 0
for (const c of checks) {
  if (!c.pass) failed++
  console.log(`${c.pass ? '  ✓' : '  ✗'} ${c.label}` +
    (c.pass ? '' : `\n      期望 ${JSON.stringify(c.expected)} / 实际 ${JSON.stringify(c.actual)}`))
}
console.log(`\n${checks.length - failed}/${checks.length} 通过`)
process.exit(failed === 0 ? 0 : 1)
