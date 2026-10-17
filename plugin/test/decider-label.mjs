/**
 * decider-label.mjs —— ★★ 「不许冒名」的单元断言（2026-10-17 主人要求 ✓✓）
 *
 * 主人的话：「决策记录与投递块里的"你上一单的结果"必须标明来源
 *   （session / single-shot / rendezvous / fallbackNone），
 *   不得把单发或兜底的结论写成"你（会话）上一单"。」
 *
 * 这里验两件事：
 *   ① `deciderOf(source)` 的**单一映射**（session/asked-owner→session；
 *      single-shot/shadow→single-shot；rendezvous→rendezvous；fallbackNone/none→fallbackNone ✓）；
 *   ② `renderPrevResult(rec)` 渲染出来的「上一单的结果」行**带 [decider] 标签** ✓，
 *      所以块里绝不会把单发/兜底的结论说成"你（会话）上一单" ✗✓。
 *
 * 跑法: node test/decider-label.mjs   （退出码 0 = 全过 ✓）
 */
import { registerHooks } from 'node:module'
import { strict as assert } from 'node:assert'

// 离线跑：DSH 的两个包指到本地桩（与兄弟测试同路 ✓）
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

const { deciderOf, renderPrevResult } = await import('../lib/index.js')

const checks = []
const check = (label, cond, actual) => checks.push({ label, pass: cond === true, actual })

// ---- ① deciderOf 单一映射 ----
check('deciderOf(session) = session', deciderOf('session') === 'session', deciderOf('session'))
check('deciderOf(asked-owner) = session（她在问主人，也是她这一级 ✓）',
  deciderOf('asked-owner') === 'session', deciderOf('asked-owner'))
check('deciderOf(single-shot) = single-shot', deciderOf('single-shot') === 'single-shot', deciderOf('single-shot'))
check('deciderOf(shadow) = single-shot（影子模式采纳的是单发 ✓）',
  deciderOf('shadow') === 'single-shot', deciderOf('shadow'))
check('deciderOf(rendezvous) = rendezvous', deciderOf('rendezvous') === 'rendezvous', deciderOf('rendezvous'))
check('deciderOf(fallbackNone) = fallbackNone', deciderOf('fallbackNone') === 'fallbackNone', deciderOf('fallbackNone'))
check('deciderOf(none) = fallbackNone', deciderOf('none') === 'fallbackNone', deciderOf('none'))
check('deciderOf(undefined) = undefined', deciderOf(undefined) === undefined, deciderOf(undefined))

// ---- ② renderPrevResult 带 [decider] 标签 ----
const base = { at: '', ship: 'X', goalText: '', goalOptions: [], ok: true }

const singleOk = renderPrevResult({
  ...base, decider: 'single-shot',
  answer: { action: 'Mine', params: { x: 1, y: 2 } },
  receipt: { at: '', accepted: true, executed: true },
})
check('renderPrevResult: 单发成功单带 [single-shot] 标签 ✓',
  singleOk === '[single-shot] Mine @(1,2)：成功 ✓', singleOk)

const sessionNone = renderPrevResult({
  ...base, decider: 'session',
  answer: { action: 'None', params: {} },
  receipt: { at: '', accepted: false, executed: false, error: 'action=None（本轮不下单 ✓）' },
})
check('renderPrevResult: 会话待命单带 [session] 标签 ✓',
  sessionNone !== undefined && sessionNone.startsWith('[session] None'), sessionNone)

const fallbackNone = renderPrevResult({
  ...base, decider: 'fallbackNone',
  answer: { action: 'None', params: {} },
  receipt: { at: '', accepted: false, executed: false, error: 'action=None（本轮不下单 ✓）' },
})
check('renderPrevResult: 兜底不下单带 [fallbackNone] 标签 ✓',
  fallbackNone !== undefined && fallbackNone.startsWith('[fallbackNone] None'), fallbackNone)

// 旧记录没有 decider 字段 → 按 source 反推 ✓
const fromSource = renderPrevResult({
  ...base, source: 'single-shot', answer: { action: 'Scout', params: { x: 5, y: 6 } },
  receipt: { at: '', accepted: true, executed: true },
})
check('renderPrevResult: 旧记录无 decider 时按 source 反推 [single-shot] ✓',
  fromSource === '[single-shot] Scout @(5,6)：成功 ✓', fromSource)

// ---- 汇总 ----
const failed = checks.filter((c) => !c.pass)
for (const c of checks) {
  console.log(`${c.pass ? '  ✓' : '  ✗'} ${c.label}${c.pass ? '' : `  ← 实际 ${JSON.stringify(c.actual)}`}`)
}
console.log(`\n== 共 ${checks.length} 项断言，失败 ${failed.length} 项 ==`)
console.log(failed.length === 0 ? 'deciderLabel: OK' : 'deciderLabel: FAILED')
process.exit(failed.length === 0 ? 0 : 1)
