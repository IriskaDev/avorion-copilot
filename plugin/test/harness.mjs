/**
 * 桥接插件离线自测。
 *
 * apply() 只依赖 ctx 的 {logger, llm.stream, effect} 三样，所以可以用假 ctx 在 Node 里
 * 把整条链路跑一遍：扫目录 → 读请求 → 组 prompt → 收分片 → 解析 → 原子写回 → 写日志。
 * 唯一没覆盖的是真实模型调用与 DSH 宿主集成。
 *
 *   node test/harness.mjs
 */
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { registerHooks } from 'node:module'

// npm 装好的 dsh-llm 无法脱离 DSH 单独加载（传递依赖 cordis 在 npm 包里是空目录），
// 离线测试用本地桩顶替它；只影响本进程，不动插件产物。
//
// ★ 2026-10-17：`@deepseek-ai/dsh-tools` 也要桩 ✓ —— `lib/tools.js` 顶部就 import 它 ✓，
//   而离线环境里没有那个包（`node_modules` 是 build.ps1 的**编译期**联接，跑完即删 ✓；
//   真实运行时由 DSH 宿主解析 ✓）→ 不桩的话 `node test/harness.mjs` 直接
//   ERR_MODULE_NOT_FOUND ✗（**不是新问题** ✓，本改动之前也是这样 ✓）。
registerHooks({
  resolve(specifier, context, next) {
    if (specifier === '@deepseek-ai/dsh-llm') {
      return { url: new URL('./llm-stub.mjs', import.meta.url).href, shortCircuit: true }
    }
    if (specifier === '@deepseek-ai/dsh-tools') {
      return { url: new URL('./dsh-tools-stub.mjs', import.meta.url).href, shortCircuit: true }
    }
    return next(specifier, context)
  },
})

const { apply } = await import('../lib/index.js')

const REQUEST = `version=1
ship=Miner-00002
tick=17
state=idle
pos=42,-8
caps=mining:2,salvaging:0,cargo:1500,free:1200,dps:130,hp:4000,jump:12
captain=Miner/3/1
cargo=Iron:200
money=1234560
opt1=Mine|area:30,-12,44,2|attack:0.08|duration:1|yield:Iron:1200-1500
opt2=Mine|area:12,5,26,19|attack:0.31|duration:1|yield:Titanium:400-600
opt3=Salvage|area:8,8,22,22|attack:0.05|duration:1|items:3-5
`

function makeCtx(chunks) {
  const logs = []
  const disposers = []
  const captured = {}
  return {
    logs,
    captured,
    disposers,
    ctx: {
      logger: {
        info: (m) => logs.push(`INFO  ${m}`),
        warn: (m) => logs.push(`WARN  ${m}`),
      },
      // ★ 2026-10-17：插件现在**一定要**有 `tools`（它注册 fleet_* 工具 ✓）——
      //   以前这个假 ctx 没有它 ✗ → `ctx.tools.register` 直接抛 ✓（本改动之前就已经这样 ✓）。
      //   离线测试不需要真的注册 ✓，只要有一个**收得下**的 register ✓（照 dsh-global-memory 的用法 ✓）。
      tools: { register: () => {} },
      effect(fn, label) {
        const d = fn()
        if (typeof d === 'function') disposers.push({ label, d })
      },
      llm: {
        async *stream(options) {
          captured.options = options
          for (const chunk of chunks) yield chunk
        },
      },
    },
  }
}

const STOP = { type: 'finish', reason: { kind: 'stop' } }
const MAXTOK = { type: 'finish', reason: { kind: 'max-tokens' } }
const FAIL = { type: 'finish', reason: { kind: 'error', failure: { code: 'RATE_LIMIT', message: 'slow down' } } }

const GOOD = [
  { type: 'reasoning-delta', index: 0, text: '选项 2 的钛矿收益与选项 1 接近，' },
  { type: 'reasoning-delta', index: 0, text: '但伏击概率只有 0.08，明显更稳。' },
  { type: 'text-delta', index: 1, text: '好的，我选这个。\n' }, // 多余文字，应被忽略
  { type: 'text-delta', index: 1, text: 'choice=1\n' },
  { type: 'text-delta', index: 1, text: 'duration=1\n' },
  { type: 'text-delta', index: 1, text: 'escorts=Miner-00001, Miner-00003\n' },
  { type: 'text-delta', index: 1, text: 'reason=低风险铁矿，收益接近上限\n' },
  STOP,
]

const GARBLED = [{ type: 'text-delta', index: 0, text: '我觉得应该去采矿吧。' }, STOP]
const TRUNCATED = [{ type: 'text-delta', index: 0, text: 'choice=' }, MAXTOK]
const CALLFAIL = [FAIL]

// 回归用例：真实第一次跑时模型回的就是这种形态（choice=opt1、加粗、全角冒号、escorts 为空）
const OPT_STYLE = [
  { type: 'reasoning-delta', index: 0, text: 'Salvaging capability is 0, so skip opt3.' },
  { type: 'text-delta', index: 1, text: '**choice=opt1**\n' },
  { type: 'text-delta', index: 1, text: 'duration：1\n' },
  { type: 'text-delta', index: 1, text: 'escorts=\n' },
  { type: 'text-delta', index: 1, text: 'reason=飞船已在区域内，伏击概率低，无需护卫\n' },
  STOP,
]

// 模型用中文写"无"表示不派护卫，不能当成船名
const NONE_ESCORT_STYLE = [
  { type: 'text-delta', index: 0, text: 'choice=3\n' },
  { type: 'text-delta', index: 0, text: 'escorts=无\n' },
  STOP,
]

async function scenario(title, chunks, requestText = REQUEST, ship = 'Miner-00002') {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'copilot-bridge-'))
  fs.writeFileSync(path.join(dir, `req_${ship}.txt`), requestText, 'utf8')

  const h = makeCtx(chunks)
  await apply(h.ctx, { dir, intervalMs: 30 })
  // 等 tick 跑完（apply 里立刻扫了一次，这里给余量）
  await new Promise((resolve) => setTimeout(resolve, 250))

  const resPath = path.join(dir, `res_${ship}.txt`)
  const logPath = path.join(dir, `log_${ship}.txt`)
  const res = fs.existsSync(resPath) ? fs.readFileSync(resPath, 'utf8') : null
  const log = fs.existsSync(logPath) ? fs.readFileSync(logPath, 'utf8') : null

  console.log(`\n${'='.repeat(72)}\n## ${title}\n${'='.repeat(72)}`)
  console.log('--- res ---')
  console.log(res === null ? '(没有生成 res 文件！)' : res.trim())
  if (log) {
    const reasoning = /--- reasoning ---\n([\s\S]*?)\n\n--- reply/.exec(log)
    console.log('--- 日志里的思维链 ---')
    console.log(reasoning ? reasoning[1].trim() : '(无)')
    if (log.includes('truncated')) console.log('--- 日志含 maxTokens 截断警告 ✓')
  }
  console.log('--- 插件日志 ---')
  h.logs.forEach((l) => console.log('   ' + l))

  const leftover = fs.readdirSync(dir).filter((n) => n.endsWith('.tmp'))
  if (leftover.length > 0) console.log(`!! 残留临时文件: ${leftover.join(', ')}`)

  for (const d of h.disposers) d.d()
  fs.rmSync(dir, { recursive: true, force: true })
  return res
}

const r1 = await scenario('正常回复（含思维链 + 多余文字）', GOOD)
const r2 = await scenario('回复里没有 choice（应写成 error）', GARBLED)
const r3 = await scenario('被 maxTokens 截断', TRUNCATED)
const r4 = await scenario('模型调用失败', CALLFAIL)
const r5 = await scenario(
  '请求里有第二个船（应各自独立裁决）',
  GOOD,
  REQUEST.replace('Miner-00002', 'Trader-00007'),
  'Trader-00007',
)

console.log(`\n${'='.repeat(72)}\n## 断言\n${'='.repeat(72)}`)
const checks = [
  ['正常回复 → choice=1', /^choice=1$/m.test(r1 ?? '')],
  ['正常回复 → duration=1', /^duration=1$/m.test(r1 ?? '')],
  ['正常回复 → 护卫去空格', /^escorts=Miner-00001,Miner-00003$/m.test(r1 ?? '')],
  ['正常回复 → reason 被压缩成一行', /^reason=低风险铁矿，收益接近上限$/m.test(r1 ?? '')],
  ['无 choice → error', /^error=/m.test(r2 ?? '')],
  ['截断 → 仍尝试解析（choice 为空 → error）', /^error=/m.test(r3 ?? '')],
  ['调用失败 → error 带 code 与 message', /^error=model call failed: RATE_LIMIT: slow down$/m.test(r4 ?? '')],
  ['另一艘船独立裁决', /^ship=Trader-00007$/m.test(r5 ?? '')],
]
let failed = 0
for (const [label, ok] of checks) {
  console.log(`${ok ? '  ✓' : '  ✗'} ${label}`)
  if (!ok) failed++
}
console.log(`\n${checks.length - failed}/${checks.length} 通过`)
process.exit(failed === 0 ? 0 : 1)
