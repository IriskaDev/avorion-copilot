/**
 * commander-dispatch.mjs —— 对**生产模块** `src/dispatch.ts` 的离线测试 ✓
 *
 * 与设计 pass 的原型（`commander-dispatch-proto.mjs`，7/7 ✓）的区别 ✗✓：
 *   原型验的是"**思路**"（一个自包含的模型 ✓）；本文件验的是**真正要上线的那份代码** ✓
 *   （`lib/dispatch.js` + `lib/task.js` + `lib/commander.js` ✓）。
 *
 * 覆盖的失效模式（与原型同源 ✓，另加本次新增的闸门 ✓）：
 *   1. 会话健康              → 采纳会话答案、**不碰单发** ✓
 *   2. 主人在聊天（会话忙）  → 不插队 → 单发 ✓（舰队照样有决策 ✓）
 *   3. 会话挂死              → 硬闸内 cancel() + 放弃它 → 单发 ✓，且**不超总预算** ✓
 *   4. 两条路都废            → action=None ✓（**绝不悬着** ✓）
 *   5. 任务号对不上          → 拒绝采纳 ✓ → 单发 ✓（**绝不把别船的答案用在它身上** ✓）
 *   6. 影子模式（Phase B）   → 会话答了**也由单发决定** ✓，但答案被并排记下来 ✓
 *   7. 舰队级串行            → 同一会话同一刻只有一条在飞 ✓（抢不到直接落单发 ✓）
 *   8. 单发**硬期限**        → 今天没有这道闸 ✗ → 超时就 action=None，且总耗时受控 ✓
 *   9. 投递会话选择            → 未指定 = 与今天逐字相同 ✓；指定/清除/落盘/租约 ✓
 *
 *   node test/commander-dispatch.mjs
 */
import { strict as assert } from 'node:assert'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'

const { dispatchDecision, BUDGETS } = await import('../lib/dispatch.js')
const { renderTaskBlock, validateAnswer, makeTaskId } = await import('../lib/task.js')
const commander = await import('../lib/commander.js')

// ---------------------------------------------------------------------------
// 桩：一个按剧本走的投递会话会话（面与 dsh-agent 的 Agent 一致 ✓）
// ---------------------------------------------------------------------------

/** 一"轮"的剧本：按顺序吐这几条 assistant 文本，然后 turn/end ✓ */
function makeAgent({ id = 'session-cmdr', script = [], turnMs = 5, hang = false, busy = false } = {}) {
  const listeners = new Set()
  let idleWaiters = []
  let rounds = 0
  const inbox = []
  const goIdle = () => {
    agent.status = 'idle'
    const w = idleWaiters
    idleWaiters = []
    for (const r of w) r()
  }
  const agent = {
    id,
    status: busy ? 'running' : 'idle',
    /** 收到的任务块（测试要能检查契约写了什么 ✓） */
    inbox,
    cancelled: 0,
    followup(message) {
      rounds += 1
      inbox.push(message)
      agent.status = 'running'
      if (hang) return                     // ★ 永不结束的一轮（要掐的那种 ✓）
      setTimeout(() => {
        for (const text of script) {
          for (const fn of [...listeners]) {
            fn({ type: 'assistant/message', turn: rounds, step: 1, message: { role: 'assistant', content: [{ type: 'text', text }] } })
          }
        }
        for (const fn of [...listeners]) fn({ type: 'turn/end', turn: rounds, reason: { kind: 'stop' } })
        goIdle()
      }, turnMs)
    },
    whenIdle() {
      if (agent.status === 'idle') return Promise.resolve()
      return new Promise((resolve) => { idleWaiters.push(resolve) })
    },
    cancel(cause) { agent.cancelled += 1; agent.cancelCause = cause; goIdle() },
    /** 真实现是 `ctx.on('session/event', …)` 再按 sessionId 筛 ✓ —— 这里按会话筛好再给 ✓ */
    onEvent(fn) { listeners.add(fn); return () => listeners.delete(fn) },
  }
  return agent
}

/** 真实现是 `ctx.agents`（get/list ✓） */
function makeRegistry(agents) {
  return { get: (id) => agents.find((a) => a.id === id), list: () => [...agents] }
}

/** 真实现 = index.ts 注入的 `agent.followup(createUserMessage({...}))` ✓ */
const followup = (agent, block) => agent.followup({ id: 'msg', role: 'user', content: [{ type: 'text', text: block }] })

/** 真实现 = index.ts 里的 `askModel`（可脚本化：字符串 / 函数 / 挂住 ✓） */
function makeSingleShot(reply, { ms = 5, fail = null, hang = false } = {}) {
  const calls = []
  return {
    get calls() { return calls.length },
    hints: calls,
    async run(hint) {
      calls.push(hint ?? null)
      if (hang) return new Promise(() => {})
      await new Promise((r) => setTimeout(r, ms))
      const text = typeof reply === 'function' ? reply(hint, calls.length) : reply
      if (fail !== null) return { failure: fail, text: '' }
      return { text, truncated: false }
    },
  }
}

/** 真实现 = `ctx.on('session/event', …)`（未打 scope 标记的监听者能收到所有会话 ✓） */
const subscribeTo = (agents) => (sessionId, fn) => {
  const a = agents.find((x) => x.id === sessionId)
  if (a === undefined) return () => {}
  return a.onEvent(fn)
}

const REQ = {
  taskId: 't-0001',
  ship: 'Miner-00002',
  goalText: '西北方向采矿',
  goalOptions: ['Mine'],
  card: { sector: { x: 42, y: -8 }, busy: false },
  planText: '{"recommendation":{"area":{"x":30,"y":-12}}}',
  deadlineHintSec: 20,
}
const ALLOWED = ['Mine', 'Salvage', 'Trade', 'Travel', 'Sell', 'Scout']

/** 压缩的时间预算（唯一变量是等待时长 ✓；代码路径与生产逐字相同 ✓） */
// ★ 2026-10-18：`mergeWindowMs` = 合并收集窗口（A 项 ✓）—— 测试里压到 30ms：
//   同一批同时来的几条仍然会被收进**一个块** ✓，但不必每条都干等 800ms ✓。
const FAST = { sessionDeadlineMs: 1500, queueReserveMs: 100, commitReserveMs: 50, singleShotTimeoutMs: 400, retryOnceMs: 300, mergeWindowMs: 30 }

const results = []
async function test(name, fn) {
  const logs = []
  try {
    const detail = await fn((l) => logs.push(l))
    results.push({ name, ok: true, detail })
  } catch (error) {
    results.push({ name, ok: false, detail: error?.stack ?? String(error) })
  }
  console.log(`\n--- ${name} ---`)
  for (const l of logs) console.log(l)
  const r = results[results.length - 1]
  console.log(r.ok ? '  PASS' : `  FAIL\n${r.detail}`)
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

// ---------------------------------------------------------------------------
// 1..6：阶梯的失效模式（与原型一一对应 ✓）
// ---------------------------------------------------------------------------

await test('① 会话健康：采纳会话答案，单发一次都不跑', async (log) => {
  const agent = makeAgent({
    script: [
      '我先查一下候选框……',
      'action=Mine\nx=30\ny=-12\nsize=15\nduration=1\ntask=t-0001\nreason=30,-12 的铁矿加权产量最高',
    ],
  })
  const single = makeSingleShot('action=None\ntask=t-0001')
  const out = await dispatchDecision({
    registry: makeRegistry([agent]), commanderId: agent.id, subscribe: subscribeTo([agent]),
    followup, singleShot: single.run, allowedActions: ALLOWED, budgets: FAST, log,
  }, REQ)
  console.log('  result:', JSON.stringify(out))
  assert.equal(out.source, 'session')
  assert.equal(out.action, 'Mine')
  assert.equal(out.params.x, 30)
  assert.equal(out.params.duration, 1)
  assert.equal(single.calls, 0, '会话答成了就不许再跑单发 ✓')
  assert.equal(out.session.steps, 2, '她用了工具 → 这一轮应当有 2 条 assistant 文本 ✓')
  assert.match(agent.inbox[0].content[0].text, /<fleet_task id="t-0001" ship="Miner-00002"/)
  return '会话的答案是唯一来源，单发没被碰'
})

await test('② 主人在聊天（会话忙）：不插队 → 兜底 None（★ 不许单发替它拍板 ✗）', async (log) => {
  const agent = makeAgent({ busy: true, script: [] })
  const single = makeSingleShot('action=Salvage\nx=8\ny=8\nsize=15\nduration=2\ntask=t-0001')
  const out = await dispatchDecision({
    registry: makeRegistry([agent]), commanderId: agent.id, subscribe: subscribeTo([agent]),
    followup, singleShot: single.run, allowedActions: ALLOWED, budgets: FAST, log,
  }, REQ)
  console.log('  result:', JSON.stringify(out))
  assert.equal(out.source, 'fallbackNone')
  assert.equal(out.action, 'None')
  assert.equal(single.calls, 0, '★ 指挥官会话在线但忙 → 单发**一次都不许跑** ✗（兜底不许下单 ✓）')
  assert.equal(agent.inbox.length, 0, '忙会话**不该**收到投递（不插队 ✓）')
  return '主人在聊天：不插队、也不让单发替她拍板'
})

await test('③ ★ 会话在线但超时（挂死）：cancel + 兜底 None，单发零次调用（主人铁律 ✓）', async (log) => {
  const agent = makeAgent({ hang: true })
  const single = makeSingleShot('action=Mine\nx=1\ny=1\ntask=t-0001')
  const t0 = Date.now()
  const out = await dispatchDecision({
    registry: makeRegistry([agent]), commanderId: agent.id, subscribe: subscribeTo([agent]),
    followup, singleShot: single.run, allowedActions: ALLOWED, budgets: FAST, log,
  }, REQ)
  const took = Date.now() - t0
  console.log(`  result: ${JSON.stringify(out)}   took ${took}ms   singleShotCalls=${single.calls}`)
  assert.equal(out.action, 'None')
  assert.equal(out.source, 'fallbackNone')
  assert.equal(single.calls, 0, '★ 会话在线但超时 → **单发一次都不许跑**（兜底不许下单 ✗✓）')
  assert.equal(agent.cancelled, 1, '挂死的一轮必须被 cancel ✓')
  // ★ cause 必须是宿主认得的 kind（user | parent | disposed | hook ✓）。
  //   原先传的是 'timeout' ✗ —— 宿主的 abortedCancelCause 会落到 assertNever 抛错，
  //   那一轮的 turn/end 被写成 reason: null ✗，客户端回放轨迹时 `reason.kind`
  //   直接 TypeError → 整个会话界面空白 ✗✗（2026-10-17 实机事故）。
  //   "插件/钩子让这一轮停下"的官方语义就是 hook ✓，所以断言跟着代码走 ✓。
  assert.equal(agent.cancelCause.kind, 'hook')
  assert.equal(agent.inbox.length, 1, '★ 失败**绝不重递** ✓（同一艘船只递一次 ✓）')
  assert.ok(took < FAST.sessionDeadlineMs + FAST.singleShotTimeoutMs + 500, `耗时失控: ${took}ms`)
  return `掐掉挂死的一轮，兜底 None（单发零次），仍在 ${took}ms 内给出决策`
})

await test('④ 会话没答成（live 模式）→ 兜底 None，不落单发、绝不悬着', async (log) => {
  const agent = makeAgent({ script: ['嗯嗯~本鱼今天不想干活。'] })
  const single = makeSingleShot('', { fail: null })
  const t0 = Date.now()
  const out = await dispatchDecision({
    registry: makeRegistry([agent]), commanderId: agent.id, subscribe: subscribeTo([agent]),
    followup, singleShot: single.run, allowedActions: ALLOWED, budgets: FAST, log,
  }, REQ)
  console.log(`  result: ${JSON.stringify(out)}   took ${Date.now() - t0}ms`)
  assert.equal(out.action, 'None')
  assert.equal(out.source, 'fallbackNone')
  assert.equal(single.calls, 0, '★ 会话在线但没答成 → 不落单发（兜底不许下单 ✗）')
  assert.ok((out.reason ?? '').length > 0, '必须写清为什么没有决策 ✓')
  return '梯子自己终止，失败是"明说的 None"而不是挂住'
})

await test('⑤ 任务号对不上：拒绝采纳 → 兜底 None（绝不把别船的答案用在它身上）', async (log) => {
  const agent = makeAgent({ script: ['action=Mine\nx=99\ny=99\ntask=t-9999'] })
  const single = makeSingleShot('action=Mine\nx=30\ny=-12\ntask=t-0001')
  const out = await dispatchDecision({
    registry: makeRegistry([agent]), commanderId: agent.id, subscribe: subscribeTo([agent]),
    followup, singleShot: single.run, allowedActions: ALLOWED, budgets: FAST, log,
  }, REQ)
  console.log('  result:', JSON.stringify(out))
  assert.equal(out.source, 'fallbackNone')
  assert.equal(out.action, 'None')
  assert.equal(single.calls, 0, '★ 答错船 → 不采纳、也不让单发替它拍板（兜底不许下单 ✗）')
  assert.equal(out.session.code, 'TASK_MISMATCH')
  return '回显写错 → 判 TASK_MISMATCH 并兜底 None'
})

await test('⑥ 会话在问主人：显式延期（ASKED_OWNER），不派单、不落单发', async (log) => {
  const agent = makeAgent({ script: ['主人，这艘船没有护航，伏击概率 34%，要我先派护航再出海吗？'] })
  const single = makeSingleShot('action=Mine\nx=1\ny=1\ntask=t-0001')
  const out = await dispatchDecision({
    registry: makeRegistry([agent]), commanderId: agent.id, subscribe: subscribeTo([agent]),
    followup, singleShot: single.run, allowedActions: ALLOWED, budgets: FAST, log,
  }, REQ)
  console.log('  result:', JSON.stringify(out), 'singleShotCalls=' + single.calls)
  assert.equal(out.source, 'asked-owner')
  assert.equal(out.action, 'None')
  assert.match(out.reason ?? '', /投递会话在问主人/)
  assert.equal(single.calls, 0, '人在环里**不是**失败 → 不该偷偷落回单发 ✓')
  return '人在环里 = 明确的延期状态，不是悬着的 promise'
})

// ---------------------------------------------------------------------------
// 7..9：本次新增的闸门
// ---------------------------------------------------------------------------

await test('⑦ 影子模式（Phase B）：会话答了也**由单发决定**，答案并排记下', async (log) => {
  const agent = makeAgent({ script: ['action=Salvage\nx=8\ny=8\nsize=15\ntask=t-0001'] })
  const single = makeSingleShot('action=Mine\nx=30\ny=-12\ntask=t-0001')
  const out = await dispatchDecision({
    registry: makeRegistry([agent]), commanderId: agent.id, subscribe: subscribeTo([agent]),
    followup, singleShot: single.run, allowedActions: ALLOWED, mode: 'shadow', budgets: FAST, log,
  }, REQ)
  console.log('  result:', JSON.stringify(out))
  assert.equal(out.source, 'shadow', 'source 必须说真话：这一单是单发定的 ✓')
  assert.equal(out.action, 'Mine', '影子模式**绝不许**采纳会话的答案 ✗')
  assert.equal(single.calls, 1, '影子模式仍然要跑单发 ✓')
  assert.equal(out.session.answered, true, '会话的答案必须被记下来 ✓')
  assert.equal(out.session.answer.action, 'Salvage')
  assert.equal(out.agreement, false, '并排比较：两者不一致 ✓（这正是主人要看的数 ✓）')
  return '零风险观测：能对比两边答案，实际下单行为一个字节都没变'
})

await test('⑦b 影子模式下没有指定会话：与今天逐字相同（单发一次，不投递）', async (log) => {
  const single = makeSingleShot('action=Mine\nx=1\ny=1\ntask=t-0001')
  const out = await dispatchDecision({
    registry: makeRegistry([]), subscribe: () => () => {},
    followup, singleShot: single.run, allowedActions: ALLOWED, mode: 'shadow', budgets: FAST, log,
  }, REQ)
  console.log('  result:', JSON.stringify(out))
  assert.equal(out.source, 'single-shot')
  assert.equal(single.calls, 1)
  return '清除投递会话 = 立刻回到今天的行为（这就是回滚开关 ✓）'
})

await test('⑧ 舰队级串行：同一会话同一刻只有一条在飞 → 第二条**排队等下一轮**（绝不丢 ✗）', async (log) => {
  const agent = makeAgent({ script: ['action=Mine\nx=1\ny=1\ntask=A'], turnMs: 200 })
  const single = makeSingleShot('action=Salvage\nx=2\ny=2\ntask=B')
  let held
  let maxInFlight = 0
  let inFlight = 0
  // ★ 真的量"同一刻有几条在飞" ✓（不是靠猜 ✓）：followup 时 +1，turn/end 时 -1 ✓
  const origFollowup = agent.followup.bind(agent)
  agent.followup = (msg) => { inFlight += 1; maxInFlight = Math.max(maxInFlight, inFlight); origFollowup(msg) }
  agent.onEvent((e) => { if (e.type === 'turn/end') inFlight = Math.max(0, inFlight - 1) })
  const lock = {
    tryClaim() {
      if (held !== undefined) return undefined
      let released = false
      held = () => { released = true; held = undefined }
      return () => { if (!released) held() }
    },
  }
  const deps = {
    registry: makeRegistry([agent]), commanderId: agent.id, subscribe: subscribeTo([agent]),
    followup, singleShot: single.run, allowedActions: ALLOWED, budgets: FAST, lock, log,
  }
  const first = dispatchDecision({ ...deps, log: () => {} }, { ...REQ, taskId: 'A' })
  await sleep(40)                                     // 第一条真的递出去了、正占着会话 ✓
  // ★ 2026-10-18（A 项）：**不再**"第二条立刻被判 SESSION_BUSY_ELSEWHERE + None" ✗✓ ——
  //   那条路就是主人说的「会漏」✓。现在它**进合并队列**，这一轮结束后**立刻**投下一轮 ✓。
  assert.equal(agent.inbox.length, 1, '第一条已经递出去了（合并窗口 30ms + 投递 ✓）')
  agent.status = 'idle'
  const second = dispatchDecision({ ...deps, log: () => {} }, { ...REQ, taskId: 'B', ship: 'Miner-00003' })
  const done = await first
  const secondOut = await second
  console.log('  second:', JSON.stringify(secondOut))
  console.log('  first :', JSON.stringify(done))
  assert.equal(done.source, 'session', '第一条照常由会话定 ✓')
  assert.equal(agent.inbox.length, 2, '★ 第二条**也真的投出去了**（只是等下一轮 ✓ —— 绝不静默丢掉 ✗）')
  assert.equal(maxInFlight, 1, '★ 同一刻**从来只有一条**在飞（锁 + 队列串行 ✓）')
  assert.equal(single.calls, 0, '★ 会话在线 → 绝不落单发（兜底不许下单 ✗）')
  // 她回显的是 task=A（这轮她答的是上一单的号）→ 第二条**正确地**被判 TASK_MISMATCH ✓
  //   ★ 重点不是"她答错"，而是**这艘船拿到了自己的结论**（不是被静默判 None ✓）
  assert.equal(secondOut.session?.code, 'TASK_MISMATCH', '★ 别船答案不许混用（判 TASK_MISMATCH ✓）')
  return '一个会话同一刻只有一条任务；第二条排队等下一轮、绝不丢（TAKEOVER.md 铁律 ✓）'
})

await test('⑧b 会话**正忙**时：连锁都不碰，兜底 None（绝不插进主人的聊天 ✗）', async (log) => {
  const agent = makeAgent({ busy: true, script: ['action=Mine\nx=1\ny=1\ntask=A'] })
  let claimed = 0
  const single = makeSingleShot('action=Salvage\nx=2\ny=2\ntask=B')
  const out = await dispatchDecision({
    registry: makeRegistry([agent]), commanderId: agent.id, subscribe: subscribeTo([agent]),
    followup, singleShot: single.run, allowedActions: ALLOWED, budgets: FAST,
    lock: { tryClaim() { claimed += 1; return () => {} } }, log,
  }, REQ)
  console.log('  result:', JSON.stringify(out))
  assert.equal(out.source, 'fallbackNone')
  assert.equal(single.calls, 0, '★ 忙会话在线 → 不落单发（兜底不许下单 ✗）')
  assert.equal(claimed, 0, '★ 忙会话压根不该走到"投递"这一步 ✓（主人的聊天优先 ✓）')
  assert.equal(agent.inbox.length, 0, '绝不许往主人正在聊的会话里塞任务 ✗')
  assert.equal(out.session, undefined, '连"会话那一级"都没开始 ✓')
  return '主人的对话优先：忙就完全不打扰、也不让单发替她拍板'
})

await test('⑨ 单发硬期限：挂住的单发也能被闸住（今天没有这道闸 ✗）', async (log) => {
  const single = makeSingleShot('', { hang: true })
  const t0 = Date.now()
  const out = await dispatchDecision({
    registry: makeRegistry([]), subscribe: () => () => {},
    followup, singleShot: single.run, allowedActions: ALLOWED, budgets: FAST, log,
  }, REQ)
  const took = Date.now() - t0
  console.log(`  result: ${JSON.stringify(out)}   took ${took}ms`)
  assert.equal(out.action, 'None')
  assert.equal(out.source, 'none')
  assert.match(out.reason ?? '', /硬期限|没有可用/)
  assert.ok(took < FAST.singleShotTimeoutMs + 400, `单发硬期限没生效: ${took}ms`)
  return `单发超时被闸住（${took}ms 就给了 None，而不是永远等下去）`
})

// ---------------------------------------------------------------------------
// 10：任务块 / 校验器本身
// ---------------------------------------------------------------------------

await test('⑩ 任务块契约 + 校验器：回显、允许集合、问题、便宜字段', async (log) => {
  const block = renderTaskBlock(REQ)
  assert.match(block, /^<fleet_task id="t-0001" ship="Miner-00002" deadline_hint="20s">/)
  assert.match(block, /<\/fleet_task>$/)
  assert.match(block, /task=t-0001/)
  assert.match(block, /第一行\*\*请直接写结论行/, '★ 结论行必须在最前（便于解析 ✓）')
  assert.doesNotMatch(block, /额度|想太久|烧光|节省|时间紧|别犹豫/, '★ 块里绝不含"额度/想太久"类施压措辞 ✗')
  assert.match(block, /不是主人在说话/, '★ 必须说清"这条是舰队任务、不是主人说话" ✓')
  assert.match(block, /唯一凭据/, '★ 回显 task 的意义要写清 ✓')
  assert.match(block, /照常\*\*跟主人聊天/, '★ 任务块外的闲聊不受影响（同一会话两用 ✓）')
  log('  任务块头尾、回显要求、"这不是主人说话"、以及"块外照样聊天"都在 ✓')

  // 合格 ✓
  const good = validateAnswer('action=Mine\nx=30\ny=-12\ntask=t-0001\nreason=好', 't-0001', ['Mine'])
  assert.equal(good.ok, true)
  assert.equal(good.echoed, true)
  assert.equal(good.answer.params.x, 30)

  // 没有回显 → **仍然采纳** ✓（她是会话，不是背格式的机器人 ✓）
  const noEcho = validateAnswer('action=Mine\nx=1\ny=1', 't-0001', ['Mine'])
  assert.equal(noEcho.ok, true)
  assert.equal(noEcho.echoed, false)
  log('  没回显 task → 采纳但标记 echoed=false ✓')

  // 回显错 → 拒 ✓
  const bad = validateAnswer('action=Mine\ntask=t-2', 't-0001', ['Mine'])
  assert.equal(bad.ok, false)
  assert.equal(bad.code, 'TASK_MISMATCH')

  // 动作不合法 → 拒 ✓（None 永远合法 ✓）
  const disallowed = validateAnswer('action=Trade\ntask=t-0001', 't-0001', ['Mine'])
  assert.equal(disallowed.ok, false)
  assert.equal(disallowed.code, 'BAD_ACTION')
  assert.equal(validateAnswer('action=None\ntask=t-0001', 't-0001', ['Mine']).ok, true)

  // 空 / 无动作行 ✓
  assert.equal(validateAnswer('', 't-0001', ['Mine']).code, 'EMPTY_REPLY')
  assert.equal(validateAnswer('我想了想，觉得还是算了。', 't-0001', ['Mine']).code, 'NO_ACTION_LINE')

  // 问主人（question= 与问号两种写法 ✓）
  assert.equal(validateAnswer('question=要不要派护航？', 't-0001', ['Mine']).code, 'ASKED_OWNER')
  assert.equal(validateAnswer('要我先派护航再出海吗？', 't-0001', ['Mine']).code, 'ASKED_OWNER')

  // 其它字段透传 ✓（Trade 形状 / 卖货 / 护航清洗 / safeMode ✓）
  const rich = validateAnswer(
    'action=Trade\ntask=t-0001\nshape=29x11\ndeposit=50000\ngoodName=Drill\n' +
    'goodsToSell=all\nescorts=A-1, 无, A-2\nsafeMode=是\nreason=x',
    't-0001', ['Trade'])
  assert.equal(rich.ok, true)
  assert.equal(rich.answer.params.sizeX, 29)
  assert.equal(rich.answer.params.sizeY, 11)
  assert.equal(rich.answer.params.deposit, 50000)
  assert.equal(rich.answer.params.goodName, 'Drill')
  assert.equal(rich.answer.params.goodsToSell, undefined, "'all' **不回传** ✓（游戏侧默认全卖 ✓）")
  assert.deepEqual(rich.answer.params.escorts, ['A-1', 'A-2'], '"无" 不该被当成船名 ✓')
  assert.equal(rich.answer.params.safeMode, true)
  log('  富字段透传（形状/预付金/选货/护航/安全模式）都对 ✓')

  assert.match(makeTaskId(), /^t-[0-9a-f]{8}$/)
  return '任务块与校验器的全部契约断言通过'
})

// ---------------------------------------------------------------------------
// 11：投递会话的选择与租约（commander.ts）
// ---------------------------------------------------------------------------

await test('⑪ 投递会话选择：未指定=今天 / 指定 / 落盘 / 清除 / 租约', async (log) => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'copilot-cmdr-'))
  const file = path.join(dir, 'commander.json')
  commander.resetCommanderCache()

  // 没指定 → undefined（调用方据此回到单发 ✓）
  assert.equal(commander.getState(file).session, null)
  assert.equal(commander.getCommanderSessionId(), undefined)   // 默认文件也是"没指定" ✓
  log('  未指定 → 单发路径（与今天逐字相同 ✓）')

  commander.setCommanderSession('session-A', { file })
  assert.equal(commander.getState(file).session, 'session-A')
  assert.equal(JSON.parse(fs.readFileSync(file, 'utf8')).session, 'session-A')
  log('  指定 → 已落盘 ✓')

  // 换会话 → 旧租约丢掉 ✓；同会话再指定 → 幂等、租约保留 ✓
  commander.renewLease({ file, now: 1000, leaseMs: 5000 })
  assert.equal(commander.getState(file).leasedUntil, 6000)
  commander.setCommanderSession('session-A', { file })
  assert.equal(commander.getState(file).leasedUntil, 6000, '同一会话重复指定应当幂等 ✓')
  commander.setCommanderSession('session-B', { file })
  assert.equal(commander.getState(file).leasedUntil, null, '换会话必须丢掉旧租约 ✓')
  log('  重复指定幂等 / 换会话清租约 ✓')

  // 租约新鲜度（只用于示警 ✓，不是投递闸门 ✓）
  commander.renewLease({ file, now: 1000, leaseMs: 5000 })
  assert.equal(commander.isLeaseFresh({ now: 2000 }), true)
  assert.equal(commander.isLeaseFresh({ now: 9000 }), false)
  log('  租约会在租期内新鲜、过期后不新鲜 ✓')

  // 空串 = 撤销 ✓（与 cosplay 的 activeRole 同款语义 ✓）
  commander.setCommanderSession('   ', { file })
  assert.equal(commander.getState(file).session, null)
  assert.equal(JSON.parse(fs.readFileSync(file, 'utf8')).session, null)
  log('  空串/空白 = 撤销 ✓')

  // 读盘：进程"重启"后仍然认得同一个会话 id ✓
  commander.resetCommanderCache()
  commander.setCommanderSession('session-A', { file })
  commander.resetCommanderCache()
  assert.equal(commander.getState(file).session, 'session-A')
  log('  读盘：重启后记得住 ✓')

  // 坏文件绝不能拖垮舰队 ✗
  fs.writeFileSync(file, '{ this is not json', 'utf8')
  commander.resetCommanderCache()
  assert.equal(commander.getState(file).session, null)
  assert.equal(commander.getCommanderSessionId() === undefined, true)
  fs.rmSync(dir, { recursive: true, force: true })
  commander.resetCommanderCache()
  return '选择的显式化、持久化、撤销与坏文件兜底都对'
})

// ---------------------------------------------------------------------------
// 12：会话路径的"再给一次机会"（只此一次 ✓）
// ---------------------------------------------------------------------------

await test('⑫ 会话两次都没有动作行 → 只递两次（绝不重递第三次 ✗）→ 兜底 None', async (log) => {
  const agent = makeAgent({ script: ['嗯……本鱼在想想。'] })
  const single = makeSingleShot('action=Mine\nx=5\ny=5\ntask=t-0001')
  const out = await dispatchDecision({
    registry: makeRegistry([agent]), commanderId: agent.id, subscribe: subscribeTo([agent]),
    followup, singleShot: single.run, allowedActions: ALLOWED, retrySessionOnce: true,
    budgets: { ...FAST, sessionDeadlineMs: 5000, retryOnceMs: 800 }, log,
  }, REQ)
  console.log('  result:', JSON.stringify(out))
  assert.equal(out.session.code, 'NO_ACTION_LINE')
  assert.equal(agent.inbox.length, 2, '★ 只能递两次（第一次 + 一次重试）✗ 绝不许无限重递 ✓')
  assert.equal(out.source, 'fallbackNone')
  assert.equal(single.calls, 0, '★ 会话没答成 → 不落单发（兜底不许下单 ✗）')
  return '重试严格只有一次，且落在兜底 None 上'
})

await test('⑬ 默认预算就是设计书定的那几个数（防止有人悄悄改小 ✗）', async () => {
  assert.equal(BUDGETS.sessionDeadlineMs, 20_000)
  assert.equal(BUDGETS.queueReserveMs, 3_000)
  assert.equal(BUDGETS.commitReserveMs, 1_000)
  assert.equal(BUDGETS.singleShotTimeoutMs, 15_000)
  // 游戏侧的 decide 超时是 90s（data/scripts/net/fleet.lua:30 ✓）——
  // ② 之后还有计划的取数与下单，所以这里必须留足余量 ✓。
  return `硬闸合计 ${BUDGETS.sessionDeadlineMs + BUDGETS.singleShotTimeoutMs}ms，远在游戏侧 90s 之内 ✓`
})

await test('⑭ ★ 唯一性：把第二个会话设为指挥官 → 第一个**立刻**不再是目标（原子替换）', async (log) => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'copilot-cmdr2-'))
  const file = path.join(dir, 'commander.json')
  commander.resetCommanderCache()

  commander.setCommanderSession('session-A', { file })
  assert.equal(commander.getCommanderSessionId(), 'session-A')
  commander.setCommanderSession('session-B', { file })
  assert.equal(commander.getCommanderSessionId(), 'session-B', '★ 只能有一个：新的立刻取代旧的 ✓')
  assert.equal(JSON.parse(fs.readFileSync(file, 'utf8')).session, 'session-B',
    '★ 盘上也只有一个 id ✓ —— 没有任何地方还记着 A ✓')
  log('  A → B：只有一个 id 被保存（A 立刻不在投递路径上 ✓）')

  // ★ 交付只去被指定的那个会话 ✓（真实后果：A 再也收不到任务 ✓）
  const a = makeAgent({ id: 'session-A', script: ['action=Mine\nx=1\ny=1\ntask=t'] })
  const b = makeAgent({ id: 'session-B', script: ['action=Salvage\nx=9\ny=9\ntask=t-0001'] })
  const single = makeSingleShot('action=Trade\ngoodName=Drill\ntask=t-0001')
  const out = await dispatchDecision({
    registry: makeRegistry([a, b]), commanderId: commander.getCommanderSessionId(),
    subscribe: subscribeTo([a, b]), followup, singleShot: single.run,
    allowedActions: ALLOWED, budgets: FAST, log,
  }, REQ)
  console.log('  result:', JSON.stringify(out))
  assert.equal(out.source, 'session')
  assert.equal(out.action, 'Salvage', '答案必须来自 B（当前指挥官 ✓）')
  assert.equal(a.inbox.length, 0, '★ A 被顶掉之后**一个任务都不该收到** ✗✓')
  assert.equal(b.inbox.length, 1)
  log('  投递只去 B；A 的收件箱空着 ✓')

  // 关掉之后：回到单发（舰队照样有决策 ✓）
  commander.setCommanderSession(null, { file })
  const single2 = makeSingleShot('action=Mine\nx=3\ny=3\ntask=t-0001')
  const out2 = await dispatchDecision({
    registry: makeRegistry([a, b]), commanderId: commander.getCommanderSessionId(),
    subscribe: subscribeTo([a, b]), followup, singleShot: single2.run,
    allowedActions: ALLOWED, budgets: FAST, log,
  }, REQ)
  console.log('  after clear:', JSON.stringify(out2))
  assert.equal(out2.source, 'single-shot', '★ 没有指挥官 = 回落到单发（**决策绝不静默停止** ✓）')
  assert.equal(b.inbox.length, 1, '关掉之后两边都不该再收到任务 ✓')
  fs.rmSync(dir, { recursive: true, force: true })
  commander.resetCommanderCache()
  return '一次只有一个指挥官；换人立刻生效；关掉就回落到单发'
})

console.log(`\n${'='.repeat(72)}\n## commander dispatch result\n${'='.repeat(72)}`)
let failed = 0
for (const r of results) {
  console.log(`${r.ok ? '  OK  ' : '  FAIL'} ${r.name}`)
  if (!r.ok) { failed++; console.log(`        ${String(r.detail).split('\n')[0]}`) }
}
console.log(`\n${results.length - failed}/${results.length} passed`)
console.log('VERDICT: ' + (failed === 0
  ? '阶梯在每种失效模式下都保住了"舰队有决策"，且每一级都有自己的硬闸。'
  : '阶梯有洞 —— 看上面的失败项。'))
process.exit(failed === 0 ? 0 : 1)
