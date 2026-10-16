/**
 * commander-api.mjs —— 会话开关 HTTP 路由的离线端到端测试 ✓
 *
 * 覆盖缺陷③：GET /avorion-copilot/api/commander?session=<id> 的 `mine` 兜底 ✓。
 *   旧 bug：GET 时 body 恒 {} → mine 恒 null → snapshot.isMine 恒 false ✗
 *   → 页面永远显示"关" ✗；用户再点一次反而把开着的关掉（toggle 语义 ✗）。
 *   修复：服务端从 URL 查询串 `?session=` 兜底赋给 mine ✓（POST 的 toggle/clear 仍走 body ✓）。
 *
 * 断言（任务不变式 ✓）：
 *   给定持久化的目标会话 == 当前会话 → GET 返回 isMine=true；
 *   不同会话 → false；没有目标 → false。
 *
 * 跑法: node test/commander-api.mjs   （退出码 0 = 全过 ✓）
 */
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { registerHooks } from 'node:module'

// 本测试离线跑：DSH 的两个包在 npm 里解析不了（缺 @deepseek-ai/cordis ✗），
// 照兄弟测试的路子指到本地桩 ✓。
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

// ★ 落盘重定向：commander.json 别写进真实玩家目录 ✓（os.homedir() 在 import 时算好 ✓）
const tmpHome = fs.mkdtempSync(path.join(os.tmpdir(), 'copilot-commander-api-'))
process.env.USERPROFILE = tmpHome
process.env.HOMEDRIVE = tmpHome.slice(0, 2)
process.env.HOMEPATH = tmpHome.slice(2)

const { apply } = await import('../lib/index.js')
const { setCommanderSession, resetCommanderCache } = await import('../lib/commander.js')

const PORT = 18877 // ★ 与其他测试的端口错开（order-payload 18811 / rendezvous-flow 18799 ✓）

const disposers = []
const captured = { handler: null, route: null }
const fakeWebServer = {
  register(route) {
    captured.route = route
    captured.handler = route.handler
    return () => {}
  },
}

const ctx = {
  logger: { info: () => {}, warn: () => {} },
  get(name) { return name === 'webServer' ? fakeWebServer : undefined },
  effect(fn) { const d = fn(); if (typeof d === 'function') disposers.push(d) },
  tools: { register: () => {} },
  llm: { async *stream() { yield { type: 'finish', reason: { kind: 'stop' } } } },
}

apply(ctx, { port: PORT })

if (captured.handler === null) {
  console.log('✗ webServer 路由没挂上 —— 无法测试')
  process.exit(1)
}

// 驱动 handler 的假 res ✓
function makeRes() {
  const res = { status: 0, headers: {}, text: '' }
  res.writeHead = (code, headers) => { res.status = code; res.headers = headers ?? {} }
  res.end = (s) => { res.text = String(s ?? '') }
  return res
}

async function get(url) {
  const res = makeRes()
  await captured.handler({ method: 'GET', url }, res)
  return { status: res.status, json: res.text === '' ? {} : JSON.parse(res.text) }
}

async function post(url, body) {
  const res = makeRes()
  const req = {
    method: 'POST',
    url,
    [Symbol.asyncIterator]: async function* () {
      if (body !== undefined) yield Buffer.from(JSON.stringify(body), 'utf8')
    },
  }
  await captured.handler(req, res)
  return { status: res.status, json: res.text === '' ? {} : JSON.parse(res.text) }
}

const checks = []
const check = (label, cond, actual) => checks.push({ label, pass: cond === true, actual })

// ---- ① 目标会话 == 当前会话 → isMine=true ✓ ----
{
  resetCommanderCache()
  setCommanderSession('session-abc')
  const r = await get('/avorion-copilot/api/commander?session=session-abc')
  console.log(`[1] GET ?session=session-abc -> ${JSON.stringify(r.json)}`)
  check('① 目标==当前：GET 返回 isMine=true', r.json.isMine === true, r.json.isMine)
  check('① 目标==当前：commander 字段是 session-abc', r.json.commander === 'session-abc', r.json.commander)
}

// ---- ② 目标会话 ≠ 当前会话 → isMine=false ✓ ----
{
  const r = await get('/avorion-copilot/api/commander?session=other-session')
  console.log(`[2] GET ?session=other-session -> ${JSON.stringify(r.json)}`)
  check('② 目标≠当前：GET 返回 isMine=false', r.json.isMine === false, r.json.isMine)
  check('② 目标≠当前：commander 仍是 session-abc', r.json.commander === 'session-abc', r.json.commander)
}

// ---- ③ 没有目标 → isMine=false ✓ ----
{
  resetCommanderCache()
  setCommanderSession(null)
  const r = await get('/avorion-copilot/api/commander?session=session-abc')
  console.log(`[3] GET ?session=session-abc (无目标) -> ${JSON.stringify(r.json)}`)
  check('③ 无目标：GET 返回 isMine=false', r.json.isMine === false, r.json.isMine)
  check('③ 无目标：commander 是 null', r.json.commander === null, r.json.commander)
}

// ---- ④ 没有 query 参数 → isMine=false ✓（不因为 body 空就假真） ----
{
  resetCommanderCache()
  setCommanderSession('session-abc')
  const r = await get('/avorion-copilot/api/commander')
  console.log(`[4] GET /commander (无 query) -> ${JSON.stringify(r.json)}`)
  check('④ 无 query：GET 返回 isMine=false', r.json.isMine === false, r.json.isMine)
}

// ---- ⑤ POST toggle 仍走 body（回归：不因缺陷③改动而破） ----
{
  resetCommanderCache()
  setCommanderSession(null)
  const r = await post('/avorion-copilot/api/commander/toggle', { session: 'body-session' })
  console.log(`[5] POST toggle {session:body-session} -> ${JSON.stringify(r.json)}`)
  check('⑤ POST toggle：body 里 session 生效（commander=body-session）', r.json.commander === 'body-session', r.json.commander)
}

const failed = checks.filter((c) => !c.pass)
console.log(`\n== 共 ${checks.length} 项断言，失败 ${failed.length} 项 ==`)
for (const f of failed) console.log(`  ✗ ${f.label} -> 实际: ${JSON.stringify(f.actual)}`)
console.log(failed.length === 0 ? 'commanderApiSelfTest: OK' : 'commanderApiSelfTest: FAILED')
for (const d of disposers) { try { d() } catch { /* noop */ } }
try { fs.rmSync(tmpHome, { recursive: true, force: true }) } catch { /* noop */ }
process.exit(failed.length === 0 ? 0 : 1)
