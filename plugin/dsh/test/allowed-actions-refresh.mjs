/**
 * allowed-actions-refresh.mjs —— ★ 2026-10-20 真机丢单的回归（`BAD_ACTION` 误杀合法动作 ✓）
 *
 * 病根（`moddata/copilot/decisions.live.log` 2026-10-20 14:32:19 逐字 ✓）：
 *   `[session] ✘ 校验没过：BAD_ACTION（action Mine 不在允许集合内（Travel, Sell, Scout，以及 None））`
 *   → `fallbackNone` → 船保持 `busy:false`；而同一刻 `fleet_query{what:'ship'}` 已是 `Mining:4` ✓，
 *   `fleet_order` 直下**一次就成** ✓。
 *   ⇒ 校验拿的是**投递时**的动作边界快照（船刚加载完、炮塔还没恢复 ✓），不是当时的事实 ✗。
 *
 * 本文件钉四件事（全部离线、不跑游戏 ✓）：
 *   A. 块里快照缺 Mine、**当前卡片**有 Mining → 答 `Mine` **必须被接受** ✓（主人给的首选修法 ✓）
 *   B. 真非法动作（当前边界里确实没有）**仍然被拒** ✓（不许把白名单放成"什么都行" ✗）
 *   C. 被拒**有可见理由** ✓（code + 两条清单都进流水 ✓）
 *   D. 拿不到当前事实 → **退回快照** ✓（绝不因为查不到就丢单 ✗）
 *   E. 合并块（N>1）也按**每条船自己**的当前事实校验 ✓
 *
 * 跑法：node test/allowed-actions-refresh.mjs   （退出码 0 = 全过 ✓）
 */
import { strict as assert } from 'node:assert'

const { dispatchDecision, resetBatchQueue } = await import('../lib/dispatch.js')

const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

/** 压缩预算：只有等待时长变了 ✓，代码路径与生产逐字相同 ✓ */
const FAST = {
  sessionDeadlineMs: 1200, queueReserveMs: 100, commitReserveMs: 50,
  singleShotTimeoutMs: 300, retryOnceMs: 200, mergeWindowMs: 30,
}

/** 假的投递会话（与 commander-dispatch.mjs 同款 ✓：followup → 回 assistant 文本 → turn/end ✓） */
function makeAgent({ id = 'session-test', script = [], turnMs = 5 } = {}) {
  const inbox = []
  const listeners = new Set()
  let idleWaiters = []
  let rounds = 0
  const agent = {
    id,
    status: 'idle',
    inbox,
    cancelled: 0,
    followup(message) {
      rounds += 1
      inbox.push(message)
      agent.status = 'running'
      setTimeout(() => {
        for (const text of typeof script === 'function' ? script(rounds, message) : script) {
          for (const fn of [...listeners]) {
            fn({
              type: 'assistant/message', turn: rounds, step: 1,
              message: { role: 'assistant', content: [{ type: 'text', text }] },
            })
          }
        }
        for (const fn of [...listeners]) fn({ type: 'turn/end', turn: rounds, reason: { kind: 'completed' } })
        agent.status = 'idle'
        const w = idleWaiters
        idleWaiters = []
        for (const r of w) r()
      }, turnMs)
    },
    whenIdle() {
      if (agent.status === 'idle') return Promise.resolve()
      return new Promise((resolve) => { idleWaiters.push(resolve) })
    },
    cancel() { agent.cancelled += 1 },
    onEvent(fn) { listeners.add(fn); return () => listeners.delete(fn) },
  }
  return agent
}

const blockOf = (agent) => agent.inbox[agent.inbox.length - 1].content[0].text

/** 造一份 deps ✓：`fresh` 缺省 = 没给 allowedActionsFor（退回快照的路径 ✓） */
function makeDeps({ agent, snapshot, fresh, log }) {
  return {
    registry: { get: (id) => (id === agent.id ? agent : undefined), list: () => [agent] },
    commanderId: agent.id,
    subscribe: (_sid, fn) => agent.onEvent(fn),
    followup: (a, block) => a.followup({ role: 'user', content: [{ type: 'text', text: block }] }),
    // 单发那条路：这里只回 None ✓（断言都落在 out.session 上 ✓）
    singleShot: async () => ({ text: 'action=None', truncated: false }),
    allowedActions: snapshot,
    ...(fresh === undefined ? {} : { allowedActionsFor: async (ship) => (typeof fresh === 'function' ? fresh(ship) : fresh) }),
    mode: 'live',
    budgets: FAST,
    retrySessionOnce: false,
    log,
  }
}

const results = []
async function test(name, fn) {
  const logs = []
  /** 收集器：既当 `log(line)` 用，也能 `.lines` 读回全部流水 ✓ */
  const log = (l) => logs.push(l)
  log.lines = logs
  resetBatchQueue()
  try {
    const detail = await fn(log)
    results.push({ name, ok: true, detail })
  } catch (error) {
    results.push({ name, ok: false, detail: error?.stack ?? String(error) })
  }
  console.log(`\n--- ${name} ---`)
  for (const l of logs) console.log(l)
  console.log(results[results.length - 1].ok ? '  PASS' : `  FAIL\n${results[results.length - 1].detail}`)
}

const SHIP = 'Miner-00002'

// ---------------------------------------------------------------------------
// A. 块里快照缺 Mine，当前卡片有 Mining → Mine 必须被接受 ✓（这次真机事故本身 ✓）
// ---------------------------------------------------------------------------
await test('A. 快照缺 Mine、当前卡片有 Mining → action=Mine 被接受 ✓', async (log) => {
  const agent = makeAgent({ script: [
    '我查了船卡，它有采矿炮塔 ✓',
    `action=Mine\ntask=t-aaaa0001\nx=-227\ny=-43\nsizeX=15\nsizeY=15\nduration=1\nsafeMode=false\nreason=铁矿石层最厚`,
  ] })
  const out = await dispatchDecision(makeDeps({
    agent,
    // ★ 投递时快照 = 真机日志里那份（**没有 Mine** ✗）
    snapshot: ['Travel', 'Sell', 'Scout'],
    // ★ 当场重查 = 炮塔恢复之后的当前事实（有 Mine ✓）
    fresh: ['Mine', 'Travel', 'Sell', 'Scout', 'Refine'],
    log,
  }), { taskId: 't-aaaa0001', ship: SHIP, goalOptions: ['Travel', 'Sell', 'Scout'], deadlineHintSec: 20 })

  // ① 块里确实印着**过期**清单（这就是事故的形状 ✓ —— 记录它，防止有人把它当成"合法依据" ✗）
  assert.match(blockOf(agent), /可选动作（按船自动）：Travel, Sell, Scout/,
    '块里应当仍是投递时那份快照（本次要复现的就是它过期 ✗）')
  // ② 校验按当前事实 → 接受 ✓
  assert.equal(out.session?.answered, true, '合法动作不许因为块里清单过期而被丢 ✗')
  assert.equal(out.session.code, undefined)
  assert.equal(out.action, 'Mine')
  assert.equal(out.source, 'session')
  assert.equal(out.session.answer.params.x, -227)
  assert.equal(out.session.answer.params.sizeX, 15)
  // ③ 流水里留下"清单过期了"的证据 ✓
  assert.ok(log.lines.join('\n').includes('动作边界当场重查'), '流水里必须有当场重查那一行 ✓')
  return 'Mine 被接受，且流水写明投递时 [Travel,Sell,Scout] → 当前 [Mine,Travel,Sell,Scout,Refine]'
})

// ---------------------------------------------------------------------------
// B. 真非法动作仍然被拒 ✓（当前边界里确实没有 Trade ✓）
// ---------------------------------------------------------------------------
await test('B. 真非法动作（当前也没有）仍然被拒 ✓', async (log) => {
  const agent = makeAgent({ script: [`action=Trade\ntask=t-bbbb0002\ngoodName=Drill\nx=1\ny=2\nsizeX=17\nsizeY=17\ndeposit=1000\nreason=想跑商`] })
  const out = await dispatchDecision(makeDeps({
    agent,
    snapshot: ['Mine', 'Travel'],
    fresh: ['Mine', 'Travel'],     // ★ 当场重查也是这两条 → Trade 不在里面 ✓
    log,
  }), { taskId: 't-bbbb0002', ship: SHIP, goalOptions: ['Mine', 'Travel'], deadlineHintSec: 20 })

  assert.equal(out.session?.answered, false)
  assert.equal(out.session.code, 'BAD_ACTION')
  assert.match(String(out.session.message), /Trade/)
  assert.match(String(out.session.message), /不在允许集合内/)
  return `被拒且 code=BAD_ACTION：${out.session.message}`
})

// ---------------------------------------------------------------------------
// C. 被拒**有可见理由** ✓：两条清单都进流水（投递时 / 当场 ✓）
// ---------------------------------------------------------------------------
await test('C. 被拒的理由可见（投递时快照 vs 当场边界）✓', async (log) => {
  const agent = makeAgent({ script: [`action=Salvage\ntask=t-cccc0003\nx=0\ny=0\nsizeX=15\nsizeY=15\nreason=打捞`] })
  await dispatchDecision(makeDeps({
    agent,
    snapshot: ['Travel', 'Sell'],
    fresh: ['Mine', 'Travel', 'Sell'],
    log,
  }), { taskId: 't-cccc0003', ship: SHIP, goalOptions: ['Travel', 'Sell'], deadlineHintSec: 20 })

  const text = log.lines.join('\n')
  assert.match(text, /校验没过：BAD_ACTION/)
  assert.match(text, /action Salvage 不在允许集合内/)
  assert.match(text, /被拒原因/)
  assert.match(text, /投递时快照 \[Travel,Sell\]/)     // 投递时那份 ✓
  assert.match(text, /当场边界 \[Mine,Travel,Sell\]/)  // 当场那份 ✓
  return '拒绝理由带两条清单，落在 decisions.live.log 里 ✓'
})

// ---------------------------------------------------------------------------
// D. 拿不到当前事实 → 退回快照 ✓（绝不因为查不到就丢单 ✗）
// ---------------------------------------------------------------------------
await test('D. 查不到当前事实 → 退回快照，不丢单 ✓', async (log) => {
  const agent = makeAgent({ script: [`action=Mine\ntask=t-dddd0004\nx=-5\ny=-6\nsize=15\nreason=退回快照也接受`] })
  const out = await dispatchDecision(makeDeps({
    agent,
    snapshot: ['Mine', 'Travel'],
    fresh: () => undefined,        // ★ 游戏侧没答上来 → undefined ✓
    log,
  }), { taskId: 't-dddd0004', ship: SHIP, goalOptions: ['Mine', 'Travel'], deadlineHintSec: 20 })

  assert.equal(out.session?.answered, true)
  assert.equal(out.action, 'Mine')
  assert.match(log.lines.join('\n'), /退回投递时快照/)
  return 'undefined → 退回快照 [Mine,Travel]，Mine 仍被接受 ✓'
})

// ---------------------------------------------------------------------------
// E. 合并块（N=2）：每条船按**自己**的当前事实校验 ✓
// ---------------------------------------------------------------------------
await test('E. 合并块里每条船用自己的当前边界 ✓', async (log) => {
  const agent = makeAgent({
    script: (_round, message) => {
      const ids = [...new Set([...message.content[0].text.matchAll(/task=(t-[0-9a-f]{8})/g)].map((m) => m[1]))]
      // 第一艘答 Mine（快照里没有 ✓），第二艘答 Scout（快照里有 ✓）
      return ids.map((id, i) => i === 0
        ? `action=Mine\ntask=${id}\nx=-227\ny=-43\nsize=15\nreason=合并块第一艘`
        : `action=Scout\ntask=${id}\nx=9\ny=9\nsize=21\nreason=合并块第二艘`)
    },
  })
  const freshOf = (ship) => (ship === 'Miner-00002'
    ? ['Mine', 'Travel', 'Sell', 'Scout', 'Refine']
    : ['Travel', 'Scout'])
  const deps = makeDeps({ agent, snapshot: ['Travel', 'Sell', 'Scout'], fresh: freshOf, log })
  const [a, b] = await Promise.all([
    dispatchDecision(deps, { taskId: 't-eeee0005', ship: 'Miner-00002', goalOptions: ['Travel', 'Sell', 'Scout'], deadlineHintSec: 20 }),
    dispatchDecision(deps, { taskId: 't-eeee0006', ship: 'Scout-00003', goalOptions: ['Travel', 'Scout'], deadlineHintSec: 20 }),
  ])
  assert.equal(a.session?.answered, true, '合并块里第一艘的 Mine 必须被接受 ✓')
  assert.equal(a.session.batchSize, 2, '应当真的合并成一块 ✓')
  assert.equal(a.action, 'Mine')
  assert.equal(b.session?.answered, true)
  assert.equal(b.action, 'Scout')
  return '合并块：Miner-00002 → Mine ✓，Scout-00003 → Scout ✓（各自的当前边界 ✓）'
})

// ---------------------------------------------------------------------------
// 汇总
// ---------------------------------------------------------------------------
await sleep(50)
const failed = results.filter((r) => !r.ok)
console.log(`\n== 共 ${results.length} 项断言，失败 ${failed.length} 项 ==`)
for (const r of failed) console.log(`  ✗ ${r.name}\n${r.detail}`)
process.exit(failed.length === 0 ? 0 : 1)
