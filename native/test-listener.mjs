/**
 * 测试用 TCP 监听端：验证「游戏 → DLL → TCP」这条链路。
 *
 * 收：按 4 字节小端长度分帧，把每条消息记进日志
 * 回：收到任何消息都回一条 hello 握手
 *
 *   node test-listener.mjs
 */
import net from 'node:net'
import fs from 'node:fs'

const PORT = 8765
const LOG = 'C:\\Users\\IriskaDev\\AppData\\Roaming\\Avorion\\moddata\\copilot\\native_net_listener.log'

function log(line) {
  const stamp = new Date().toISOString()
  const text = `${stamp}  ${line}\n`
  fs.appendFileSync(LOG, text, 'utf8')
  process.stdout.write(text)
}

function frame(text) {
  const body = Buffer.from(text, 'utf8')
  const head = Buffer.alloc(4)
  head.writeUInt32LE(body.length, 0)
  return Buffer.concat([head, body])
}

const server = net.createServer((sock) => {
  log(`[+] client ${sock.remoteAddress}:${sock.remotePort}`)
  let buf = Buffer.alloc(0)

  sock.on('data', (chunk) => {
    buf = Buffer.concat([buf, chunk])
    for (;;) {
      if (buf.length < 4) return
      const len = buf.readUInt32LE(0)
      if (buf.length < 4 + len) return
      const payload = buf.subarray(4, 4 + len).toString('utf8')
      buf = buf.subarray(4 + len)
      log(`<<< ${payload}`)
      const reply = JSON.stringify({ cmd: 'hello', params: { ver: 1, side: 'dsh', echo: payload.slice(0, 160) } })
      sock.write(frame(reply))
      log(`>>> ${reply}`)
    }
  })

  sock.on('error', (e) => log(`[!] ${e.message}`))
  sock.on('close', () => log('[-] client closed'))
})

server.on('error', (e) => log(`[!] server error: ${e.message}`))
server.listen(PORT, '127.0.0.1', () => {
  log(`listening on 127.0.0.1:${PORT}`)
})
