// test-peer.mjs —— 与游戏侧 **同协议、同 RPC 框架** 的最小 Node 对端。
//
// 用途：验证 Lua 侧的 RPC 框架，**不需要 DSH、不需要点界面、不需要截图** ✓
//   游戏是主动连出的一方 → 本进程当监听端 → 游戏连上来 → 本进程主动发起 RPC → 打日志
//
// 它同时是**插件侧的原型** ✓ —— plugins 的 TCP 层照着这个写就行 ✓
//
// 用法：  node native/test-peer.mjs [port]        （默认 8765）
// 日志：  控制台 + %APPDATA%/Avorion/moddata/copilot/rpc_peer.log
//
// 协议（docs/dev/protocol.md v2）：
//   帧    = uint32LE 长度 + UTF-8 JSON
//   信封  = { id, type: "request"|"response", cmd, data?, ok?, code?, message? }
//   铁律  = 答复的 id 与 cmd 都与请求相同；每个 request 都被答复

import net from 'node:net'
import fs from 'node:fs'
import path from 'node:path'
import os from 'node:os'

const PORT = Number(process.argv[2] || 8765)
const LOG_DIR = path.join(os.homedir(), 'AppData', 'Roaming', 'Avorion', 'moddata', 'copilot')
const LOG_FILE = path.join(LOG_DIR, 'rpc_peer.log')

try { fs.mkdirSync(LOG_DIR, { recursive: true }) } catch { /* ignore */ }

function log(...args) {
  const line = `${new Date().toISOString()}  ${args.join(' ')}`
  console.log(line)
  try { fs.appendFileSync(LOG_FILE, line + '\n') } catch { /* ignore */ }
}

// ---------------------------------------------------------------------------
// 帧编解码
// ---------------------------------------------------------------------------

let rxBuf = Buffer.alloc(0)

function feed(sock, chunk) {
  rxBuf = Buffer.concat([rxBuf, chunk])
  // 不足 4 字节 → 等；够 4 但不足 len → 等；够 len → 切一帧，剩余的继续判
  for (;;) {
    if (rxBuf.length < 4) return
    const len = rxBuf.readUInt32LE(0)
    if (len === 0 || len > 64 * 1024 * 1024) {
      log(`!! 非法长度 ${len} —— 视为协议错误，断开`)
      sock.destroy()
      return
    }
    if (rxBuf.length < 4 + len) return
    const payload = rxBuf.subarray(4, 4 + len).toString('utf8')
    rxBuf = rxBuf.subarray(4 + len)
    let msg
    try { msg = JSON.parse(payload) } catch (e) { log(`!! JSON 解析失败: ${e.message}  raw=${payload.slice(0, 120)}`); continue }
    dispatch(msg)
  }
}

function send(msg) {
  if (!sock) return false
  const body = Buffer.from(JSON.stringify(msg), 'utf8')
  const head = Buffer.alloc(4)
  head.writeUInt32LE(body.length, 0)
  return sock.write(Buffer.concat([head, body]))
}

// ---------------------------------------------------------------------------
// RPC 框架（与 Lua 侧 rpc.lua 一一对应）
// ---------------------------------------------------------------------------

let nextId = 0
const handlers = new Map()      // cmd -> (data) => [ok, payload, message]
const pending = new Map()       // id  -> { cmd, cb, deadline }

function handle(cmd, fn) { handlers.set(cmd, fn) }
function caps() { return [...handlers.keys()].sort() }

function call(cmd, data, cb, timeoutSec = 5) {
  const id = ++nextId
  pending.set(id, { cmd, cb, deadline: Date.now() + timeoutSec * 1000 })
  const ok = send({ id, type: 'request', cmd, data: data ?? {} })
  if (!ok) { pending.delete(id); return false }
  return true
}

function dispatch(msg) {
  if (!msg || typeof msg !== 'object') return
  if (typeof msg.id !== 'number') { log(`!! 信封缺 id（协议 §2 铁律 5）: ${JSON.stringify(msg).slice(0,120)}`); return }
  if (msg.type === 'response') return onResponse(msg)
  if (msg.type === 'request') return onRequest(msg)
  log(`!! 非法 type: ${msg.type}`)
}

function onResponse(msg) {
  const e = pending.get(msg.id)
  if (!e) { log(`   (未知 id 的答复 ${msg.id} —— 按协议丢弃 ✓)`); return }
  pending.delete(msg.id)
  log(`<<< response id=${msg.id} cmd=${msg.cmd} ok=${msg.ok}${msg.ok ? '' : ' code=' + msg.code + ' msg=' + (msg.message ?? '')}`)
  if (msg.ok && msg.data) log(`       data = ${JSON.stringify(msg.data).slice(0, 400)}`)
  if (e.cb) { try { e.cb(msg.ok, msg.data, msg.message ?? msg.code) } catch (err) { log(`!! 回调异常: ${err.message}`) } }
}

function onRequest(msg) {
  const fn = handlers.get(msg.cmd)
  log(`>>> request  id=${msg.id} cmd=${msg.cmd} data=${JSON.stringify(msg.data ?? {}).slice(0, 300)}`)

  let ok = false, payload, message
  if (!fn) {
    ok = false; payload = 'UNSUPPORTED'; message = `peer has no handler for '${msg.cmd}'`
  } else {
    try { [ok, payload, message] = fn(msg.data ?? {}) }
    catch (err) { ok = false; payload = 'HANDLER_ERROR'; message = err.message }
  }

  const resp = { id: msg.id, type: 'response', cmd: msg.cmd, ok: !!ok }
  if (ok) resp.data = payload ?? {}
  else { resp.code = payload ?? 'ERROR'; if (message) resp.message = message; resp.data = {} }
  send(resp)
  log(`<<< 已答复 id=${msg.id} cmd=${msg.cmd} ok=${!!ok}${ok ? '' : ' code=' + resp.code}`)
}

// 超时扫描（Lua 侧靠 tick 泵，这里靠定时器 ✓）
setInterval(() => {
  const now = Date.now()
  for (const [id, e] of [...pending]) {
    if (now >= e.deadline) {
      pending.delete(id)
      log(`!! 超时 id=${id} cmd=${e.cmd}`)
      if (e.cb) try { e.cb(false, 'TIMEOUT', 'no response') } catch { /* ignore */ }
    }
  }
}, 500)

// ---------------------------------------------------------------------------
// 我提供给游戏调用的能力（对面调我）
// ---------------------------------------------------------------------------

handle('hello', (d) => {
  log(`   [hello] side=${d.side} ver=${d.ver} caps=[${(d.caps ?? []).join(',')}]`)
  return [true, { side: 'peer', ver: 2, caps: caps() }]
})

// ★ decide（协议 §11）：游戏问我要决策 —— 这里先回一个**固定答案**验证链路 ✓
handle('decide', (d) => {
  log(`   [decide] ship=${d.ship}  options=${JSON.stringify(d.options ?? []).slice(0, 200)}`)
  return [true, { action: 'PING_ONLY', params: {}, note: 'test peer: fixed answer' }]
})

handle('ping', () => [true, { pong: true, from: 'peer' }])

// ---------------------------------------------------------------------------
// 连接处理
// ---------------------------------------------------------------------------

let sock = null

const server = net.createServer((s) => {
  // 协议 §6：只接受一条连接；新连接到达 → 关掉旧的 ✓
  if (sock) {
    log('!! 新连接到达 —— 按协议 §6 只保留一条，关掉旧连接')
    try { sock.destroy() } catch { /* ignore */ }
    pending.clear()
  }
  sock = s
  rxBuf = Buffer.alloc(0)
  log(`[+] 游戏连上来了 ${s.remoteAddress}:${s.remotePort}`)

  s.on('data', (c) => feed(s, c))
  s.on('error', (e) => log(`[!] socket 错误: ${e.message}`))
  s.on('close', () => { log('[-] 连接关闭'); if (sock === s) sock = null })

  // 连上就发起验证序列 ✓（先握手，再 query，再 ping）
  setTimeout(() => {
    log('--- 发起 hello ---')
    call('hello', { ver: 2, side: 'peer', caps: caps() }, (ok, data) => {
      if (!ok) { log('!! hello 失败，后续不进行'); return }
      log('--- hello 成功，发起 query fleet ---')
      call('query', { what: 'fleet' }, (ok2, data2, why) => {
        if (!ok2) { log(`!! query fleet 失败: ${why}`); return }
        // ★ BUG 修复：空的 Lua 表被 cJSON 编成 {}（不是 []）✗ —— 两种都当空列表处理 ✓
        const rawShips = data2?.ships
        const ships = Array.isArray(rawShips) ? rawShips
          : (rawShips && typeof rawShips === 'object' ? Object.values(rawShips) : [])
        log(`=== ★ 舰队快照拿到 === ships=${ships.length} 只=${data2?.designated ?? '?'}`)
        for (const sh of ships) {
          log(`    - ${sh.name}  busy=${sh.busy}  captain=${sh.hasCaptain}  sector=${JSON.stringify(sh.sector ?? null)}` +
              (sh.probe ? `  probe=${JSON.stringify(sh.probe)}` : ''))
        }
        log('--- 发起 query caps ---')
        call('query', { what: 'caps' }, (ok3, data3) => {
          log(`=== caps: ${ok3 ? JSON.stringify(data3) : '失败'}`)
          log('--- 发起 ping ---')
          call('ping', {}, (ok4, data4) => { log(`=== ping: ${ok4 ? JSON.stringify(data4) : '失败'}`); log('--- 验证序列结束 ---') })
        })
      })
    })
  }, 1200)
})

server.on('error', (e) => {
  // 协议 §6：端口占用必须**明确报错**，不许静默 ✓（今晚踩过 ✗）
  log(`!! 监听失败: ${e.code} ${e.message}`)
  if (e.code === 'EADDRINUSE') log(`!! 端口 ${PORT} 被占用 —— 找出占用进程，别静默重试`)
  process.exit(1)
})

server.listen(PORT, '127.0.0.1', () => {
  log(`=== RPC 测试对端已在 127.0.0.1:${PORT} 监听（等游戏连上来）===`)
  log(`=== 日志同时写入 ${LOG_FILE} ===`)
})
