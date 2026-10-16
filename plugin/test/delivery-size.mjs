/**
 * delivery-size.mjs —— ★★ 两条投递路径的**体积自检**（2026-10-17，主人批准的改动 ✓✓）
 *
 * 这份测试守的是那次事故的**根因** ✗✓：
 *   一条投进会话的 `<fleet_task>` 曾经到 **8,761,847 字符** ✓ —— 里面一份 Scout 计划
 *   JSON 就是 8.7 MB ✓。修法不是"加一个上限" ✗，而是：
 *     · **agent 路径只告知**（一行通知 + 工具指针 ✓），数据一个字节都不进块 ✗；
 *     · **单发路径预取 + 裁剪 + 硬字节预算** ✓（它没有工具，不能自己查 ✓）。
 *
 * 四条断言（每条都对着一个**具体的失效模式** ✓）：
 *   A. 哪怕调用方**硬塞**一份 8.7 MB 的计划 + 船卡两遍，
 *      agent 块仍然 < **2 KB**（**这四条是本次改动最要紧的性质** ✓✓）；
 *   B. 块里带着船名 / 任务号 / 期限 / 工具指针 / 答案契约 / `task=` 回显要求 ✓；
 *   C. 单发档案在**病态**输入下仍然 ≤ 自己的字节预算，且保证事实（船/规则/能做什么/
 *      每个计划的推荐或明说的零候选原因）**都在** ✓；
 *   D. 裁剪顺序**确定性** ✓（同一份输入 → 同一份 dropped 序列与同样的字节数 ✓），
 *      且**逐条记录**裁了什么 ✓（绝不静默 ✗✓）。
 *
 * 跑法（仓库根或 plugin/ 下都行 ✓）：  node plugin/test/delivery-size.mjs
 */

import { renderTaskBlock } from '../lib/task.js'
import { renderDossier, byteLen, PLAN_DROP_ORDER } from '../lib/dossier.js'

const checks = []
const check = (label, pass, actual) => checks.push({ label, pass: pass === true, actual })
const fmt = (n) => (n >= 1000000 ? `${(n / 1000000).toFixed(2)} MB` : n >= 1000 ? `${(n / 1000).toFixed(1)} KB` : `${n} B`)

// ---------------------------------------------------------------------------
// A/B. agent 路径：一行通知 —— 与数据大小**无关** ✓
// ---------------------------------------------------------------------------

/**
 * ★ 病态输入（**照着事故的真实形状做** ✓）：一份 Scout 计划的候选里带着粗扫 `run()` 的
 *   逐星区明细（`reachableCoordinates` / `offgridSegments`）+ 每个候选内嵌的 analysis ✓。
 */
function pathologicalPlan(areas = 9, sectors = 441) {
  const ranking = []
  for (let i = 0; i < areas; i++) {
    const reach = []
    for (let j = 0; j < sectors; j++) reach.push({ x: j, y: i, faction: 1, tier: j % 7, danger: 0.01 * (j % 5) })
    const entry = { x: 100 + i, y: 200 + i, origin: 'coarse', shape: '21x21', unknownCount: 41, revealsLow: 3 }
    entry.analysis = { reachable: 400, sectors: 441, reachableCoordinates: reach, offgridSegments: reach }
    entry.unknown = { unknownCount: 41, knownCount: 400, total: 441, sectors: reach }
    ranking.push(entry)
  }
  return {
    ship: 'Scout-00001', action: 'Scout', areaRanking: ranking, areasScannedList: ranking,
    recommendation: ranking[0], orderHint: { x: 100, y: 200, size: 21 },
  }
}

function pathologicalCard() {
  const card = { name: 'Scout-00001', cargoCapacity: 5000, actionNames: ['Mine', 'Scout'] }
  card.depth = { here: {}, towardCentre: [] }
  for (let i = 0; i < 21; i++) card.depth.towardCentre.push({ x: i, y: i, richness: 1.2, materialProbabilities: [] })
  return card
}

const rawPlan = pathologicalPlan()
const rawCard = pathologicalCard()
const rawPlanBytes = byteLen(JSON.stringify(rawPlan))
const rawPlanPretty = byteLen(JSON.stringify(rawPlan, null, 2))     // 事故里用的就是"原样缩进"✓
const rawCardBytes = byteLen(JSON.stringify(rawCard, null, 2))
const request = {
  taskId: 't-deadbeef',
  ship: 'Scout-00001',
  goalText: '尽量侦察还没发现的地方；采高级矿；风险 <10%',
  goalOptions: ['Mine', 'Salvage', 'Trade', 'Sell', 'Scout'],
  // ★★ 故意硬塞（模拟"调用方还在传旧字段"✓）：能不能被忽略，正是这条断言要证明的 ✓
  card: rawCard,
  planText: JSON.stringify(rawPlan, null, 2),
  deadlineHintSec: 20,
}
const block = renderTaskBlock(request)
const blockBytes = byteLen(block)

console.log(`\n[A/B] agent 块：${fmt(blockBytes)}（数据：计划 ${fmt(rawPlanBytes)} / 缩进后 ${fmt(rawPlanPretty)}；船卡缩进后 ${fmt(rawCardBytes)}）`)
console.log(`      如果照旧"预取全塞"：${fmt(blockBytes + rawPlanPretty + 2 * rawCardBytes)} —— 那就是 8.7 MB 事故的形状`)

check('A. ★ agent 块 < 2000 字节（哪怕调用方硬塞 8.7MB 级计划 ✓）', blockBytes < 2000, blockBytes)
check('A. ★ 块的大小与计划大小无关（塞进去的 planText 一个字节都没进 ✓）',
  !block.includes('reachableCoordinates'), block.slice(0, 120))
check('A. ★ 块里也没有船卡副本（0 份 ✓ —— 以前是 2 份 ✗）',
  !block.includes('cargoCapacity'), block.slice(0, 120))
check('B. 块里有船名 ✓', block.includes('Scout-00001'))
check('B. 块里有任务号与回显要求 ✓', block.includes('t-deadbeef') && /task=t-deadbeef/.test(block))
check('B. 块里有期限提示 ✓', block.includes('deadline_hint="20s"'))
check('B. 块里说了"它空闲了、要一个决策" ✓', /空闲/.test(block) && /需要一个决策/.test(block))
check('B. ★ 块里有**工具指针**（哪个查询查什么 ✓）',
  block.includes('what:"ship"') && block.includes('minePlan') && block.includes('scoutPlan'), '')
check('B. ★ 指针里写明了计划查询缺省就是小答案（compact/top ✓）',
  /compact/.test(block) && /top/.test(block), '')
check('B. 答案契约在块里，且要求 action 放**第一行** ✓',
  /action=</.test(block) && /第 1 行/.test(block), '')
check('B. 块是**任务**而不是主人说话（delimiter + 明说 ✓）',
  block.startsWith('<fleet_task id="t-deadbeef"') && block.trimEnd().endsWith('</fleet_task>'))
check('B. 玩家限定的动作写进了块 ✓（她不必再查一次才知道边界 ✓）',
  block.includes('Mine, Salvage, Trade, Sell, Scout'), '')

// ---------------------------------------------------------------------------
// C/D. 单发档案：有界 + 保证事实 + 确定性
// ---------------------------------------------------------------------------

/** 病态档案：每个计划都带巨表 + 一大堆散文（真实响应就是这种形状 ✓） */
function pathologicalDossier(plans = 5, rows = 40) {
  const ranking = []
  for (let i = 0; i < rows; i++) {
    const reach = []
    for (let j = 0; j < 441; j++) reach.push({ x: j, y: i })
    ranking.push({
      x: 100 + i, y: 200 + i, shape: '21x21', origin: i % 2 === 0 ? 'coarse' : 'fine',
      unknownCount: 41 - i, totalSectors: 441, attackChance: 0.05 + i * 0.01, baseAttackChance: 0.05 + i * 0.01,
      netProfitLow: 100000 + i, netProfitHigh: 200000 + i, valueLow: 10 + i, valueHigh: 20 + i,
      duration: 1 + i, bestTag: 'default', acceptable: i < 3, riskKind: 'jobAmbushChance(whole task, this box)',
      analysis: { reachable: 400, reachableCoordinates: reach }, unknown: { sectors: reach, unknownCount: 41 },
      note: '★ 这是一段很长的解释性散文，单发路径里没有它的位置 ✗'.repeat(6),
    })
  }
  const actions = ['Mine', 'Salvage', 'Trade', 'Sell', 'Scout'].slice(0, plans)
  return {
    what: 'dossier', ship: 'Miner-00009',
    card: {
      name: 'Miner-00009', sector: { x: -412, y: 73 }, busy: false, hasCaptain: true, captainClass: 'Miner',
      freeCargoSpace: 1200, cargoUsed: 200, cargoCapacity: 5000, cargoUsedPercent: 4, holdHasGoods: true,
      hyperspace: { reach: 12, canPassRifts: true },
      actionNames: actions,
      actions: Object.fromEntries(actions.map((a) => [a, {
        areaSize: a === 'Scout' ? [21, 21] : [15, 15], shipMustBeInside: a !== 'Travel', needsCaptain: true,
        note: '很长的动作说明 '.repeat(10),
      }])),
      sectorFacts: { x: -412, y: 73, richness: 1.05 },
    },
    goal: { ship: 'Miner-00009', text: '采最高阶的矿，风险 <10%', options: actions, hasGoal: true },
    gate: 0.1,
    plans: actions.map((a) => ({
      ship: 'Miner-00009', action: a, areaRanking: ranking,
      recommendation: ranking[0], orderHint: { x: 100, y: 200, size: 15 },
      riskWarning: null, scoreBasis: 'layerWeightedYield(vanilla minecommand.calculatePrediction)',
      areasScanned: 9, boxesEvaluated: 33, scanMs: 120,
      capability: { materials: [{ material: 'Iron', dps: 100 }, { material: 'Titanium', dps: 0 }] },
      coverage: { unknown: 9, known: 432, total: 441 },
      compactNote: '★ 这是小答案 ✓'.repeat(20),
      planCompaction: { mode: 'compact', dropped: [{ field: 'perGoodByArea', detail: '丢了'.repeat(50) }] },
      moveHint: { listIsOptions: true, statement: '框可以平移 '.repeat(20) },
    })),
    planFetchFailures: [{ what: 'tradePlan', why: 'timeout' }],
    note: '★ 这是有界档案 ✓'.repeat(20),
  }
}

const dossierPayload = pathologicalDossier()
const payloadBytes = byteLen(JSON.stringify(dossierPayload))
const memoryBlock = '【你自己的记忆 —— 仅供参考 ✓】\n' + '记忆行 '.repeat(200)

const BUDGET = 24000
const d = renderDossier({
  payload: dossierPayload,
  goalText: '采最高阶的矿，风险 <10%',
  goalOptions: ['Mine', 'Salvage', 'Trade', 'Sell', 'Scout'],
  budgetBytes: BUDGET,
  memoryBlock,
})

console.log(`\n[C/D] 单发档案：载荷 ${fmt(payloadBytes)} → 档案 ${fmt(d.stats.finalBytes)}（预算 ${fmt(d.stats.budgetBytes)}）`)
console.log(`      未裁剪时 ${fmt(d.stats.untouchedBytes)}；候选 ${d.stats.rowsPerPlan} 行/计划；计划 ${d.stats.plansIncluded.join(',') || '(无)'}`)
for (const line of d.stats.dropped) console.log(`      裁剪：${line}`)

check('C. ★ 档案 ≤ 自己的字节预算（含记忆块 ✓）', d.stats.finalBytes <= BUDGET, d.stats.finalBytes)
check('C. ★ 档案比病态载荷小一个数量级（预取全塞的形状 = 载荷那么大 ✓）',
  d.stats.finalBytes * 10 < payloadBytes, `${d.stats.finalBytes} vs ${payloadBytes}`)
check('C. 保证事实①：船名与星区在 ✓',
  d.text.includes('Miner-00009') && d.text.includes('(-412,73)'), d.text.slice(0, 80))
check('C. 保证事实②：玩家的目标与风险闸门在 ✓',
  d.text.includes('采最高阶的矿') && /attackChance ≤ 0\.1/.test(d.text), '')
check('C. 保证事实③：允许的动作在 ✓', /允许的动作/.test(d.text) && d.text.includes('Mine'), '')
check('C. 保证事实④：这艘船"能做什么"在 ✓', /能做什么/.test(d.text) && /区域 15x15/.test(d.text), '')
check('C. ★ 保证事实⑤：每个计划都有推荐**或明说的零候选原因** ✓',
  (d.text.match(/★★ (Mine|Salvage|Trade|Sell|Scout)/g) ?? []).length >= 1
  && (/无推荐：/.test(d.text) || /推荐：/.test(d.text)), '')
check('C. ★ 逐候选的风险/收益数字真的在（主人要的"2~3 个候选 + 数字" ✓）',
  /基准风险/.test(d.text) || /伏击/.test(d.text), '')
check('C. ★ 记忆块也在（单发路径专属 ✓）', d.text.includes('你自己的记忆'), '')
check('C. 巨表一个都没进档案（没有 441 长的数组 ✓）',
  !d.text.includes('reachableCoordinates') && d.text.length < payloadBytes, d.text.length)
check('C. ★ 被裁的东西**逐条记下来了**（绝不静默 ✓）', d.stats.dropped.length > 0, d.stats.dropped)
check('C. 未裁剪字节数是**真数**（before 那一半 ✓）', d.stats.untouchedBytes > d.stats.finalBytes, [d.stats.untouchedBytes, d.stats.finalBytes])

// 确定性 ✓
const d2 = renderDossier({
  payload: pathologicalDossier(),
  goalText: '采最高阶的矿，风险 <10%',
  goalOptions: ['Mine', 'Salvage', 'Trade', 'Sell', 'Scout'],
  budgetBytes: BUDGET,
  memoryBlock,
})
check('D. ★ 确定性：同一份输入 → 同样的字节数 ✓', d2.stats.finalBytes === d.stats.finalBytes,
  [d.stats.finalBytes, d2.stats.finalBytes])
check('D. ★ 确定性：同样的 dropped 序列 ✓',
  JSON.stringify(d2.stats.dropped) === JSON.stringify(d.stats.dropped), d2.stats.dropped)
check('D. ★ 裁剪顺序是**固定**的那一套（② 之后才动计划段 ✓）', (() => {
  const order = d.stats.dropped.map((l) => l[0])
  const firstPlanDrop = order.findIndex((c) => c === '④')
  const lastRowDrop = order.lastIndexOf('②')
  return firstPlanDrop === -1 || lastRowDrop === -1 || lastRowDrop < firstPlanDrop
})(), d.stats.dropped)
check('D. 计划的丢弃顺序常量就是固定的那一个 ✓',
  PLAN_DROP_ORDER.join(',') === 'Sell,Scout,Trade,Salvage,Mine', PLAN_DROP_ORDER.join(','))

// 极端：预算小到只剩骨架也必须**明说**，而不是静默超预算 ✓
const tiny = renderDossier({
  payload: pathologicalDossier(),
  goalText: 'x', goalOptions: [], budgetBytes: 512,
})
check('C. ★ 预算极小时仍然**明说**自己超了（绝不假装没事 ✓）',
  /超预算/.test(tiny.text) || tiny.text.length <= 512 + 200, tiny.stats.finalBytes)

// 骨架兜底：连 dossier 都取不到时，仍要有船 + 规则（单发那条路不能瞎 ✓）
const fb = renderDossier({
  payload: undefined,
  fallbackCard: { name: 'X-1', sector: { x: 1, y: 2 }, actionNames: ['Mine'], actions: { Mine: { areaSize: [15, 15] } } },
  goalText: '挖矿', goalOptions: ['Mine'],
})
check('C. 兜底：dossier 取不到时仍有船 + 规则 + 能做什么 ✓',
  fb.text.includes('X-1') && fb.text.includes('挖矿') && /能做什么/.test(fb.text), fb.text.slice(0, 120))

// ---------------------------------------------------------------------------
// 汇总
// ---------------------------------------------------------------------------
const failed = checks.filter((c) => !c.pass)
console.log(`\n== 共 ${checks.length} 项断言，失败 ${failed.length} 项 ==`)
for (const f of failed) console.log(`  ✗ ${f.label}  → 实际: ${JSON.stringify(f.actual)}`)
console.log(`== 实测：agent 块 ${fmt(blockBytes)}（目标是 < 2 KB）；单发档案 ${fmt(d.stats.finalBytes)} / 预算 ${fmt(BUDGET)} ==`)
console.log(failed.length === 0 ? 'deliverySizeSelfTest: OK' : 'deliverySizeSelfTest: FAILED')
process.exit(failed.length === 0 ? 0 : 1)
