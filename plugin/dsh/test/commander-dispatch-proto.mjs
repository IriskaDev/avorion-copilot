/**
 * commander-dispatch-proto.mjs -- offline proof-of-concept for the PROPOSED
 * architecture: the plugin delivers each fleet decision as a TASK BLOCK into a
 * live DSH commander session, and the session answers with the same
 * machine-checkable action lines we parse today.
 *
 * WHAT IS REAL HERE
 *   * the task-block format (facts + required answer lines + taskId echo);
 *   * the answer parser (the same field: value grammar the plugin already uses);
 *   * the DELIVERY LADDER and every timeout / budget number;
 *   * the "never stall the fleet" property, asserted by tests.
 *
 * WHAT IS STUBBED HERE (and exactly which real API replaces it)
 *   * `Agent`        -> a real one comes from `ctx.agents.get(sessionId)`;
 *                       the stub implements followup/inject/status/inbox/whenIdle
 *                       with the semantics documented on those methods
 *                       (dsh-agent/lib/types/runtime-types.d.ts).
 *   * reply capture  -> real: `ctx.on('session/event', (session, event) =>
 *                       event.type === 'turn/end' / 'assistant/message')`
 *                       (dsh-session/lib/types/index.d.ts: 'session/event' emit;
 *                        'assistant/message' carries {turn, step, message}).
 *   * single-shot    -> real: the existing `askModel()` in src/index.ts
 *                       (ctx.llm.stream) which stays exactly as it is today.
 *
 * Run: node test/commander-dispatch-proto.mjs
 */
import { strict as assert } from 'node:assert'

// ---------------------------------------------------------------------------
// 1. The task block delivered into the session (this text is the CONTRACT)
// ---------------------------------------------------------------------------

/**
 * Render one decision task for the commander session.
 *
 * Shape mirrors the plugin's existing buildPrompt(), plus a task header that
 * makes the request unambiguous inside a chat transcript:
 *   - the task id makes the reply correlatable even mid-conversation;
 *   - the required answer lines are stated last, so truncation loses prose, not
 *     the contract (the plugin learned this the hard way: prompt/system.md now
 *     requires the action line FIRST).
 */
export function renderTaskBlock(req) {
  const lines = []
  lines.push(`<fleet_task id="${req.taskId}" ship="${req.ship}" deadline_hint="${req.deadlineHintSec}s">`)
  lines.push('这是舰队运营的一个决策请求（不是闲聊）。你可以先调用工具自己查证，再给结论。')
  lines.push('')
  lines.push(`船：${req.ship}`)
  lines.push(`玩家给这艘船设定的运营目标：${req.goalText !== '' ? req.goalText : '(没有文字目标，只看动作边界)'}`)
  lines.push(`允许的动作：${req.goalOptions.length > 0 ? req.goalOptions.join(', ') : '(不限制)'}`)
  lines.push('现状（能力卡）：')
  lines.push(JSON.stringify(req.card ?? {}, null, 2))
  if (req.planText !== undefined && req.planText !== '') {
    lines.push('游戏侧算好的计划（reference，不是必须照抄）：')
    lines.push(req.planText)
  }
  lines.push('')
  lines.push('★ 请**先**给出结论行（第一行就写 action=），再写理由；理由写进 reason= 或写在后面都行。')
  lines.push(`★ 结论里必须回显 task=${req.taskId}（这样即使你在同一轮里回答了别的船，也能对上号）。`)
  lines.push('action=' + req.allowedExample, 'task=' + req.taskId, 'reason=…')
  lines.push('</fleet_task>')
  return lines.join('\n')
}

// ---------------------------------------------------------------------------
// 2. Answer parsing -- the SAME contract the plugin already validates
// ---------------------------------------------------------------------------

/** Parse `field=value` lines into a record (last wins, backticks/asterisks stripped). */
export function parseFields(text) {
  const out = {}
  for (const raw of text.split('\n')) {
    const line = raw.trim().replace(/^[*-]\s+/, '').replace(/[*`]/g, '')
    const m = /^([A-Za-z][A-Za-z0-9_]*)\s*=\s*(.*)$/.exec(line)
    if (m === null) continue
    out[m[1]] = m[2].trim()
  }
  return out
}

/**
 * Validate a session answer against the task.
 * Returns { ok: true, answer } or { ok: false, code, message }.
 * `codes` are the ones the FALLBACK LADDER switches on.
 */
export function validateAnswer(text, req, allowedActions) {
  if (typeof text !== 'string' || text.trim() === '') {
    return { ok: false, code: 'EMPTY_REPLY', message: 'the session produced no text' }
  }
  const f = parseFields(text)
  // A question instead of a decision is an EXPLICIT, supported outcome.
  const question = f.question ?? (/[?？]\s*$/.test(text.trim()) && f.action === undefined ? text.trim() : undefined)
  if (f.action === undefined && question !== undefined) {
    return { ok: false, code: 'ASKED_OWNER', question }
  }
  if (f.action === undefined) {
    return { ok: false, code: 'NO_ACTION_LINE', message: `no action line in reply (${text.length} chars)` }
  }
  if (f.task !== undefined && f.task !== req.taskId) {
    // The session answered about a different task -- never apply it to this ship.
    return { ok: false, code: 'TASK_MISMATCH', message: `reply is for task ${f.task}, not ${req.taskId}` }
  }
  const action = f.action
  if (!allowedActions.includes(action) && action !== 'None') {
    return { ok: false, code: 'BAD_ACTION', message: `action ${action} is not allowed here (${allowedActions.join(', ')})` }
  }
  const params = {}
  for (const k of ['x', 'y', 'size', 'duration', 'deposit', 'goodName', 'escort']) {
    if (f[k] === undefined) continue
    const n = Number(f[k])
    params[k] = Number.isFinite(n) && /^-?[\d.]+$/.test(f[k]) ? n : f[k]
  }
  return { ok: true, answer: { action, params, reason: f.reason } }
}

// ---------------------------------------------------------------------------
// 3. The stubs: a commander session, modelled on the documented Agent API
// ---------------------------------------------------------------------------

/** One inbox list, as dsh-agent describes it (`inbox.nextTurn` / `inbox.nextStep`). */
class Inbox {
  constructor() { this.nextTurn = []; this.nextStep = [] }
  append(target, message) { (target === 'next-step' ? this.nextStep : this.nextTurn).push(message) }
  clear() { this.nextTurn.length = 0; this.nextStep.length = 0 }
}

/**
 * Stub of the real Agent face (dsh-agent/lib/types/runtime-types.d.ts):
 *   status: 'idle' | 'running', inbox, followup(), inject(), whenIdle(), cancel().
 * `script` is ONE turn's behaviour: the ordered list of assistant texts the
 * session emits (a turn may emit several steps when it uses tools).
 */
function makeCommanderAgent({ script = [], turnMs = 5, failWith = null, trace = false } = {}) {
  const listeners = new Set()
  let idleWaiters = []
  const log = (m) => { if (trace) console.log(`    [stub] ${m}`) }
  const goIdle = () => {
    agent.status = 'idle'
    const waiters = idleWaiters
    idleWaiters = []
    log(`goIdle -> resolving ${waiters.length} waiter(s)`)
    for (const resolve of waiters) resolve()
  }
  const agent = {
    id: 'session-commander-0001',
    status: 'idle',
    inbox: new Inbox(),
    /** Real: dsh-agent Agent.followup -- queues its own turn and wakes the driver. */
    followup(message) {
      if (agent.status === 'running') throw new Error('followup while running is not what a task round is for')
      log('followup called')
      agent.inbox.append('next-turn', message)
      agent.status = 'running'
      const emit = (text) => {
        log(`emit assistant/message (${text.length} chars)`)
        for (const fn of listeners) {
          fn({ type: 'assistant/message', turn: 1, step: 1, message: { role: 'assistant', content: [{ type: 'text', text }] } })
        }
      }
      setTimeout(() => {
        log(`turn finishing (listeners=${listeners.size}, script=${script.length})`)
        if (failWith !== null) {
          for (const fn of listeners) fn({ type: 'turn/end', turn: 1, reason: { kind: 'error' } })
        } else {
          for (const text of script) emit(text)
          for (const fn of listeners) fn({ type: 'turn/end', turn: 1, reason: { kind: 'stop' } })
        }
        goIdle()
      }, turnMs)
    },
    /** Real: Agent.inject -- model-facing context, does NOT wake an idle driver. */
    inject(message) { agent.inbox.append('next-step', message) },
    /**
     * Real: Agent.whenIdle -- "resolve after the current whole-agent activity
     * reaches quiescence". Note the trap this stub also reproduces: when the
     * agent is ALREADY idle it resolves at once, so a caller must observe the
     * turn boundary (turn/end) rather than trust whenIdle alone.
     */
    whenIdle() {
      if (agent.status === 'idle') return Promise.resolve()
      return new Promise((resolve) => { idleWaiters.push(resolve) })
    },
    cancel() { goIdle() },
    /** Real: ctx.on('session/event', ...) scoped to this session. */
    onEvent(fn) { listeners.add(fn); return () => listeners.delete(fn) },
  }
  return agent
}

/** Stub registry: real face is `ctx.agents.get(id)` / `ctx.agents.list()`. */
function makeRegistry(agents) {
  return { get: (id) => agents.find((a) => a.id === id), list: () => [...agents] }
}

/** Stub of the plugin's CURRENT single-shot call (real: askModel + ctx.llm.stream). */
function makeSingleShot(reply, { ms = 5, fail = null } = {}) {
  let calls = 0
  return {
    get calls() { return calls },
    async run() {
      calls++
      await new Promise((r) => setTimeout(r, ms))
      if (fail !== null) return { failure: fail }
      return { text: reply, truncated: false }
    },
  }
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

// ---------------------------------------------------------------------------
// 4. The dispatcher: the delivery ladder, and the budgets
// ---------------------------------------------------------------------------

export const BUDGETS = {
  /** How long we are willing to wait for the session before giving up on it. */
  sessionDeadlineMs: 20_000,
  /** How much of that budget we require BEFORE we even try to queue the task. */
  queueReserveMs: 3_000,
  /** After the session answer arrives we still validate + order; keep slack. */
  commitReserveMs: 1_000,
  /** Hard cap for the single-shot fallback so the loop cannot run long. */
  singleShotTimeoutMs: 15_000,
}

/**
 * Ask the commander session, then walk the fallback ladder.
 *
 * `deps`: { registry, commanderId, singleShot, order, log }
 * `req`:  { taskId, ship, goalText, goalOptions, card, planText, deadlineHintSec,
 *           allowedActions, allowedExample }
 *
 * Never throws, never blocks longer than ~sessionDeadlineMs +
 * singleShotTimeoutMs, and never lets a busy/hung/mid-chat session stop the
 * decision (that is the whole point of the ladder).
 */
export async function dispatchDecision(deps, req) {
  const B = { ...BUDGETS, ...(deps.budgets ?? {}) }
  const started = Date.now()
  const say = deps.log ?? (() => {})
  const agent = deps.registry.get(deps.commanderId)

  const elapsed = () => Date.now() - started
  const remaining = () => B.sessionDeadlineMs - elapsed()

  // ---- rung 1: the commander session -------------------------------------
  if (agent === undefined) {
    say(`  [ladder] commander session ${deps.commanderId} is not live -> skip to single-shot`)
  } else if (agent.status !== 'idle') {
    // A human is chatting, or the session is on another ship. A task round gets
    // its own turn, so we can still queue -- but we refuse to queue when the
    // remaining budget cannot cover the wait.
    say(`  [ladder] commander is running (human chat / other task)`)
    if (remaining() < B.queueReserveMs) {
      say(`  [ladder] only ${remaining()}ms left (< reserve ${B.queueReserveMs}ms) -> skip to single-shot`)
    } else if (deps.steerWhenBusy !== true) {
      say('  [ladder] steerWhenBusy is off -> skip to single-shot rather than interleave')
    } else {
      const outcome = await runSessionRung(agent, req, Math.min(remaining() - B.commitReserveMs, B.sessionDeadlineMs), say)
      if (outcome.kind === 'decision') return commit(deps, req, outcome.answer, 'session', say)
      if (outcome.kind === 'asked') return await askOwnerThenFallback(deps, req, outcome, remaining(), say)
      say(`  [ladder] session rung failed: ${outcome.code}`)
    }
  } else {
    const budget = remaining() - B.commitReserveMs
    say(`  [ladder] commander is idle; queueing task ${req.taskId} with ${budget}ms budget`)
    const outcome = await runSessionRung(agent, req, budget, say)
    if (outcome.kind === 'decision') return commit(deps, req, outcome.answer, 'session', say)
    if (outcome.kind === 'asked') return await askOwnerThenFallback(deps, req, outcome, remaining(), say)
    say(`  [ladder] session rung failed: ${outcome.code} (${outcome.message ?? ''})`)
  }

  // ---- rung 2: today's single-shot facts call ----------------------------
  say('  [ladder] -> single-shot model call (today\'s path)')
  const single = await withTimeout(deps.singleShot.run(req), B.singleShotTimeoutMs)
  if (!single.settled) {
    say(`  [ladder] single-shot did not settle within ${B.singleShotTimeoutMs}ms`)
    return { action: 'None', params: {}, reason: 'no decision available', source: 'none' }
  }
  if (single.value === undefined || single.value === null) {
    say('  [ladder] single-shot threw')
    return { action: 'None', params: {}, reason: 'no decision available', source: 'none' }
  }
  if (single.value.failure !== undefined) {
    say(`  [ladder] single-shot model failure: ${single.value.failure}`)
    return { action: 'None', params: {}, reason: 'no decision available', source: 'none' }
  }
  const v = validateAnswer(single.value.text, req, req.allowedActions)
  if (!v.ok) {
    say(`  [ladder] single-shot reply unusable: ${v.code}`)
    return { action: 'None', params: {}, reason: 'no decision available', source: 'none' }
  }
  return commit(deps, req, v.answer, 'single-shot', say)
}

/** One session round: queue, observe, validate, all inside `budgetMs`. */
async function runSessionRung(agent, req, budgetMs, say) {
  // REAL: createUserMessage({content:[{type:'text',text}], source:{kind:'plugin', plugin:'davorion-copilot'}})
  const message = {
    id: `msg-${req.taskId}`,
    role: 'user',
    content: [{ type: 'text', text: renderTaskBlock(req) }],
    source: { kind: 'plugin', plugin: 'dsh-avorion-copilot' },
  }

  const texts = []
  const stop = agent.onEvent((event) => {
    if (event.type === 'assistant/message') {
      const text = event.message.content.filter((b) => b.type === 'text').map((b) => b.text).join('')
      if (text.length > 0) texts.push(text)
    }
  })
  try {
    if (budgetMs <= 0) return { kind: 'failed', code: 'NO_BUDGET' }
    try {
      agent.followup(message)
    } catch (error) {
      return { kind: 'failed', code: 'QUEUE_FAILED', message: error.message }
    }
    say(`  [session] queued; waiting up to ${budgetMs}ms for turn end`)
    // `Agent.whenIdle()` resolves with NO value, so the wait must report
    // settled-ness separately -- otherwise "resolved" and "timed out" are
    // indistinguishable and every session round would look like a timeout.
    const done = await withTimeout(agent.whenIdle(), budgetMs)
    if (!done.settled) {
      // REAL: agent.cancel({kind:'timeout'}) so the runaway round cannot hold the
      // fleet; the session log keeps whatever it produced.
      agent.cancel({ kind: 'timeout' })
      say(`  [session] no answer within ${budgetMs}ms -> cancel and fall back`)
      return { kind: 'failed', code: 'TIMEOUT' }
    }
    // The LAST assistant message of the turn is the answer (earlier ones are
    // tool-using steps). REAL: same fold over 'assistant/message' events.
    const last = texts.length > 0 ? texts[texts.length - 1] : ''
    const v = validateAnswer(last, req, req.allowedActions)
    if (v.ok) return { kind: 'decision', answer: v.answer, turns: texts.length }
    if (v.code === 'ASKED_OWNER') return { kind: 'asked', question: v.question }
    return { kind: 'failed', code: v.code, message: v.message }
  } finally {
    stop()
  }
}

/**
 * The session asked the owner a question instead of deciding.
 * A human in the loop is a FEATURE, but it must never stall the fleet silently:
 * we answer with a stated deferral NOW and let the owner's later reply reach the
 * session normally.
 */
async function askOwnerThenFallback(deps, req, outcome, remainingMs, say) {
  say(`  [session] the commander ASKED the owner: ${JSON.stringify(outcome.question).slice(0, 160)}`)
  say(`  [session] deferring this ship's decision (human in the loop); no order is sent`)
  return {
    action: 'None',
    params: {},
    reason: `commander asked the owner: ${String(outcome.question).slice(0, 300)}`,
    source: 'asked-owner',
    // No order is sent, so the caller's "did we command anything" answer is a
    // definite false -- never leave it undefined, or a caller reading
    // `orderOk !== true` cannot tell "deferred" from "crashed".
    orderOk: false,
  }
}

/** Validate, then run the SAME order RPC path the plugin uses today. */
async function commit(deps, req, answer, source, say) {
  if (answer.action !== 'None') {
    const receipt = await deps.order(req.ship, answer.action, answer.params)
    say(`  [commit] order ${req.ship} -> ${answer.action} : ${receipt.ok ? 'accepted' : 'REFUSED ' + receipt.why}`)
    return { ...answer, source, orderOk: receipt.ok === true, orderWhy: receipt.why }
  }
  say(`  [commit] action=None (${answer.reason ?? ''})`)
  return { ...answer, source, orderOk: false }
}

/** Await `promise` for at most `ms`; resolves undefined on timeout. */
function withTimeout(promise, ms) {
  return new Promise((resolve) => {
    let settled = false
    const timer = setTimeout(() => { if (!settled) { settled = true; resolve({ settled: false }) } }, Math.max(0, ms))
    promise.then(
      (value) => { if (!settled) { settled = true; clearTimeout(timer); resolve({ settled: true, value }) } },
      (error) => { if (!settled) { settled = true; clearTimeout(timer); resolve({ settled: false, error }) } },
    )
  })
}

// ---------------------------------------------------------------------------
// 5. Tests
// ---------------------------------------------------------------------------

const REQ = {
  taskId: 't-0001',
  ship: 'Miner-00002',
  goalText: 'north-west mining',
  goalOptions: ['Mine'],
  card: { sector: { x: 42, y: -8 }, busy: false },
  planText: '{"recommendation":{"area":{"x":30,"y":-12},"level":2}}',
  deadlineHintSec: 20,
  allowedActions: ['Mine', 'Salvage', 'Trade', 'Travel', 'Sell', 'Scout', 'None'],
  allowedExample: 'Mine',
}

/**
 * Compressed budgets for the test run. The PRODUCTION numbers are
 * BUDGETS above; shrinking only the wall-clock waits keeps the suite fast while
 * exercising the identical code paths (timeout, reserve, cancel).
 */
const TEST_BUDGETS = { sessionDeadlineMs: 1500, queueReserveMs: 100, commitReserveMs: 50, singleShotTimeoutMs: 400 }
const withBudgets = (deps) => ({ ...deps, budgets: TEST_BUDGETS })

const results = []
async function test(name, fn) {
  const logs = []
  try {
    const detail = await fn((line) => logs.push(line))
    results.push({ name, ok: true, detail })
  } catch (error) {
    results.push({ name, ok: false, detail: error.message })
  }
  console.log(`\n--- ${name} ---`)
  for (const l of logs) console.log(l)
  console.log(results[results.length - 1].ok ? '  PASS' : `  FAIL  ${results[results.length - 1].detail}`)
}

const orderOk = async (ship, action, params) => ({ ok: true, data: { ship, action, params } })

await test('session path: facts asked for, native tool call, final answer parsed and committed', async (log) => {
  const agent = makeCommanderAgent({
    script: [
      'CALL: sector_facts x=30 y=-12',
      'action=Mine\nx=30\ny=-12\nsize=15\nduration=1\ntask=t-0001\nreason=参考档位里 30,-12 的铁矿加权产量最高',
    ],
  })
  const single = makeSingleShot('action=None\ntask=t-0001')
  const out = await dispatchDecision(
    withBudgets({ registry: makeRegistry([agent]), commanderId: agent.id, singleShot: single, order: orderOk, log }),
    REQ,
  )
  console.log('  result:', JSON.stringify(out))
  assert.equal(out.source, 'session')
  assert.equal(out.action, 'Mine')
  assert.equal(out.params.x, 30)
  assert.equal(out.params.duration, 1)
  assert.equal(single.calls, 0, 'the single-shot path must not run when the session answered')
  return 'committed from the session without touching the fallback'
})

await test('busy session + no steer: falls back to single-shot, fleet still ordered', async (log) => {
  const agent = makeCommanderAgent({ script: [] })
  agent.status = 'running'   // the owner is chatting
  const single = makeSingleShot('action=Salvage\nx=8\ny=8\nsize=15\nduration=2\ntask=t-0001')
  const out = await dispatchDecision(
    withBudgets({ registry: makeRegistry([agent]), commanderId: agent.id, singleShot: single, order: orderOk, log }),
    REQ,
  )
  console.log('  result:', JSON.stringify(out))
  assert.equal(out.source, 'single-shot')
  assert.equal(out.action, 'Salvage')
  assert.equal(single.calls, 1)
  return 'the human being in the session did NOT stall the fleet'
})

await test('hung session: times out, cancels the round, falls back, never exceeds the budget', async (log) => {
  // A session whose turn never ends -- the runaway case the ladder must contain.
  const agent = makeCommanderAgent({ script: [] })
  agent.whenIdle = () => new Promise(() => {})      // never settles, like a stuck turn
  const single = makeSingleShot('action=Mine\nx=1\ny=1\ntask=t-0001')
  const t0 = Date.now()
  const out = await dispatchDecision(
    withBudgets({ registry: makeRegistry([agent]), commanderId: agent.id, singleShot: single, order: orderOk, log }),
    REQ,
  )
  const took = Date.now() - t0
  console.log(`  result: ${JSON.stringify(out)}   took ${took}ms`)
  assert.equal(out.source, 'single-shot')
  assert.equal(agent.status, 'idle', 'a hung round must be cancelled')
  assert.ok(
    took < TEST_BUDGETS.sessionDeadlineMs + TEST_BUDGETS.singleShotTimeoutMs + 400,
    `took too long: ${took}ms`,
  )
  return `cancelled the hung round and still decided in ${took}ms`
})

await test('no commander session at all: single-shot only (today\'s behaviour preserved)', async (log) => {
  const single = makeSingleShot('action=Trade\ngoodName=Drill\ndeposit=50000\ntask=t-0001')
  const out = await dispatchDecision(
    withBudgets({ registry: makeRegistry([]), commanderId: 'session-nobody', singleShot: single, order: orderOk, log }),
    REQ,
  )
  console.log('  result:', JSON.stringify(out))
  assert.equal(out.source, 'single-shot')
  assert.equal(out.action, 'Trade')
  return 'unchanged single-call path when no session is leased'
})

await test('session asks the owner a question: explicit deferral, no order, no stall', async (log) => {
  const agent = makeCommanderAgent({
    script: ['主人，这艘船没有护卫，伏击概率 34%，要我先派护航再出海吗？'],
  })
  const single = makeSingleShot('action=Mine\nx=1\ny=1\ntask=t-0001')
  const out = await dispatchDecision(
    withBudgets({ registry: makeRegistry([agent]), commanderId: agent.id, singleShot: single, order: orderOk, log }),
    REQ,
  )
  console.log('  result:', JSON.stringify(out), 'singleShotCalls=' + single.calls)
  assert.equal(out.source, 'asked-owner')
  assert.equal(out.action, 'None')
  assert.equal(out.orderOk, false)
  return 'human-in-the-loop is expressed as an explicit deferral, not a hang'
})

await test('session answers about the WRONG task: rejected, falls through to single-shot', async (log) => {
  const agent = makeCommanderAgent({ script: ['action=Mine\nx=99\ny=99\ntask=t-9999'] })
  const single = makeSingleShot('action=Mine\nx=30\ny=-12\ntask=t-0001')
  const out = await dispatchDecision(
    withBudgets({ registry: makeRegistry([agent]), commanderId: agent.id, singleShot: single, order: orderOk, log }),
    REQ,
  )
  console.log('  result:', JSON.stringify(out))
  assert.equal(out.source, 'single-shot')
  assert.equal(out.params.x, 30)
  return 'a stray chat reply can never be applied to the wrong ship'
})

await test('every rung fails: returns action=None instead of stalling forever', async (log) => {
  const agent = makeCommanderAgent({ script: ['嗯嗯~本鱼今天不想干活。'] })
  const single = makeSingleShot('', { fail: null })
  const out = await dispatchDecision(
    withBudgets({ registry: makeRegistry([agent]), commanderId: agent.id, singleShot: single, order: orderOk, log }),
    REQ,
  )
  console.log('  result:', JSON.stringify(out))
  assert.equal(out.action, 'None')
  assert.equal(out.source, 'none')
  return 'fails closed, and the ladder itself always terminates'
})

console.log(`\n${'='.repeat(72)}\n## prototype result\n${'='.repeat(72)}`)
let failed = 0
for (const r of results) {
  console.log(`${r.ok ? '  OK  ' : '  FAIL'} ${r.name}`)
  if (!r.ok) { failed++; console.log(`        ${r.detail}`) }
}
console.log(`\n${results.length - failed}/${results.length} passed`)
console.log('VERDICT: ' + (failed === 0
  ? 'the delivery ladder keeps the fleet deciding in every failure mode tested.'
  : 'the ladder has a hole -- see the failing cases.'))
process.exit(failed === 0 ? 0 : 1)
